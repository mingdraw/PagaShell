use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use ::vnc::{
    PixelFormat, Rect, VncClient, VncConnector, VncEncoding, VncError, VncEvent, X11Event,
};
use anyhow::{anyhow, bail, Context, Result};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch, Mutex};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::api::desktop::{DesktopCursor, DesktopFrame};
use crate::desktop::Transport;
use crate::desktop_frame::{FrameEncoder, FrameRequest};

#[cfg(test)]
#[path = "vnc_tests.rs"]
mod tests;

const TIMEOUT: Duration = Duration::from_secs(30);
const INPUT_TIMEOUT: Duration = Duration::from_secs(5);
const FRAME_INTERVAL: Duration = Duration::from_millis(16);
// Some servers answer an incremental request with zero rectangles; the decoder
// has no event for that message. Retry only while a consumer is waiting.
const REFRESH_RETRY: Duration = Duration::from_millis(750);
const MAX_PIXELS: usize = 8_294_400;
static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Session>>>> = LazyLock::new(Default::default);

#[cfg(windows)]
pub(crate) fn reserve_session_id() -> u32 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

struct Session {
    frames: mpsc::Sender<FrameRequest>,
    inputs: mpsc::Sender<InputRequest>,
    #[cfg(any(windows, test))]
    probes: mpsc::Sender<oneshot::Sender<()>>,
    cancel: CancellationToken,
    finished: watch::Sender<bool>,
}

struct InputRequest {
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
    reply: oneshot::Sender<Result<()>>,
}

#[derive(Default)]
struct HeldInputs {
    keys: HashSet<u32>,
    buttons: u8,
    x: u16,
    y: u16,
    typed_key: Option<u32>,
    wheel_active: bool,
}

struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
    encoder: FrameEncoder,
}

impl Default for Framebuffer {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            pixels: Vec::new(),
            encoder: FrameEncoder::new(0, 0),
        }
    }
}

impl Framebuffer {
    fn resize(&mut self, width: u16, height: u16) -> Result<()> {
        let count = usize::from(width) * usize::from(height);
        if width == 0 || height == 0 || width > 8192 || height > 8192 || count > MAX_PIXELS {
            bail!("VNC 画面尺寸无效或过大");
        }
        if self.width == width && self.height == height {
            return Ok(());
        }
        self.width = width;
        self.height = height;
        self.pixels = vec![0; count * 4];
        self.encoder.resize(width, height);
        Ok(())
    }

    fn valid(&self, r: Rect) -> bool {
        r.width > 0
            && r.height > 0
            && u32::from(r.x) + u32::from(r.width) <= u32::from(self.width)
            && u32::from(r.y) + u32::from(r.height) <= u32::from(self.height)
    }

    fn blit(&mut self, r: Rect, pixels: &[u8]) -> Result<()> {
        if !self.valid(r) || pixels.len() != usize::from(r.width) * usize::from(r.height) * 4 {
            bail!("VNC 画面数据无效");
        }
        let stride = usize::from(r.width) * 4;
        for row in 0..usize::from(r.height) {
            let offset =
                ((usize::from(r.y) + row) * usize::from(self.width) + usize::from(r.x)) * 4;
            self.pixels[offset..offset + stride]
                .copy_from_slice(&pixels[row * stride..(row + 1) * stride]);
        }
        self.encoder.damage_region(r.x, r.y, r.width, r.height);
        Ok(())
    }

    fn copy(&mut self, dst: Rect, src: Rect) -> Result<()> {
        if !self.valid(src)
            || !self.valid(dst)
            || dst.width != src.width
            || dst.height != src.height
        {
            bail!("VNC 画面数据无效");
        }
        let stride = usize::from(self.width) * 4;
        let bytes = usize::from(src.width) * 4;
        for at in 0..src.height {
            // A downward overlapping copy must start at the bottom row.
            let row = if dst.y > src.y {
                src.height - at - 1
            } else {
                at
            };
            let from = usize::from(src.y + row) * stride + usize::from(src.x) * 4;
            let to = usize::from(dst.y + row) * stride + usize::from(dst.x) * 4;
            self.pixels.copy_within(from..from + bytes, to);
        }
        self.encoder
            .damage_region(dst.x, dst.y, dst.width, dst.height);
        Ok(())
    }

    fn apply(&mut self, event: VncEvent) -> Result<()> {
        match event {
            VncEvent::SetResolution(s) => self.resize(s.width, s.height)?,
            VncEvent::DesktopUpdate(update) => {
                if let Some(layout) = update.layout {
                    self.resize(layout.width, layout.height)?;
                }
            }
            VncEvent::RawImage(r, pixels) => self.blit(r, &pixels)?,
            VncEvent::Copy(dst, src) => self.copy(dst, src)?,
            VncEvent::SetCursor(r, rgba) => {
                if rgba.len() != usize::from(r.width) * usize::from(r.height) * 4 {
                    bail!("VNC 光标无效");
                }
                self.encoder.cursor(DesktopCursor {
                    kind: if r.width == 0 || r.height == 0 { 1 } else { 2 },
                    width: r.width,
                    height: r.height,
                    hotspot_x: r.x,
                    hotspot_y: r.y,
                    rgba,
                });
            }
            VncEvent::Error(_) => bail!("VNC 连接已断开，请重新连接"),
            // Tight/JPEG and server clipboard synchronization are not negotiated.
            VncEvent::JpegImage(_, _) => bail!("VNC 画面编码不受支持"),
            _ => {}
        }
        Ok(())
    }

    fn ready(&self, after: u32) -> bool {
        self.width > 0 && self.encoder.ready(after)
    }

    fn frame(&mut self, after: u32) -> Option<DesktopFrame> {
        self.ready(after).then(|| {
            self.encoder
                .snapshot_rgba(self.width, self.height, &self.pixels, after)
        })
    }
}

pub(crate) async fn connect(
    host: String,
    port: u16,
    password: String,
    ssh_gateway: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    connect_inner(password, deadline, async move {
        if let Some(gateway) = page_gateway {
            Ok(Transport::Page(Box::new(
                crate::page::connect(gateway, &host, port, deadline).await?,
            )))
        } else if let Some(id) = ssh_gateway {
            Ok(Transport::Ssh(
                crate::api::ssh::desktop_tunnel(id, host, port).await?,
            ))
        } else {
            let stream = TcpStream::connect((host.as_str(), port))
                .await
                .context("VNC TCP 连接失败")?;
            stream.set_nodelay(true)?;
            Ok(Transport::Direct(stream))
        }
    })
    .await
}

#[cfg(windows)]
pub(crate) async fn connect_transport(password: String, stream: Transport) -> Result<u32> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    connect_inner(password, deadline, async move { Ok(stream) }).await
}

async fn connect_inner(
    password: String,
    deadline: tokio::time::Instant,
    open_stream: impl std::future::Future<Output = Result<Transport>>,
) -> Result<u32> {
    let client = tokio::time::timeout_at(deadline, async move {
        let stream = open_stream.await?;
        let state = VncConnector::new(stream)
            .set_auth_method(async move { Ok(password) })
            .set_pixel_format(PixelFormat::rgba())
            .allow_shared(true)
            .add_encoding(VncEncoding::Zrle)
            .add_encoding(VncEncoding::CopyRect)
            .add_encoding(VncEncoding::Raw)
            .add_encoding(VncEncoding::CursorPseudo)
            .add_encoding(VncEncoding::DesktopSizePseudo)
            .add_encoding(VncEncoding::LastRectPseudo)
            .build()
            .map_err(connect_error)?;
        state
            .try_start()
            .await
            .map_err(connect_error)?
            .finish()
            .map_err(connect_error)
    })
    .await
    .context("VNC 连接超时")??;
    let (frames, frame_rx) = mpsc::channel(4);
    let (inputs, input_rx) = mpsc::channel(64);
    #[cfg(any(windows, test))]
    let (probes, probe_rx) = mpsc::channel(4);
    let (finished, _) = watch::channel(false);
    let session = Arc::new(Session {
        frames,
        inputs,
        #[cfg(any(windows, test))]
        probes,
        cancel: CancellationToken::new(),
        finished,
    });
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    SESSIONS.lock().await.insert(id, Arc::clone(&session));
    #[cfg(any(windows, test))]
    tokio::spawn(run(session, client, frame_rx, input_rx, probe_rx));
    #[cfg(not(any(windows, test)))]
    tokio::spawn(run(session, client, frame_rx, input_rx));
    Ok(id)
}

fn connect_error(error: VncError) -> anyhow::Error {
    match error {
        VncError::WrongPassword | VncError::NoPassword => anyhow!("VNC_AUTH_FAILED"),
        VncError::InvalidSecurityTyep(_) => {
            anyhow!("VNC 服务器认证方式不受支持，请启用标准 VNC 密码认证")
        }
        // 3.8 authentication failures are returned as an opaque server string by vnc-rs.
        // Do not expose or classify arbitrary server messages as a password rejection.
        VncError::General(_) => anyhow!("VNC 认证或协议协商失败，请检查密码及服务器认证方式"),
        _ => anyhow!("VNC 连接失败，请检查地址、端口及服务器设置"),
    }
}

async fn run(
    session: Arc<Session>,
    client: VncClient,
    mut frames: mpsc::Receiver<FrameRequest>,
    mut inputs: mpsc::Receiver<InputRequest>,
    #[cfg(any(windows, test))] mut probes: mpsc::Receiver<oneshot::Sender<()>>,
) {
    let mut image = Framebuffer::default();
    let mut held = HeldInputs::default();
    let mut pending: Option<FrameRequest> = None;
    let mut publish_at = None;
    let mut refresh_at = Instant::now() + REFRESH_RETRY; // The library sends the first full request.
    let result: Result<()> = async {
        loop {
            if pending.as_ref().is_some_and(|request| request.reply.is_closed()) { pending = None; }
            let frame_ready = pending.as_ref().is_some_and(|request| image.ready(request.after));
            let deadline = if frame_ready { publish_at.unwrap_or_else(Instant::now) } else { refresh_at };
            #[cfg(any(windows, test))]
            let next_probe = probes.recv();
            #[cfg(not(any(windows, test)))]
            let next_probe = std::future::pending::<Option<oneshot::Sender<()>>>();
            tokio::select! {
                _ = session.cancel.cancelled() => return Ok(()),
                probe = next_probe => {
                    if let Some(reply) = probe {
                        let _ = reply.send(());
                    }
                }
                // recv_event holds the vnc-rs mutex. Only the owner uses the client,
                // and select drops the read future before processing an input.
                event = client.recv_event() => {
                    accept_event(&mut image, &mut refresh_at, event?)?;
                    if publish_at.is_none() { publish_at = Some(Instant::now() + FRAME_INTERVAL); }
                }
                request = frames.recv() => pending = request,
                request = inputs.recv() => {
                    if let Some(InputRequest { kind, code, flags, x, y, text, mut reply }) = request {
                        let result = tokio::select! {
                            _ = session.cancel.cancelled() => return Ok(()),
                            _ = reply.closed() => None,
                            result = apply_input(&client, &mut held, kind, code, flags, x, y, text) => Some(result),
                        };
                        if !matches!(&result, Some(Ok(()))) {
                            let _ = tokio::time::timeout(Duration::from_millis(200), held.release_transient(&client)).await;
                        }
                        if let Some(result) = result { let _ = reply.send(result); }
                    }
                }
                _ = tokio::time::sleep_until(deadline), if pending.is_some() => {
                    if frame_ready {
                        // Collect the rectangles already queued by the decoder in
                        // the same batch before exporting the dirty tiles.
                        for _ in 0..256 {
                            let Some(event) = client.poll_event().await? else { break; };
                            accept_event(&mut image, &mut refresh_at, event)?;
                        }
                        let request = pending.take().unwrap();
                        publish_at = None;
                        if !request.reply.is_closed() {
                            if let Some(frame) = image.frame(request.after) {
                                let _ = request.reply.send(crate::desktop_frame::FrameDelivery {
                                    frame,
                                    gpu: None,
                                });
                            }
                        }
                    } else {
                        tokio::select! {
                            _ = session.cancel.cancelled() => return Ok(()),
                            result = send(&client, X11Event::Refresh) => result?,
                        }
                        refresh_at = Instant::now() + REFRESH_RETRY;
                    }
                }
            }
        }
    }.await;
    let _ = result; // Protocol details and server strings never enter logs/UI.
    drop(frames);
    drop(pending);
    drop(inputs);
    #[cfg(any(windows, test))]
    drop(probes);
    if session.cancel.is_cancelled() {
        let _ = tokio::time::timeout(Duration::from_secs(1), async {
            if let Some(code) = held.typed_key.take() {
                held.keys.insert(code);
            }
            for code in held.keys.drain() {
                let _ = client.input(X11Event::KeyEvent((code, false).into())).await;
            }
            let _ = client
                .input(X11Event::PointerEvent((held.x, held.y, 0).into()))
                .await;
        })
        .await;
    }
    let _ = client.close().await;
    session.finished.send_replace(true);
}

impl HeldInputs {
    async fn release_transient(&mut self, client: &VncClient) {
        if let Some(key) = self.typed_key {
            if client
                .input(X11Event::KeyEvent((key, false).into()))
                .await
                .is_ok()
            {
                self.typed_key = None;
            }
        }
        if self.wheel_active
            && client
                .input(X11Event::PointerEvent(
                    (self.x, self.y, self.buttons).into(),
                ))
                .await
                .is_ok()
        {
            self.wheel_active = false;
        }
    }
}

fn accept_event(image: &mut Framebuffer, refresh_at: &mut Instant, event: VncEvent) -> Result<()> {
    if matches!(
        &event,
        VncEvent::RawImage(..)
            | VncEvent::Copy(..)
            | VncEvent::SetCursor(..)
            | VncEvent::DesktopUpdate(..)
    ) {
        *refresh_at = Instant::now() + FRAME_INTERVAL;
    }
    image.apply(event)
}

async fn get(id: u32) -> Result<Arc<Session>> {
    SESSIONS
        .lock()
        .await
        .get(&id)
        .cloned()
        .context("VNC 会话已关闭")
}

pub(crate) async fn frame(id: u32, after: u32) -> Result<Option<DesktopFrame>> {
    let session = get(id).await?;
    let wait = async {
        let (reply, result) = oneshot::channel();
        session
            .frames
            .send(FrameRequest { after, reply })
            .await
            .map_err(|_| anyhow!("VNC 连接已断开，请重新连接"))?;
        match result.await {
            Ok(delivery) => Ok(Some(delivery.frame)),
            Err(_) if session.frames.is_closed() || session.cancel.is_cancelled() => {
                bail!("VNC 连接已断开，请重新连接")
            }
            Err(_) => Ok(None),
        }
    };
    tokio::time::timeout(Duration::from_millis(500), wait)
        .await
        .unwrap_or(Ok(None))
}

async fn send(client: &VncClient, event: X11Event) -> Result<()> {
    tokio::time::timeout(INPUT_TIMEOUT, client.input(event))
        .await
        .context("VNC 输入超时")?
        .map_err(|_| anyhow!("VNC 输入失败，连接已断开"))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn input(
    id: u32,
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    let session = get(id).await?;
    anyhow::ensure!(kind <= 2, "VNC 输入类型无效");
    anyhow::ensure!(kind != 2 || text.len() <= 65536, "VNC 输入文本过长");
    let (reply, result) = oneshot::channel();
    tokio::time::timeout(INPUT_TIMEOUT, async {
        session
            .inputs
            .send(InputRequest {
                kind,
                code,
                flags,
                x,
                y,
                text,
                reply,
            })
            .await
            .map_err(|_| anyhow!("VNC 输入失败，连接已断开"))?;
        result
            .await
            .map_err(|_| anyhow!("VNC 输入失败，连接已断开"))?
    })
    .await
    .context("VNC 输入超时")?
}

#[allow(clippy::too_many_arguments)]
async fn apply_input(
    client: &VncClient,
    held: &mut HeldInputs,
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    match kind {
        0 => {
            let down = flags & 1 == 0;
            send(client, X11Event::KeyEvent((code, down).into())).await?;
            if down {
                held.keys.insert(code);
            } else {
                held.keys.remove(&code);
            }
        }
        1 => {
            held.x = x;
            held.y = y;
            for (flag, bit) in [(0x1000, 1), (0x2000, 4), (0x4000, 2)] {
                if flags & flag != 0 {
                    if flags & 0x8000 != 0 {
                        held.buttons |= bit;
                    } else {
                        held.buttons &= !bit;
                    }
                }
            }
            let wheel = if flags & 0x0200 != 0 {
                if flags & 0x0100 != 0 {
                    16
                } else {
                    8
                }
            } else if flags & 0x0400 != 0 {
                if flags & 0x0100 != 0 {
                    64
                } else {
                    32
                }
            } else {
                0
            };
            if wheel != 0 {
                for _ in 0..code.div_ceil(120).clamp(1, 8) {
                    send(
                        client,
                        X11Event::PointerEvent((x, y, held.buttons | wheel).into()),
                    )
                    .await?;
                    held.wheel_active = true;
                    send(client, X11Event::PointerEvent((x, y, held.buttons).into())).await?;
                    held.wheel_active = false;
                }
            } else {
                send(client, X11Event::PointerEvent((x, y, held.buttons).into())).await?;
            }
        }
        2 => {
            for c in text.chars() {
                let code = if c == '\n' || c == '\r' {
                    0xff0d
                } else if c == '\t' {
                    0xff09
                } else if u32::from(c) <= 255 {
                    u32::from(c)
                } else {
                    0x01000000 | u32::from(c)
                };
                send(client, X11Event::KeyEvent((code, true).into())).await?;
                held.typed_key = Some(code);
                send(client, X11Event::KeyEvent((code, false).into())).await?;
                held.typed_key = None;
            }
        }
        _ => bail!("VNC 输入类型无效"),
    }
    Ok(())
}

#[cfg(any(windows, test))]
pub(crate) async fn probe(id: u32) -> Result<()> {
    let session = get(id).await?;
    let (reply, waiter) = oneshot::channel();
    session
        .probes
        .send(reply)
        .await
        .map_err(|_| anyhow!("VNC 连接已断开，请重新连接"))?;
    waiter
        .await
        .map_err(|_| anyhow!("VNC 连接已断开，请重新连接"))
}

pub(crate) async fn disconnect(id: u32) {
    let Some(session) = SESSIONS.lock().await.remove(&id) else {
        return;
    };
    session.cancel.cancel();
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        session.finished.subscribe().wait_for(|finished| *finished),
    )
    .await;
}

#[cfg(windows)]
pub(crate) async fn disconnect_worker(id: u32) {
    let Some(session) = SESSIONS.lock().await.remove(&id) else {
        return;
    };
    session.cancel.cancel();
    let _ = tokio::time::timeout(
        Duration::from_millis(650),
        session.finished.subscribe().wait_for(|finished| *finished),
    )
    .await;
}
