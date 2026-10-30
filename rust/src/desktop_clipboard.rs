//! CLIPRDR stays on the RDP task; all filesystem work stays off that task.
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{anyhow, bail, Context, Result};
use ironrdp::core::{decode, AsAny, IntoOwned};
use ironrdp::pdu::gcc::{ChannelName, ChannelOptions};
use ironrdp::pdu::PduResult;
use ironrdp::session::{ActiveStage, ActiveStageOutput};
use ironrdp::svc::{SvcClientProcessor, SvcMessage, SvcProcessor, SvcProcessorMessages};
use ironrdp_cliprdr::backend::{ClipboardMessage, CliprdrBackend};
use ironrdp_cliprdr::pdu::{
    ClipboardFileAttributes, ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags,
    ClipboardPdu, FileContentsFlags, FileContentsRequest, FileContentsResponse, FileDescriptor,
    FormatDataRequest, FormatDataResponse, LockDataId,
};
use ironrdp_cliprdr::CliprdrClient;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot, watch};

use crate::api::desktop::DesktopClipboardEvent;

const MAX_TEXT: usize = 16 * 1024 * 1024;
const MAX_FILES: usize = 4096;
const MAX_BYTES: u64 = 16 * 1024 * 1024 * 1024;
const CHUNK: u32 = 1024 * 1024;
const MAX_UPLOAD_CHUNK: u32 = 4 * 1024 * 1024;
const FILE_LIST: &str = "FileGroupDescriptorW";
const NEGOTIATION_TIMEOUT: Duration = Duration::from_secs(15);
const NEGOTIATION_ERROR: &str = "远端未建立剪贴板通道，请检查 Windows 剪贴板重定向设置或重新连接";

pub(crate) enum Command {
    Protocol(ClipboardMessage),
    Publish(Arc<LocalCopy>),
    Barrier(oneshot::Sender<()>),
}

#[derive(Clone, Debug)]
pub(crate) struct Clipboard {
    inner: Arc<Inner>,
}

#[derive(Debug)]
struct Inner {
    state: Mutex<State>,
    messages: mpsc::UnboundedSender<Command>,
    receiver: Mutex<Option<mpsc::UnboundedReceiver<Command>>>,
    events: watch::Sender<DesktopClipboardEvent>,
    generation: watch::Sender<u64>,
    replies: Mutex<HashMap<u32, oneshot::Sender<Result<Vec<u8>>>>>,
}

#[derive(Debug, Default)]
struct State {
    active: bool,
    active_serial: u64,
    ready: bool,
    negotiation_started: Option<Instant>,
    files_enabled: bool,
    long_names: bool,
    directory: PathBuf,
    local: Arc<LocalCopy>,
    offer: Arc<LocalCopy>,
    unlocked: Option<Arc<LocalCopy>>,
    file_format: Option<ClipboardFormatId>,
    local_serial: u64,
    locked: HashMap<u32, Arc<LocalCopy>>,
    formats: VecDeque<u64>,
    next_stream: u32,
}

#[derive(Debug, Default)]
pub(crate) struct LocalCopy {
    text: Option<String>,
    files: Vec<LocalFile>,
}

#[derive(Debug)]
struct LocalFile {
    path: PathBuf,
    descriptor: FileDescriptor,
}

/// Observe the exact file-list response used by peers without clipDataId.
/// Keep the upstream protocol/state machine, and only associate its file list
/// with the local filesystem snapshot that produced it.
#[derive(Debug)]
pub(crate) struct ClipboardChannel {
    inner: CliprdrClient,
    clipboard: Clipboard,
}
impl AsAny for ClipboardChannel {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}
impl SvcClientProcessor for ClipboardChannel {}
impl SvcProcessor for ClipboardChannel {
    fn channel_name(&self) -> ChannelName {
        self.inner.channel_name()
    }
    fn channel_options(&self) -> ChannelOptions {
        self.inner.channel_options()
    }
    fn start(&mut self) -> PduResult<Vec<SvcMessage>> {
        self.inner.start()
    }
    fn process(&mut self, payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
        let file_request = match decode::<ClipboardPdu<'_>>(payload) {
            Ok(ClipboardPdu::FormatDataRequest(request)) => {
                let state = self.clipboard.inner.state.lock().unwrap();
                Some(request.format) == state.file_format
            }
            _ => false,
        };
        let messages = self.inner.process(payload)?;
        if file_request && !messages.is_empty() {
            let mut state = self.clipboard.inner.state.lock().unwrap();
            state.unlocked = Some(state.local.clone());
        }
        Ok(messages)
    }
}

impl Clipboard {
    pub(crate) fn new() -> Self {
        let (messages, receiver) = mpsc::unbounded_channel();
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                messages,
                receiver: Mutex::new(Some(receiver)),
                events: watch::channel(DesktopClipboardEvent::default()).0,
                generation: watch::channel(0).0,
                replies: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub(crate) fn client(&self) -> ClipboardChannel {
        ClipboardChannel {
            inner: CliprdrClient::new(Box::new(Backend(self.clone()))),
            clipboard: self.clone(),
        }
    }

    pub(crate) fn receiver(&self) -> mpsc::UnboundedReceiver<Command> {
        self.inner.receiver.lock().unwrap().take().unwrap()
    }

    fn send(&self, message: ClipboardMessage) {
        let _ = self.inner.messages.send(Command::Protocol(message));
    }

    fn event(&self, mut event: DesktopClipboardEvent) {
        self.inner.events.send_modify(|previous| {
            event.sequence = previous.sequence.wrapping_add(1).max(1);
            *previous = event;
        });
    }

    fn error(&self, message: &str) {
        self.event(DesktopClipboardEvent {
            kind: 4,
            error: Some(message.into()),
            ..Default::default()
        });
    }

    pub(crate) fn cancel(&self) {
        self.inner
            .generation
            .send_modify(|value| *value = value.wrapping_add(1));
        self.inner.replies.lock().unwrap().clear();
        self.event(DesktopClipboardEvent::default());
    }

    pub(crate) async fn active(&self, active: bool, directory: String) -> Result<()> {
        let directory = if active {
            let path = PathBuf::from(directory);
            if !path.is_absolute() {
                bail!("RDP 剪贴板缓存目录无效");
            }
            tokio::task::spawn_blocking(move || -> Result<PathBuf> {
                std::fs::create_dir_all(&path)?;
                // Only this app's completed clipboard caches; never follow links.
                for entry in std::fs::read_dir(&path)?.flatten() {
                    if entry.file_name().to_string_lossy().starts_with("copy-")
                        && entry.file_type().is_ok_and(|kind| kind.is_dir())
                        && entry
                            .metadata()
                            .ok()
                            .and_then(|m| m.modified().ok())
                            .and_then(|time| SystemTime::now().duration_since(time).ok())
                            .is_some_and(|age| age > Duration::from_secs(24 * 3600))
                    {
                        let _ = std::fs::remove_dir_all(entry.path());
                    }
                }
                Ok(path)
            })
            .await
            .context("RDP 剪贴板缓存不可用")??
        } else {
            PathBuf::new()
        };
        {
            let mut state = self.inner.state.lock().unwrap();
            state.active = active;
            state.active_serial = state.active_serial.wrapping_add(1);
            state.local_serial = state.local_serial.wrapping_add(1);
            state.negotiation_started = (active && !state.ready).then(Instant::now);
            if active {
                state.directory = directory;
            }
        }
        if !active {
            self.cancel();
        }
        Ok(())
    }

    pub(crate) async fn update(&self, text: Option<String>, files: Vec<String>) -> Result<()> {
        if text.as_ref().is_some_and(|text| text.len() > MAX_TEXT) || files.len() > MAX_FILES {
            bail!("RDP 剪贴板内容超出大小或数量限制");
        }
        let serial = {
            let mut state = self.inner.state.lock().unwrap();
            if !state.active {
                return Ok(());
            }
            state.local_serial = state.local_serial.wrapping_add(1);
            state.local_serial
        };
        self.cancel();
        let local = tokio::task::spawn_blocking(move || collect_local(text, files))
            .await
            .context("无法读取剪贴板文件")?
            .map_err(|_| anyhow!("无法读取剪贴板文件，请检查权限、文件名或文件数量"))?;
        {
            let mut state = self.inner.state.lock().unwrap();
            if !state.active || serial != state.local_serial {
                return Ok(());
            }
            state.offer = Arc::new(local);
            if !state.ready {
                return Ok(());
            }
        }
        self.advertise();
        // A paste key must follow the new FormatList on the same wire.
        let (reply, receiver) = oneshot::channel();
        self.inner
            .messages
            .send(Command::Barrier(reply))
            .map_err(|_| anyhow!("RDP 剪贴板通道已关闭"))?;
        tokio::time::timeout(Duration::from_secs(5), receiver)
            .await
            .context("RDP 剪贴板同步超时")?
            .context("RDP 剪贴板通道已关闭")?;
        Ok(())
    }

    fn advertise(&self) {
        let state = self.inner.state.lock().unwrap();
        if !state.active || !state.ready {
            return;
        }
        let _ = self
            .inner
            .messages
            .send(Command::Publish(state.offer.clone()));
    }

    pub(crate) fn publish(
        &self,
        stage: &mut ActiveStage,
        local: Arc<LocalCopy>,
    ) -> Vec<ActiveStageOutput> {
        {
            let mut state = self.inner.state.lock().unwrap();
            if !state.active || !Arc::ptr_eq(&local, &state.offer) {
                return Vec::new();
            }
            if !local.files.is_empty() && !state.files_enabled {
                drop(state);
                self.error("远端未启用文件剪贴板重定向");
                return Vec::new();
            }
            state.local = local.clone();
        }
        // Published snapshots change on the RDP task, atomically with the
        // upstream FormatList. An incoming Lock can never observe a queued copy.
        let message = if local.files.is_empty() {
            ClipboardMessage::SendInitiateCopy(if local.text.is_some() {
                vec![ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]
            } else {
                Vec::new()
            })
        } else {
            ClipboardMessage::SendInitiateFileCopy(
                local
                    .files
                    .iter()
                    .map(|file| file.descriptor.clone())
                    .collect(),
            )
        };
        self.process(stage, message)
    }

    pub(crate) async fn next(&self, after: u32) -> Option<DesktopClipboardEvent> {
        let mut events = self.inner.events.subscribe();
        let wait = async {
            loop {
                let event = events.borrow_and_update().clone();
                if event.sequence != after {
                    return Some(event);
                }
                if events.changed().await.is_err() {
                    return None;
                }
            }
        };
        tokio::time::timeout(Duration::from_millis(500), wait)
            .await
            .ok()
            .flatten()
    }

    pub(crate) fn process(
        &self,
        stage: &mut ActiveStage,
        message: ClipboardMessage,
    ) -> Vec<ActiveStageOutput> {
        let Some(channel) = stage.get_svc_processor_mut::<ClipboardChannel>() else {
            return Vec::new();
        };
        let channel = &mut channel.inner;
        let advertising = matches!(
            &message,
            ClipboardMessage::SendInitiateCopy(_) | ClipboardMessage::SendInitiateFileCopy(_)
        );
        let result = match message {
            ClipboardMessage::SendInitiateCopy(formats) => channel.initiate_copy(&formats),
            ClipboardMessage::SendInitiateFileCopy(files) => channel.initiate_file_copy(files),
            ClipboardMessage::SendFormatData(data) => channel.submit_format_data(data),
            ClipboardMessage::SendInitiatePaste(format) => channel.initiate_paste(format),
            ClipboardMessage::SendFileContentsRequest(request) => {
                channel.request_file_contents(request)
            }
            ClipboardMessage::SendFileContentsResponse(response) => {
                channel.submit_file_contents(response)
            }
            ClipboardMessage::Error(_) => {
                self.error("RDP 剪贴板传输失败，请重新复制");
                return Vec::new();
            }
        };
        match result.map_err(|_| ()).and_then(|messages| {
            let messages: Vec<SvcMessage> = messages.into();
            if advertising {
                let mut state = self.inner.state.lock().unwrap();
                for message in &messages {
                    if let Ok(bytes) = message.encode_unframed_pdu() {
                        if let Ok(ClipboardPdu::FormatList(list)) =
                            decode::<ClipboardPdu<'_>>(&bytes)
                        {
                            state.file_format =
                                list.get_formats(state.long_names).ok().and_then(|formats| {
                                    formats
                                        .into_iter()
                                        .find(|format| {
                                            format
                                                .name
                                                .as_ref()
                                                .is_some_and(|name| name.value() == FILE_LIST)
                                        })
                                        .map(|format| format.id)
                                });
                        }
                    }
                }
            }
            stage
                .process_svc_processor_messages(SvcProcessorMessages::<ClipboardChannel>::new(
                    messages,
                ))
                .map_err(|_| ())
        }) {
            Ok(bytes) => vec![ActiveStageOutput::ResponseFrame(bytes)],
            Err(_) => {
                self.error("RDP 剪贴板传输失败，请重新复制");
                Vec::new()
            }
        }
    }

    pub(crate) fn timeouts(&self, stage: &mut ActiveStage) -> Vec<ActiveStageOutput> {
        let negotiation_timed_out = {
            let mut state = self.inner.state.lock().unwrap();
            let expired = state.active
                && !state.ready
                && state
                    .negotiation_started
                    .is_some_and(|started| started.elapsed() >= NEGOTIATION_TIMEOUT);
            if expired {
                state.negotiation_started = None;
            }
            expired
        };
        if negotiation_timed_out {
            // A missing/disabled channel and an unanswered handshake used to
            // appear to work while silently dropping every clipboard update.
            self.error(NEGOTIATION_ERROR);
        }
        let Some(channel) = stage.get_svc_processor_mut::<ClipboardChannel>() else {
            return Vec::new();
        };
        let messages = channel.inner.drive_timeouts();
        match messages.map_err(|_| ()).and_then(|messages| {
            stage
                .process_svc_processor_messages(SvcProcessorMessages::<ClipboardChannel>::new(
                    messages.into(),
                ))
                .map_err(|_| ())
        }) {
            Ok(bytes) if !bytes.is_empty() => vec![ActiveStageOutput::ResponseFrame(bytes)],
            _ => Vec::new(),
        }
    }

    async fn chunk(
        &self,
        index: usize,
        position: u64,
        size: u32,
        data_id: Option<u32>,
        generation: u64,
        size_only: bool,
    ) -> Result<Vec<u8>> {
        let (reply, receiver) = oneshot::channel();
        let stream_id = {
            let mut state = self.inner.state.lock().unwrap();
            state.next_stream = state.next_stream.wrapping_add(1).max(1);
            state.next_stream
        };
        let mut cancelled = self.inner.generation.subscribe();
        if *cancelled.borrow() != generation {
            bail!("cancelled");
        }
        self.inner.replies.lock().unwrap().insert(stream_id, reply);
        self.send(ClipboardMessage::SendFileContentsRequest(
            FileContentsRequest {
                stream_id,
                index: i32::try_from(index)?,
                position,
                requested_size: size,
                flags: if size_only {
                    FileContentsFlags::SIZE
                } else {
                    FileContentsFlags::RANGE
                },
                data_id,
            },
        ));
        let result = tokio::select! {
            _ = cancelled.changed() => Err(anyhow!("cancelled")),
            result = tokio::time::timeout(Duration::from_secs(65), receiver) => {
                result.map_err(|_| anyhow!("clipboard timeout"))
                    .and_then(|result| result.map_err(|_| anyhow!("clipboard closed")))
                    .and_then(|result| result)
            }
        };
        self.inner.replies.lock().unwrap().remove(&stream_id);
        result
    }

    async fn download(
        &self,
        files: Vec<FileDescriptor>,
        data_id: Option<u32>,
        generation: u64,
    ) -> Result<()> {
        let entries = validate_remote(&files)?;
        let directory = self.inner.state.lock().unwrap().directory.clone();
        let cache = tokio::task::spawn_blocking(move || {
            tempfile::Builder::new()
                .prefix("copy-")
                .tempdir_in(directory)
        })
        .await??;
        let mut total = files
            .iter()
            .filter_map(|f| f.file_size)
            .try_fold(0_u64, |sum, size| {
                sum.checked_add(size)
                    .filter(|sum| *sum <= MAX_BYTES)
                    .context("clipboard too large")
            })?;
        let mut transferred = 0;
        let mut last_progress = Instant::now() - Duration::from_secs(1);
        for (index, (file, path)) in files.iter().zip(&entries).enumerate() {
            if *self.inner.generation.borrow() != generation {
                bail!("cancelled");
            }
            let target = cache.path().join(path);
            if file
                .attributes
                .is_some_and(|flags| flags.contains(ClipboardFileAttributes::DIRECTORY))
            {
                tokio::fs::create_dir_all(target).await?;
                continue;
            }
            let size = if let Some(size) = file.file_size {
                size
            } else {
                let bytes = self.chunk(index, 0, 8, data_id, generation, true).await?;
                let size =
                    u64::from_le_bytes(bytes.try_into().map_err(|_| anyhow!("invalid size"))?);
                total = total
                    .checked_add(size)
                    .filter(|total| *total <= MAX_BYTES)
                    .context("clipboard too large")?;
                size
            };
            if let Some(parent) = target.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            let mut output = tokio::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(target)
                .await?;
            let mut position = 0;
            while position < size {
                let count = u32::try_from((size - position).min(u64::from(CHUNK)))?;
                let bytes = self
                    .chunk(index, position, count, data_id, generation, false)
                    .await?;
                if bytes.is_empty() || bytes.len() > count as usize {
                    bail!("invalid clipboard range");
                }
                output.write_all(&bytes).await?;
                position += bytes.len() as u64;
                transferred += bytes.len() as u64;
                if *self.inner.generation.borrow() != generation {
                    bail!("cancelled");
                }
                if last_progress.elapsed() >= Duration::from_millis(100) {
                    self.event(DesktopClipboardEvent {
                        kind: 3,
                        transferred,
                        total,
                        ..Default::default()
                    });
                    last_progress = Instant::now();
                }
            }
            output.flush().await?;
        }
        let generation_guard = self.inner.generation.borrow();
        if *generation_guard != generation {
            bail!("cancelled");
        }
        let mut roots = Vec::new();
        for entry in entries {
            let root = entry.components().next().context("invalid name")?;
            let path = cache
                .path()
                .join(root.as_os_str())
                .to_string_lossy()
                .into_owned();
            if !roots.contains(&path) {
                roots.push(path);
            }
        }
        // Completed copies remain usable after disconnect; aged caches are swept
        // on the next activation. Failed/aborted TempDirs are removed by RAII.
        let _ = cache.keep();
        self.event(DesktopClipboardEvent {
            kind: 2,
            files: roots,
            transferred,
            total,
            ..Default::default()
        });
        Ok(())
    }
}

#[derive(Debug)]
struct Backend(Clipboard);
impl AsAny for Backend {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}
impl CliprdrBackend for Backend {
    fn temporary_directory(&self) -> &str {
        ""
    }
    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
            | ClipboardGeneralCapabilityFlags::FILECLIP_NO_FILE_PATHS
            | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
            | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED
    }
    fn on_ready(&mut self) {
        {
            let mut state = self.0.inner.state.lock().unwrap();
            state.ready = true;
            state.negotiation_started = None;
        }
        self.0.event(DesktopClipboardEvent::default());
        self.0.advertise();
    }
    fn on_request_format_list(&mut self) {
        self.0.send(ClipboardMessage::SendInitiateCopy(Vec::new()));
    }
    fn on_process_negotiated_capabilities(&mut self, flags: ClipboardGeneralCapabilityFlags) {
        let mut state = self.0.inner.state.lock().unwrap();
        state.files_enabled =
            flags.contains(ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED);
        state.long_names = flags.contains(ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES);
    }
    fn on_format_list_response(&mut self, ok: bool) {
        if !ok {
            self.0.error("远端拒绝了剪贴板内容，请重新复制");
        }
    }
    fn on_remote_copy(&mut self, formats: &[ClipboardFormat]) {
        let mut state = self.0.inner.state.lock().unwrap();
        if !state.active {
            return;
        }
        self.0.cancel();
        let generation = *self.0.inner.generation.borrow();
        let file_format = formats.iter().find(|format| {
            format
                .name
                .as_ref()
                .is_some_and(|name| name.value() == FILE_LIST)
        });
        let format = file_format.filter(|_| state.files_enabled).or_else(|| {
            formats
                .iter()
                .find(|format| format.id == ClipboardFormatId::CF_UNICODETEXT)
        });
        if let Some(format) = format {
            if state.formats.len() >= 32 {
                return;
            }
            state.formats.push_back(generation);
            self.0.event(DesktopClipboardEvent {
                kind: 3,
                ..Default::default()
            });
            self.0.send(ClipboardMessage::SendInitiatePaste(format.id));
        }
    }
    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        let state = self.0.inner.state.lock().unwrap();
        let response = if state.active && request.format == ClipboardFormatId::CF_UNICODETEXT {
            state
                .local
                .text
                .as_ref()
                .map(|text| {
                    FormatDataResponse::new_unicode_string(
                        &text.replace("\r\n", "\n").replace('\n', "\r\n"),
                    )
                })
                .unwrap_or_else(FormatDataResponse::new_error)
        } else {
            FormatDataResponse::new_error()
        };
        self.0
            .send(ClipboardMessage::SendFormatData(response.into_owned()));
    }
    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        let generation = self.0.inner.state.lock().unwrap().formats.pop_front();
        if generation != Some(*self.0.inner.generation.borrow()) {
            return;
        }
        if response.is_error() || response.data().len() > MAX_TEXT * 2 {
            self.0.error("无法读取远端剪贴板，请重新复制");
            return;
        }
        match response.to_unicode_string() {
            Ok(text) => self.0.event(DesktopClipboardEvent {
                kind: 1,
                text: Some(text.replace("\r\n", "\n")),
                ..Default::default()
            }),
            Err(_) => self.0.error("无法读取远端剪贴板，请重新复制"),
        }
    }
    fn on_remote_file_list(&mut self, files: &[FileDescriptor], data_id: Option<u32>) {
        let generation = self.0.inner.state.lock().unwrap().formats.pop_front();
        if generation != Some(*self.0.inner.generation.borrow()) {
            return;
        }
        let clipboard = self.0.clone();
        let files = files.to_vec();
        tokio::spawn(async move {
            if clipboard
                .download(files, data_id, generation.unwrap())
                .await
                .is_err()
                && *clipboard.inner.generation.borrow() == generation.unwrap()
            {
                clipboard.error("剪贴板文件接收失败，请检查文件大小、磁盘空间或重新复制");
            }
        });
    }
    fn on_file_contents_request(&mut self, request: FileContentsRequest) {
        let (local, active_serial) = {
            let state = self.0.inner.state.lock().unwrap();
            let local = if !state.active {
                None
            } else {
                match request.data_id {
                    Some(id) => state.locked.get(&id).cloned(),
                    None => state.unlocked.clone(),
                }
            };
            (local, state.active_serial)
        };
        let clipboard = self.0.clone();
        tokio::spawn(async move {
            let result = async {
                let local = local.context("missing snapshot")?;
                let file = local
                    .files
                    .get(usize::try_from(request.index)?)
                    .context("invalid index")?;
                if file
                    .descriptor
                    .attributes
                    .is_some_and(|flags| flags.contains(ClipboardFileAttributes::DIRECTORY))
                {
                    bail!("directory");
                }
                // Re-open only the user's advertised regular file; no remote path.
                let metadata = tokio::fs::symlink_metadata(&file.path).await?;
                if !metadata.is_file() || metadata.len() != file.descriptor.file_size.unwrap_or(0) {
                    bail!("file changed");
                }
                if request.flags.contains(FileContentsFlags::SIZE) {
                    return Ok(FileContentsResponse::new_size_response(
                        request.stream_id,
                        metadata.len(),
                    ));
                }
                if request.requested_size > MAX_UPLOAD_CHUNK || request.position > metadata.len() {
                    bail!("invalid range");
                }
                let mut input = tokio::fs::File::open(&file.path).await?;
                input
                    .seek(std::io::SeekFrom::Start(request.position))
                    .await?;
                let count = u64::from(request.requested_size).min(metadata.len() - request.position)
                    as usize;
                let mut bytes = vec![0; count];
                input.read_exact(&mut bytes).await?;
                Ok::<_, anyhow::Error>(FileContentsResponse::new_data_response(
                    request.stream_id,
                    bytes,
                ))
            }
            .await;
            let active = {
                let state = clipboard.inner.state.lock().unwrap();
                state.active && state.active_serial == active_serial
            };
            let result = if !active {
                Err(anyhow!("clipboard disabled or changed"))
            } else {
                result
            };
            clipboard.send(ClipboardMessage::SendFileContentsResponse(
                result.unwrap_or_else(|_| FileContentsResponse::new_error(request.stream_id)),
            ));
        });
    }
    fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
        if let Some(reply) = self
            .0
            .inner
            .replies
            .lock()
            .unwrap()
            .remove(&response.stream_id())
        {
            let _ = reply.send(if response.is_error() {
                Err(anyhow!("clipboard response failed"))
            } else {
                Ok(response.data().to_vec())
            });
        }
    }
    fn on_lock(&mut self, id: LockDataId) {
        let mut state = self.0.inner.state.lock().unwrap();
        if state.locked.len() < 64 {
            let local = state.local.clone();
            state.locked.insert(id.0, local);
        }
    }
    fn on_unlock(&mut self, id: LockDataId) {
        self.0.inner.state.lock().unwrap().locked.remove(&id.0);
    }
}

fn safe_component(name: &str) -> Result<()> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.ends_with(['.', ' '])
        || name
            .chars()
            .any(|c| c.is_control() || "\\/:*?\"<>|".contains(c))
        || ironrdp_cliprdr::is_windows_device_name(name)
    {
        bail!("invalid clipboard name");
    }
    Ok(())
}

fn descriptor_path(file: &FileDescriptor) -> Result<PathBuf> {
    safe_component(&file.name)?;
    let mut path = PathBuf::new();
    if let Some(parent) = file.relative_path.as_deref() {
        for component in parent.split('\\') {
            safe_component(component)?;
            path.push(component);
        }
    }
    path.push(&file.name);
    if path.to_string_lossy().encode_utf16().count() >= 260 {
        bail!("clipboard name too long");
    }
    Ok(path)
}

fn validate_remote(files: &[FileDescriptor]) -> Result<Vec<PathBuf>> {
    if files.is_empty() || files.len() > MAX_FILES {
        bail!("invalid clipboard count");
    }
    let mut seen = HashSet::new();
    let mut paths = Vec::new();
    for file in files {
        let path = descriptor_path(file)?;
        if !seen.insert(path.to_string_lossy().to_lowercase()) {
            bail!("duplicate clipboard path");
        }
        paths.push(path);
    }
    Ok(paths)
}

fn collect_local(text: Option<String>, paths: Vec<String>) -> Result<LocalCopy> {
    let mut files = Vec::new();
    let mut names = HashSet::new();
    let mut pending = VecDeque::new();
    for path in paths {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            bail!("invalid clipboard path");
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .context("invalid name")?
            .to_owned();
        safe_component(&name)?;
        if !names.insert(name.to_lowercase()) {
            bail!("duplicate clipboard root");
        }
        pending.push_back((path, name, None::<String>));
    }
    while let Some((path, name, parent)) = pending.pop_front() {
        if files.len() >= MAX_FILES {
            bail!("too many clipboard files");
        }
        let metadata = std::fs::symlink_metadata(&path)?;
        let mut descriptor = FileDescriptor::new(name);
        descriptor.relative_path = parent;
        let relative = descriptor_path(&descriptor)?;
        if metadata.is_dir() {
            descriptor.attributes = Some(ClipboardFileAttributes::DIRECTORY);
            let mut entries = std::fs::read_dir(&path)?.collect::<std::io::Result<Vec<_>>>()?;
            entries.sort_by_key(|entry| entry.file_name());
            let parent = relative
                .components()
                .map(|c| c.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("\\");
            for entry in entries {
                pending.push_back((
                    entry.path(),
                    entry
                        .file_name()
                        .into_string()
                        .map_err(|_| anyhow!("invalid name"))?,
                    Some(parent.clone()),
                ));
            }
        } else if metadata.is_file() {
            descriptor.file_size = Some(metadata.len());
            descriptor.attributes = Some(ClipboardFileAttributes::NORMAL);
        } else {
            bail!("clipboard symlink or special file");
        }
        files.push(LocalFile { path, descriptor });
    }
    Ok(LocalCopy {
        text: if files.is_empty() { text } else { None },
        files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::encode_vec;
    use ironrdp::session::ActiveStageBuilder;
    use ironrdp::svc::StaticChannelSet;
    use ironrdp_cliprdr::pdu::{Capabilities, ClipboardProtocolVersion, FormatListResponse};

    fn incoming(stage: &mut ActiveStage, pdu: ClipboardPdu<'_>) -> Vec<SvcMessage> {
        stage
            .get_svc_processor_mut::<ClipboardChannel>()
            .unwrap()
            .process(&encode_vec(&pdu).unwrap())
            .unwrap()
    }

    fn unready_stage(clipboard: &Clipboard) -> ActiveStage {
        let mut channels = StaticChannelSet::new();
        channels.insert(clipboard.client());
        channels.attach_channel_id(std::any::TypeId::of::<ClipboardChannel>(), 1004);
        ActiveStageBuilder {
            static_channels: channels,
            user_channel_id: 1001,
            io_channel_id: 1003,
            message_channel_id: None,
            share_id: 1,
            compression_type: None,
            enable_server_pointer: true,
            pointer_software_rendering: false,
        }
        .build()
    }

    fn ready_stage(clipboard: &Clipboard) -> ActiveStage {
        let mut stage = unready_stage(clipboard);
        incoming(
            &mut stage,
            ClipboardPdu::Capabilities(Capabilities::new(
                ClipboardProtocolVersion::V2,
                ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
                    | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
                    | ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES,
            )),
        );
        let outputs = clipboard.process(&mut stage, ClipboardMessage::SendInitiateCopy(Vec::new()));
        assert!(
            matches!(&outputs[..], [ActiveStageOutput::ResponseFrame(bytes)] if !bytes.is_empty())
        );
        incoming(
            &mut stage,
            ClipboardPdu::FormatListResponse(FormatListResponse::Ok),
        );
        assert!(clipboard.inner.state.lock().unwrap().ready);
        stage
    }

    #[tokio::test]
    async fn negotiation_timeout_reports_once_and_allows_late_readiness() {
        let clipboard = Clipboard::new();
        let dir = tempfile::tempdir().unwrap();
        clipboard
            .active(true, dir.path().to_string_lossy().into_owned())
            .await
            .unwrap();
        let mut stage = unready_stage(&clipboard);
        clipboard.inner.state.lock().unwrap().negotiation_started =
            Some(Instant::now() - NEGOTIATION_TIMEOUT);
        assert!(clipboard.timeouts(&mut stage).is_empty());
        let error = clipboard.inner.events.borrow().clone();
        assert_eq!(error.kind, 4);
        assert_eq!(error.error.as_deref(), Some(NEGOTIATION_ERROR));
        assert!(clipboard.timeouts(&mut stage).is_empty());
        assert_eq!(clipboard.inner.events.borrow().sequence, error.sequence);

        // A slow gateway may complete negotiation after the warning.
        stage = ready_stage(&clipboard);
        assert_eq!(clipboard.inner.events.borrow().kind, 0);
        clipboard.inner.state.lock().unwrap().negotiation_started =
            Some(Instant::now() - NEGOTIATION_TIMEOUT);
        clipboard.timeouts(&mut stage);
        assert_eq!(clipboard.inner.events.borrow().kind, 0);
    }

    #[tokio::test]
    async fn inactive_clipboard_does_not_report_negotiation_timeout() {
        let clipboard = Clipboard::new();
        let mut stage = unready_stage(&clipboard);
        clipboard.inner.state.lock().unwrap().negotiation_started =
            Some(Instant::now() - NEGOTIATION_TIMEOUT);
        clipboard.timeouts(&mut stage);
        assert_eq!(clipboard.inner.events.borrow().sequence, 0);
    }

    #[tokio::test]
    async fn wire_channel_preserves_published_locked_and_unlocked_file_snapshots() {
        let dir = tempfile::tempdir().unwrap();
        let old_path = dir.path().join("old.txt");
        let new_path = dir.path().join("new.txt");
        std::fs::write(&old_path, b"original").unwrap();
        std::fs::write(&new_path, b"new data").unwrap();
        let old =
            Arc::new(collect_local(None, vec![old_path.to_string_lossy().into_owned()]).unwrap());
        let new =
            Arc::new(collect_local(None, vec![new_path.to_string_lossy().into_owned()]).unwrap());
        let clipboard = Clipboard::new();
        let mut messages = clipboard.receiver();
        let mut stage = ready_stage(&clipboard);
        {
            let mut state = clipboard.inner.state.lock().unwrap();
            state.active = true;
            state.offer = old.clone();
        }
        assert!(!clipboard.publish(&mut stage, old.clone()).is_empty());
        let format = clipboard.inner.state.lock().unwrap().file_format.unwrap();
        let descriptor = incoming(
            &mut stage,
            ClipboardPdu::FormatDataRequest(FormatDataRequest { format }),
        );
        assert_eq!(descriptor.len(), 1);
        let bytes = descriptor[0].encode_unframed_pdu().unwrap();
        let ClipboardPdu::FormatDataResponse(response) =
            decode::<ClipboardPdu<'_>>(&bytes).unwrap()
        else {
            panic!("missing descriptor response");
        };
        assert_eq!(response.to_file_list().unwrap().files[0].name, "old.txt");
        clipboard.inner.state.lock().unwrap().offer = new.clone();
        incoming(&mut stage, ClipboardPdu::LockData(LockDataId(7)));
        assert!(Arc::ptr_eq(
            &clipboard.inner.state.lock().unwrap().locked[&7],
            &old
        ));
        assert!(!clipboard.publish(&mut stage, new).is_empty());
        assert!(Arc::ptr_eq(
            clipboard
                .inner
                .state
                .lock()
                .unwrap()
                .unlocked
                .as_ref()
                .unwrap(),
            &old
        ));
        for (stream_id, data_id) in [(11, None), (12, Some(7))] {
            incoming(
                &mut stage,
                ClipboardPdu::FileContentsRequest(FileContentsRequest {
                    stream_id,
                    index: 0,
                    flags: FileContentsFlags::RANGE,
                    position: 0,
                    requested_size: 8,
                    data_id,
                }),
            );
            let Command::Protocol(ClipboardMessage::SendFileContentsResponse(response)) =
                messages.recv().await.unwrap()
            else {
                panic!("missing file response");
            };
            assert!(!response.is_error());
            assert_eq!(response.data(), b"original");
            assert!(!clipboard
                .process(
                    &mut stage,
                    ClipboardMessage::SendFileContentsResponse(response)
                )
                .is_empty());
        }
    }

    #[tokio::test]
    async fn inactive_clipboard_rejects_file_reads_and_already_queued_uploads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("data.txt");
        std::fs::write(&path, b"private").unwrap();
        let clipboard = Clipboard::new();
        let mut messages = clipboard.receiver();
        {
            let mut state = clipboard.inner.state.lock().unwrap();
            state.unlocked = Some(Arc::new(
                collect_local(None, vec![path.to_string_lossy().into_owned()]).unwrap(),
            ));
        }
        let mut backend = Backend(clipboard.clone());
        for queued_while_active in [false, true] {
            clipboard.inner.state.lock().unwrap().active = queued_while_active;
            backend.on_file_contents_request(FileContentsRequest {
                stream_id: 3,
                index: 0,
                flags: FileContentsFlags::RANGE,
                position: 0,
                requested_size: 7,
                data_id: None,
            });
            // Before the spawned I/O task runs, deactivate and reactivate the tab.
            // Its old response must not become eligible in the next activation.
            clipboard.active(false, String::new()).await.unwrap();
            clipboard.inner.state.lock().unwrap().active = true;
            let Command::Protocol(ClipboardMessage::SendFileContentsResponse(response)) =
                messages.recv().await.unwrap()
            else {
                panic!("missing file response");
            };
            assert!(response.is_error());
        }
    }

    #[test]
    fn unicode_directory_collection_preserves_indices_and_rejects_unsafe_names() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("文件夹");
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("文档😀.txt"), b"hello").unwrap();
        let copy = collect_local(None, vec![folder.to_string_lossy().into_owned()]).unwrap();
        assert_eq!(copy.files.len(), 2);
        assert_eq!(copy.files[1].descriptor.name, "文档😀.txt");
        assert_eq!(
            copy.files[1].descriptor.relative_path.as_deref(),
            Some("文件夹")
        );
        assert_eq!(copy.files[1].descriptor.file_size, Some(5));
        for name in [
            "../escape",
            "..",
            "C:\\escape",
            "CON",
            "a:b",
            "file.",
            "file ",
        ] {
            assert!(
                validate_remote(&[FileDescriptor::new(name)]).is_err(),
                "{name}"
            );
        }
        assert!(
            validate_remote(&[FileDescriptor::new("a.txt"), FileDescriptor::new("A.txt"),])
                .is_err()
        );
        assert!(
            validate_remote(&[FileDescriptor::new("file").with_relative_path("..\\escape")])
                .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn local_symlinks_are_not_exported() {
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink("/etc/passwd", &link).unwrap();
        assert!(collect_local(None, vec![link.to_string_lossy().into_owned()]).is_err());
    }

    #[tokio::test]
    async fn remote_unicode_normalizes_line_endings_and_discards_stale_responses() {
        let clipboard = Clipboard::new();
        let mut backend = Backend(clipboard.clone());
        clipboard.inner.state.lock().unwrap().formats.push_back(0);
        backend.on_format_data_response(FormatDataResponse::new_unicode_string("中文😀\r\ntext"));
        let event = clipboard.next(0).await.unwrap();
        assert_eq!(event.text.as_deref(), Some("中文😀\ntext"));
        clipboard.inner.state.lock().unwrap().formats.push_back(0);
        clipboard.cancel();
        let sequence = clipboard.inner.events.borrow().sequence;
        backend.on_format_data_response(FormatDataResponse::new_unicode_string("stale"));
        assert_eq!(clipboard.inner.events.borrow().sequence, sequence);
    }

    #[tokio::test]
    async fn locked_upload_serves_original_file_and_arbitrary_ranges() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join("old.txt");
        let new = dir.path().join("new.txt");
        std::fs::write(&old, b"0123456789").unwrap();
        std::fs::write(&new, b"new").unwrap();
        let clipboard = Clipboard::new();
        clipboard.inner.state.lock().unwrap().active = true;
        let mut messages = clipboard.receiver();
        let mut backend = Backend(clipboard.clone());
        clipboard.inner.state.lock().unwrap().local =
            Arc::new(collect_local(None, vec![old.to_string_lossy().into_owned()]).unwrap());
        backend.on_lock(LockDataId(7));
        clipboard.inner.state.lock().unwrap().local =
            Arc::new(collect_local(None, vec![new.to_string_lossy().into_owned()]).unwrap());
        backend.on_file_contents_request(FileContentsRequest {
            stream_id: 12,
            index: 0,
            flags: FileContentsFlags::RANGE,
            position: 2,
            requested_size: 3,
            data_id: Some(7),
        });
        match messages.recv().await.unwrap() {
            Command::Protocol(ClipboardMessage::SendFileContentsResponse(response)) => {
                assert!(!response.is_error());
                assert_eq!(response.stream_id(), 12);
                assert_eq!(response.data(), b"234");
            }
            _ => panic!("missing file response"),
        }
        backend.on_unlock(LockDataId(7));
        assert!(clipboard.inner.state.lock().unwrap().locked.is_empty());
    }

    #[tokio::test]
    async fn download_streams_multiple_chunks_and_publishes_only_complete_files() {
        let root = tempfile::tempdir().unwrap();
        let clipboard = Clipboard::new();
        clipboard
            .active(true, root.path().to_string_lossy().into_owned())
            .await
            .unwrap();
        let mut messages = clipboard.receiver();
        let copy = clipboard.clone();
        let bytes = vec![42_u8; CHUNK as usize + 9];
        let size = bytes.len() as u64;
        let worker = tokio::spawn(async move {
            copy.download(
                vec![
                    FileDescriptor::new("folder")
                        .with_attributes(ClipboardFileAttributes::DIRECTORY),
                    FileDescriptor::new("中文.txt")
                        .with_relative_path("folder")
                        .with_file_size(size),
                    FileDescriptor::new("empty.txt").with_file_size(0),
                ],
                Some(3),
                0,
            )
            .await
        });
        let mut backend = Backend(clipboard.clone());
        for _ in 0..2 {
            let request = match messages.recv().await.unwrap() {
                Command::Protocol(ClipboardMessage::SendFileContentsRequest(request)) => request,
                _ => panic!("missing range request"),
            };
            assert_eq!(request.index, 1);
            assert_eq!(request.data_id, Some(3));
            let start = request.position as usize;
            let end = start + request.requested_size as usize;
            // An unrelated stream must not complete this request.
            backend.on_file_contents_response(FileContentsResponse::new_error(999));
            backend.on_file_contents_response(FileContentsResponse::new_data_response(
                request.stream_id,
                bytes[start..end].to_vec(),
            ));
        }
        worker.await.unwrap().unwrap();
        let event = clipboard.inner.events.borrow().clone();
        assert_eq!(event.kind, 2);
        assert_eq!(event.files.len(), 2);
        assert_eq!(
            std::fs::read(PathBuf::from(&event.files[0]).join("中文.txt")).unwrap(),
            bytes
        );
        assert!(std::fs::read(&event.files[1]).unwrap().is_empty());
        assert_eq!(event.transferred, size);
    }

    #[tokio::test]
    async fn cancelled_or_failed_download_removes_partial_files_and_replies() {
        for cancel in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let clipboard = Clipboard::new();
            clipboard
                .active(true, root.path().to_string_lossy().into_owned())
                .await
                .unwrap();
            let mut messages = clipboard.receiver();
            let copy = clipboard.clone();
            let worker = tokio::spawn(async move {
                copy.download(
                    vec![FileDescriptor::new("part.txt").with_file_size(100)],
                    None,
                    0,
                )
                .await
            });
            let request = match messages.recv().await.unwrap() {
                Command::Protocol(ClipboardMessage::SendFileContentsRequest(request)) => request,
                _ => panic!("missing range request"),
            };
            if cancel {
                clipboard.cancel();
            } else {
                Backend(clipboard.clone())
                    .on_file_contents_response(FileContentsResponse::new_error(request.stream_id));
            }
            assert!(worker.await.unwrap().is_err());
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
            assert!(clipboard.inner.replies.lock().unwrap().is_empty());
            assert_ne!(clipboard.inner.events.borrow().kind, 2);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn chunk_timeout_retires_pending_reply() {
        let clipboard = Clipboard::new();
        let mut messages = clipboard.receiver();
        let copy = clipboard.clone();
        let worker = tokio::spawn(async move { copy.chunk(0, 0, 1, None, 0, false).await });
        assert!(messages.recv().await.is_some());
        tokio::time::advance(Duration::from_secs(66)).await;
        assert!(worker.await.unwrap().is_err());
        assert!(clipboard.inner.replies.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn oversized_remote_claims_do_not_allocate_or_publish() {
        let root = tempfile::tempdir().unwrap();
        let clipboard = Clipboard::new();
        clipboard
            .active(true, root.path().to_string_lossy().into_owned())
            .await
            .unwrap();
        assert!(clipboard
            .download(
                vec![FileDescriptor::new("huge").with_file_size(u64::MAX)],
                None,
                0
            )
            .await
            .is_err());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
