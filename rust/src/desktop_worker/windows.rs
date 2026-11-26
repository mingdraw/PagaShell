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
    rpc::{Client, Messages, RDP_MESSAGES, VNC_MESSAGES},
    windows_handles::{FrameReader, TunnelPipe, WorkerJob},
    wire::{Reply, Request, MAX_FRAME_BYTES, VERSION},
};
use crate::api::desktop::{
    DesktopClipboardEvent, DesktopFrame, DesktopHandshake, DesktopInputEvent, DesktopWorkerStarted,
};
use crate::api::page::PageGateway;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(35);
// RDP authentication and activation can each take up to 30s.
const AUTH_TIMEOUT: Duration = Duration::from_secs(65);
const POLL_TIMEOUT: Duration = Duration::from_secs(3);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const CLOSE_GRACE: Duration = Duration::from_millis(1200);
const CLOSE_WAIT: Duration = Duration::from_millis(350);
const INITIAL_FRAME_BYTES: usize = 4 * 1024 * 1024;

static WORKERS: LazyLock<Mutex<HashMap<u32, Arc<Worker>>>> = LazyLock::new(Default::default);
static VNC_WORKERS: LazyLock<Mutex<HashMap<u32, Arc<Worker>>>> = LazyLock::new(Default::default);

pub(crate) struct Worker {
    client: Client,
    messages: Messages,
    job: Arc<WorkerJob>,
    exited: watch::Receiver<bool>,
    session_started: AtomicBool,
    closing: AtomicBool,
    frame: Mutex<Option<FrameReader>>,
    tunnel_bridge: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

async fn spawn_worker(
    messages: Messages,
    session_id: u32,
    registry: &'static LazyLock<Mutex<HashMap<u32, Arc<Worker>>>>,
) -> Result<DesktopWorkerStarted> {
    let mut child = Command::new(std::env::current_exe().context("无法定位 PagaShell")?)
        .arg("--pagashell-rdp-worker")
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("无法启动 Windows 远程桌面会话进程")?;
    let process_id = child.id().context("远程桌面会话进程已退出")?;
    let process = child.raw_handle().context("远程桌面会话进程已退出")?;
    // The child blocks on its private input until this succeeds. No network or
    // credentials reach a child that is not enrolled in its own Job Object.
    let job = Arc::new(WorkerJob::attach(process).context("无法隔离 Windows 远程桌面会话进程")?);
    let input = child.stdin.take().context("无法打开远程桌面会话进程输入")?;
    let output = child
        .stdout
        .take()
        .context("无法打开远程桌面会话进程输出")?;
    let client = Client::start_with_messages(output, input, messages);
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
    let worker = Arc::new(Worker {
        client,
        messages,
        job,
        exited,
        session_started: AtomicBool::new(false),
        closing: AtomicBool::new(false),
        frame: Mutex::new(None),
        tunnel_bridge: Mutex::new(None),
    });
    let weak = Arc::downgrade(&worker);
    registry.lock().await.insert(session_id, worker);
    tokio::spawn(async move {
        time::sleep(Duration::from_secs(180)).await;
        if let Some(worker) = weak.upgrade() {
            if !worker.session_started.load(Ordering::Acquire) {
                let removed = registry.lock().await.remove(&session_id);
                if let Some(worker) = removed {
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

pub(crate) async fn open() -> Result<DesktopWorkerStarted> {
    spawn_worker(RDP_MESSAGES, crate::desktop::reserve_session_id(), &WORKERS).await
}

pub(crate) async fn open_vnc() -> Result<DesktopWorkerStarted> {
    spawn_worker(VNC_MESSAGES, crate::vnc::reserve_session_id(), &VNC_WORKERS).await
}

pub(crate) async fn get(id: u32) -> Option<Arc<Worker>> {
    WORKERS.lock().await.get(&id).cloned()
}

pub(crate) async fn remove(id: u32) -> Option<Arc<Worker>> {
    WORKERS.lock().await.remove(&id)
}

pub(crate) async fn get_vnc(id: u32) -> Option<Arc<Worker>> {
    VNC_WORKERS.lock().await.get(&id).cloned()
}

pub(crate) async fn remove_vnc(id: u32) -> Option<Arc<Worker>> {
    VNC_WORKERS.lock().await.remove(&id)
}

impl Worker {
    async fn call(&self, request: Request, timeout: Duration) -> Result<Reply> {
        if self.closing.load(Ordering::Acquire) {
            return Err(anyhow!(self.messages.closed));
        }
        self.client.call(request, timeout).await
    }

    fn protocol_error(&self) -> anyhow::Error {
        self.client.stop(self.messages.invalid_reply);
        anyhow!(self.messages.invalid_reply)
    }

    fn start_watchdog(&self) {
        let client = self.client.clone();
        let invalid_reply = self.messages.invalid_reply;
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = client.stopped() => break,
                    _ = time::sleep(Duration::from_secs(2)) => {}
                }
                match client.call(Request::Probe, Duration::from_secs(8)).await {
                    Ok(Reply::Done) => {}
                    Ok(_) => {
                        client.stop(invalid_reply);
                        break;
                    }
                    // Ordinary session disconnects retain their native reason
                    // for polls. An IPC timeout already stops the process.
                    Err(_) => break,
                }
            }
        });
    }

    async fn open_ssh_tunnel(&self, ssh_gateway_id: u32, host: String, port: u16) -> Result<u64> {
        let upstream = crate::api::ssh::desktop_tunnel(ssh_gateway_id, host, port).await?;
        let pipe = TunnelPipe::create().context("无法创建网关隧道管道")?;
        let (remote_handle, task) = pipe.bridge(&self.job, upstream).await?;
        let mut bridge = self.tunnel_bridge.lock().await;
        if let Some(previous) = bridge.replace(task) {
            previous.abort();
        }
        Ok(remote_handle)
    }

    async fn finish_handshake(&self, id: u32, request: Request) -> Result<DesktopHandshake> {
        match self.call(request, HANDSHAKE_TIMEOUT).await? {
            Reply::Handshake(mut handshake) => {
                handshake.session_id = id;
                Ok(handshake)
            }
            _ => Err(self.protocol_error()),
        }
    }

    pub(crate) async fn handshake(
        &self,
        id: u32,
        host: String,
        port: u16,
    ) -> Result<DesktopHandshake> {
        self.finish_handshake(
            id,
            Request::Prepare {
                version: VERSION,
                host,
                port,
            },
        )
        .await
    }

    pub(crate) async fn handshake_via_page(
        &self,
        id: u32,
        host: String,
        port: u16,
        gateway: PageGateway,
    ) -> Result<DesktopHandshake> {
        self.finish_handshake(
            id,
            Request::PreparePage {
                version: VERSION,
                host,
                port,
                gateway,
            },
        )
        .await
    }

    pub(crate) async fn handshake_via_ssh(
        &self,
        id: u32,
        host: String,
        port: u16,
        ssh_gateway_id: u32,
    ) -> Result<DesktopHandshake> {
        let tunnel_handle = self
            .open_ssh_tunnel(ssh_gateway_id, host.clone(), port)
            .await?;
        self.finish_handshake(
            id,
            Request::PrepareTunnel {
                version: VERSION,
                host,
                tunnel_handle,
            },
        )
        .await
    }

    pub(crate) async fn vnc_connect(
        &self,
        host: String,
        port: u16,
        password: String,
        ssh_gateway_id: Option<u32>,
        page_gateway: Option<PageGateway>,
    ) -> Result<()> {
        let request = if let Some(gateway_id) = ssh_gateway_id {
            let tunnel_handle = self.open_ssh_tunnel(gateway_id, host, port).await?;
            Request::VncConnectTunnel {
                version: VERSION,
                password,
                tunnel_handle,
            }
        } else {
            Request::VncConnect {
                version: VERSION,
                host,
                port,
                password,
                page_gateway,
            }
        };
        let start_watchdog = !self.session_started.swap(true, Ordering::AcqRel);
        match self.call(request, HANDSHAKE_TIMEOUT).await? {
            Reply::Done => {}
            _ => return Err(self.protocol_error()),
        }
        if start_watchdog {
            self.start_watchdog();
        }
        Ok(())
    }

    pub(crate) async fn authenticate(
        &self,
        fingerprint: String,
        username: String,
        password: String,
        domain: String,
        preferences: crate::rdp::ClientPreferences,
        gpu_adapter_luid: Option<u64>,
    ) -> Result<()> {
        let start_watchdog = !self.session_started.swap(true, Ordering::AcqRel);
        match self
            .call(
                Request::Authenticate {
                    fingerprint,
                    username,
                    password,
                    domain,
                    preferences,
                    gpu_adapter_luid,
                },
                AUTH_TIMEOUT,
            )
            .await?
        {
            Reply::Done => {}
            _ => return Err(self.protocol_error()),
        }
        if start_watchdog {
            self.start_watchdog();
        }
        Ok(())
    }

    pub(crate) async fn vnc_frame(&self, after: u32) -> Result<Option<DesktopFrame>> {
        self.frame_inner(None, after).await
    }

    pub(crate) async fn frame(&self, session: u32, after: u32) -> Result<Option<DesktopFrame>> {
        self.frame_inner(Some(session), after).await
    }

    async fn frame_inner(
        &self,
        texture_session: Option<u32>,
        mut after: u32,
    ) -> Result<Option<DesktopFrame>> {
        let mut slot = self.frame.lock().await;
        // If this call is cancelled, retire its slot. A later call offers a
        // new mapping instead of reading bytes an in-flight request still owns.
        let mut buffer = slot.take();
        let mut desired = INITIAL_FRAME_BYTES;
        for _ in 0..5 {
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
                    let Some(mut frame) = frame else {
                        *slot = Some(current);
                        return Ok(None);
                    };
                    crate::rdp::validate_desktop_size(frame.width, frame.height)
                        .map_err(|_| self.protocol_error())?;
                    let len = usize::from(frame.bitmap_width)
                        .checked_mul(usize::from(frame.bitmap_height))
                        .and_then(|pixels| pixels.checked_mul(4))
                        .ok_or_else(|| self.protocol_error())?;
                    let pixels = current
                        .pixels(len, frame.sequence)
                        .map_err(|_| self.protocol_error())?;
                    if let Some(session) = texture_session {
                        if let Some(presenter) =
                            crate::desktop_texture::Presenter::for_session(session)
                        {
                            desired = current.capacity();
                            let result = crate::desktop_texture::run_upload(session, move || {
                                // Keep this mapping alive until the upload returns.
                                // A failed/abandoned upload will never recycle it.
                                let pixels = current.pixels(len, frame.sequence).map_err(|_| ())?;
                                presenter.submit(&mut frame, pixels)?;
                                Ok((frame, current))
                            })
                            .await;
                            match result {
                                Ok((frame, current)) => {
                                    *slot = Some(current);
                                    return Ok(Some(frame));
                                }
                                Err(()) => {
                                    // Dart skipped the GPU updates; its CPU atlas
                                    // needs a full base from a different mapping.
                                    after = 0;
                                    continue;
                                }
                            }
                        }
                    }
                    frame.rgba = pixels.to_vec();
                    *slot = Some(current);
                    return Ok(Some(frame));
                }
                Reply::GpuFrame { mut frame, surface } => {
                    crate::rdp::validate_desktop_size(frame.width, frame.height)
                        .map_err(|_| self.protocol_error())?;
                    let submitted = if let Some(session) = texture_session {
                        if let Some(presenter) =
                            crate::desktop_texture::Presenter::for_session(session)
                        {
                            crate::desktop_texture::run_upload(session, move || {
                                presenter.submit_gpu(
                                    &mut frame,
                                    crate::desktop_texture::GPU_SURFACE_DXGI_SHARED_HANDLE,
                                    surface.handle,
                                    surface.generation,
                                )?;
                                Ok(frame)
                            })
                            .await
                        } else {
                            Err(())
                        }
                    } else {
                        Err(())
                    };
                    match submitted {
                        Ok(frame) => {
                            *slot = Some(current);
                            return Ok(Some(frame));
                        }
                        Err(()) => {
                            let _ = self.done(Request::DisableGpu).await;
                            desired = current.capacity();
                            after = 0;
                            continue;
                        }
                    }
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

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn vnc_input(
        &self,
        kind: u8,
        code: u32,
        flags: u16,
        x: u16,
        y: u16,
        text: String,
    ) -> Result<()> {
        self.done(Request::VncInput {
            kind,
            code,
            flags,
            x,
            y,
            text,
        })
        .await
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
            self.client.stop(self.messages.closed);
        }
        if let Some(bridge) = self.tunnel_bridge.lock().await.take() {
            bridge.abort();
        }
        let mut exited = self.exited.clone();
        let _ = time::timeout(CLOSE_WAIT, exited.wait_for(|value| *value)).await;
    }
}
