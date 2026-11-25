use std::{
    collections::HashMap,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, LazyLock,
    },
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use tokio::{
    process::Command,
    sync::{watch, Mutex},
    time,
};
use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

use super::{
    rpc::{Client, CLOSED, INVALID_REPLY},
    windows_handles::{FrameReader, WorkerJob},
    wire::{Reply, Request, MAX_FRAME_BYTES, VERSION},
};
use crate::api::desktop::{
    DesktopClipboardEvent, DesktopFrame, DesktopHandshake, DesktopInputEvent, DesktopWorkerStarted,
};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(35);
// RDP authentication and activation can each take up to 30s.
const AUTH_TIMEOUT: Duration = Duration::from_secs(65);
const POLL_TIMEOUT: Duration = Duration::from_secs(3);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const CLOSE_GRACE: Duration = Duration::from_millis(1200);
const CLOSE_WAIT: Duration = Duration::from_millis(350);
const INITIAL_FRAME_BYTES: usize = 4 * 1024 * 1024;

static WORKERS: LazyLock<Mutex<HashMap<u32, Arc<Worker>>>> = LazyLock::new(Default::default);

pub(crate) struct Worker {
    client: Client,
    job: Arc<WorkerJob>,
    exited: watch::Receiver<bool>,
    authentication_started: AtomicBool,
    closing: AtomicBool,
    frame: Mutex<Option<FrameReader>>,
}

pub(crate) async fn open() -> Result<DesktopWorkerStarted> {
    let mut child = Command::new(std::env::current_exe().context("无法定位 PagaShell")?)
        .arg("--pagashell-rdp-worker")
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("无法启动 Windows RDP 会话进程")?;
    let process_id = child.id().context("RDP 会话进程已退出")?;
    let process = child.raw_handle().context("RDP 会话进程已退出")?;
    // The child blocks on its private input until this succeeds. No network or
    // credentials reach a child that is not enrolled in its own Job Object.
    let job = Arc::new(WorkerJob::attach(process).context("无法隔离 Windows RDP 会话进程")?);
    let input = child.stdin.take().context("无法打开 RDP 会话进程输入")?;
    let output = child.stdout.take().context("无法打开 RDP 会话进程输出")?;
    let client = Client::start(output, input);
    let (exited_tx, exited) = watch::channel(false);
    let monitor = client.clone();
    let monitored_job = job.clone();
    tokio::spawn(async move {
        tokio::select! {
            _ = child.wait() => {}
            _ = monitor.stopped() => {
                monitored_job.terminate();
                let _ = child.start_kill();
                let _ = child.wait().await;
            }
        }
        monitored_job.terminate();
        exited_tx.send_replace(true);
    });
    let session_id = crate::desktop::reserve_session_id();
    let worker = Arc::new(Worker {
        client,
        job,
        exited,
        authentication_started: AtomicBool::new(false),
        closing: AtomicBool::new(false),
        frame: Mutex::new(None),
    });
    let weak = Arc::downgrade(&worker);
    WORKERS.lock().await.insert(session_id, worker);
    tokio::spawn(async move {
        time::sleep(Duration::from_secs(180)).await;
        if let Some(worker) = weak.upgrade() {
            if !worker.authentication_started.load(Ordering::Acquire) {
                if let Some(worker) = remove(session_id).await {
                    worker.close().await;
                }
            }
        }
    });
    Ok(DesktopWorkerStarted {
        session_id,
        process_id,
    })
}

pub(crate) async fn get(id: u32) -> Option<Arc<Worker>> {
    WORKERS.lock().await.get(&id).cloned()
}

pub(crate) async fn remove(id: u32) -> Option<Arc<Worker>> {
    WORKERS.lock().await.remove(&id)
}

impl Worker {
    async fn call(&self, request: Request, timeout: Duration) -> Result<Reply> {
        if self.closing.load(Ordering::Acquire) {
            return Err(anyhow!(CLOSED));
        }
        self.client.call(request, timeout).await
    }

    fn protocol_error(&self) -> anyhow::Error {
        self.client.stop(INVALID_REPLY);
        anyhow!(INVALID_REPLY)
    }

    pub(crate) async fn handshake(
        &self,
        id: u32,
        host: String,
        port: u16,
    ) -> Result<DesktopHandshake> {
        match self
            .call(
                Request::Prepare {
                    version: VERSION,
                    host,
                    port,
                },
                HANDSHAKE_TIMEOUT,
            )
            .await?
        {
            Reply::Handshake(mut handshake) => {
                handshake.session_id = id;
                Ok(handshake)
            }
            _ => Err(self.protocol_error()),
        }
    }

    pub(crate) async fn authenticate(
        &self,
        fingerprint: String,
        username: String,
        password: String,
        domain: String,
    ) -> Result<()> {
        let start_watchdog = !self.authentication_started.swap(true, Ordering::AcqRel);
        match self
            .call(
                Request::Authenticate {
                    fingerprint,
                    username,
                    password,
                    domain,
                },
                AUTH_TIMEOUT,
            )
            .await?
        {
            Reply::Done => {}
            _ => return Err(self.protocol_error()),
        }
        if start_watchdog {
            let client = self.client.clone();
            tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = client.stopped() => break,
                        _ = time::sleep(Duration::from_secs(2)) => {}
                    }
                    match client.call(Request::Probe, Duration::from_secs(8)).await {
                        Ok(Reply::Done) => {}
                        Ok(_) => {
                            client.stop(INVALID_REPLY);
                            break;
                        }
                        // Ordinary RDP disconnects retain their native reason
                        // for polls. An IPC timeout already stops the process.
                        Err(_) => break,
                    }
                }
            });
        }
        Ok(())
    }

    pub(crate) async fn frame(&self, after: u32) -> Result<Option<DesktopFrame>> {
        let mut slot = self.frame.lock().await;
        // If this call is cancelled, retire its slot. A later call offers a
        // new mapping instead of reading bytes an in-flight request still owns.
        let mut buffer = slot.take();
        let mut desired = INITIAL_FRAME_BYTES;
        for _ in 0..3 {
            let (current, mapping) = match buffer.take() {
                Some(current) => (current, None),
                None => {
                    let current = FrameReader::new(desired)?;
                    let offer = current.offer(&self.job)?;
                    (current, Some(offer))
                }
            };
            match self
                .call(Request::Frame { after, mapping }, POLL_TIMEOUT)
                .await?
            {
                Reply::Frame(frame) => {
                    let frame = frame
                        .map(|mut frame| {
                            crate::rdp::validate_desktop_size(frame.width, frame.height)?;
                            let len = usize::from(frame.bitmap_width)
                                .checked_mul(usize::from(frame.bitmap_height))
                                .and_then(|pixels| pixels.checked_mul(4))
                                .context("RDP 会话进程画面超限")?;
                            frame.rgba = current.read(len, frame.sequence)?;
                            Ok::<_, anyhow::Error>(frame)
                        })
                        .transpose()
                        .map_err(|_| self.protocol_error())?;
                    *slot = Some(current);
                    return Ok(frame);
                }
                Reply::NeedFrameSpace(required)
                    if (required as usize) > current.capacity()
                        && required as usize <= MAX_FRAME_BYTES =>
                {
                    desired = (required as usize).next_power_of_two();
                    // The next request reuses the caller's base sequence, so
                    // abandoning an oversized snapshot cannot lose damage.
                }
                _ => return Err(self.protocol_error()),
            }
        }
        Err(self.protocol_error())
    }

    async fn done(&self, request: Request) -> Result<()> {
        match self.call(request, COMMAND_TIMEOUT).await? {
            Reply::Done => Ok(()),
            _ => Err(self.protocol_error()),
        }
    }

    pub(crate) async fn input(
        &self,
        kind: u8,
        code: u16,
        flags: u16,
        x: u16,
        y: u16,
        text: String,
    ) -> Result<()> {
        self.done(Request::Input {
            kind,
            code,
            flags,
            x,
            y,
            text,
        })
        .await
    }

    pub(crate) async fn input_batch(&self, events: Vec<DesktopInputEvent>) -> Result<()> {
        self.done(Request::InputBatch(events)).await
    }

    pub(crate) async fn resize(&self, width: u16, height: u16) -> Result<bool> {
        match self
            .call(Request::Resize { width, height }, COMMAND_TIMEOUT)
            .await?
        {
            Reply::Resize(sent) => Ok(sent),
            _ => Err(self.protocol_error()),
        }
    }

    pub(crate) async fn clipboard_active(&self, active: bool, directory: String) -> Result<()> {
        self.done(Request::ClipboardActive { active, directory })
            .await
    }

    pub(crate) async fn clipboard_update(
        &self,
        text: Option<String>,
        files: Vec<String>,
    ) -> Result<()> {
        self.done(Request::ClipboardUpdate { text, files }).await
    }

    pub(crate) async fn clipboard_event(
        &self,
        after: u32,
    ) -> Result<Option<DesktopClipboardEvent>> {
        match self
            .call(Request::ClipboardEvent { after }, POLL_TIMEOUT)
            .await?
        {
            Reply::Clipboard(event) => Ok(event),
            _ => Err(self.protocol_error()),
        }
    }

    pub(crate) async fn clipboard_cancel(&self) -> Result<()> {
        self.done(Request::ClipboardCancel).await
    }

    pub(crate) async fn close(&self) {
        if !self.closing.swap(true, Ordering::AcqRel) {
            let _ = self.client.call(Request::Close, CLOSE_GRACE).await;
            self.client.stop(CLOSED);
        }
        let mut exited = self.exited.clone();
        let _ = time::timeout(CLOSE_WAIT, exited.wait_for(|value| *value)).await;
    }
}
