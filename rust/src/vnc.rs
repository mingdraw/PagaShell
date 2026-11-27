use std::collections::{HashMap, HashSet};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock};
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;

use ::vnc::{
    DesktopStatus, PixelFormat, Rect, ResizeError, VncClient, VncConnector, VncEncoding, VncError,
    VncEvent, X11Event,
};
use anyhow::{anyhow, bail, Context, Result};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch, Mutex};
use tokio::time::{Instant, MissedTickBehavior};
use tokio_util::sync::CancellationToken;

use crate::api::desktop::{
    DesktopClipboardEvent, DesktopCursor, DesktopFrame, DesktopNetworkStats,
};
use crate::api::vnc::VncInputEvent;
use crate::desktop::Transport;
use crate::desktop_frame::{FrameEncoder, FrameRequest};
use crate::desktop_network::{
    DesktopNetworkTracker, QualityTier, TcpInfoSampler, QUALITY_MODE_AUTO, QUALITY_MODE_LOW,
    TRANSPORT_TCP, TRANSPORT_TUNNEL,
};

#[cfg(test)]
#[path = "vnc_tests.rs"]
mod tests;

const TIMEOUT: Duration = Duration::from_secs(30);
const INPUT_TIMEOUT: Duration = Duration::from_secs(5);
const FRAME_INTERVAL: Duration = Duration::from_millis(16);
const PARTIAL_FLUSH: Duration = Duration::from_millis(80);
// Fallback when a server silently ignores an incremental request without
// sending even a zero-rectangle FramebufferUpdate. Retry only while waiting.
const REFRESH_RETRY: Duration = Duration::from_millis(750);
const MAX_PIXELS: usize = 24_000_000;
const MAX_INPUT_BATCH: usize = 64;
const MAX_CLIPBOARD_TEXT: usize = 1024 * 1024;
static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Session>>>> = LazyLock::new(Default::default);

#[cfg(windows)]
pub(crate) fn reserve_session_id() -> u32 {
    crate::desktop_frame::reserve_desktop_session_id()
}

pub(crate) fn validate_desktop_size(width: u16, height: u16) -> Result<()> {
    let count = usize::from(width) * usize::from(height);
    if width == 0 || height == 0 || width > 8192 || height > 8192 || count > MAX_PIXELS {
        bail!("VNC 画面尺寸无效或过大");
    }
    Ok(())
}

struct MeteredTransport {
    inner: Transport,
    rx_bytes: Arc<AtomicU64>,
}

impl AsyncRead for MeteredTransport {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let poll = Pin::new(&mut this.inner).poll_read(cx, buf);
        if matches!(poll, Poll::Ready(Ok(()))) {
            let read = buf.filled().len().saturating_sub(before);
            if read > 0 {
                this.rx_bytes.fetch_add(read as u64, Ordering::Relaxed);
            }
        }
        poll
    }
}

impl AsyncWrite for MeteredTransport {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

struct VncClipboard {
    state: std::sync::Mutex<VncClipboardState>,
    events: watch::Sender<DesktopClipboardEvent>,
}

#[derive(Default)]
struct VncClipboardState {
    active: bool,
    sequence: u32,
    last_text: Option<String>,
}

impl VncClipboard {
    fn new() -> Self {
        Self {
            state: std::sync::Mutex::new(VncClipboardState::default()),
            events: watch::channel(DesktopClipboardEvent::default()).0,
        }
    }

    fn set_active(&self, active: bool) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.active = active;
        if active {
            state.sequence = state.sequence.wrapping_add(1).max(1);
            let sequence = state.sequence;
            self.events.send_replace(DesktopClipboardEvent {
                sequence,
                kind: 0,
                ..Default::default()
            });
        }
    }

    fn prepare_local_send(&self, text: &str) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !state.active {
            return false;
        }
        state.last_text = Some(text.to_string());
        true
    }

    fn receive_remote(&self, text: String) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !state.active || state.last_text.as_deref() == Some(text.as_str()) {
            return;
        }
        state.last_text = Some(text.clone());
        state.sequence = state.sequence.wrapping_add(1).max(1);
        let sequence = state.sequence;
        self.events.send_replace(DesktopClipboardEvent {
            sequence,
            kind: 1,
            text: Some(text),
            ..Default::default()
        });
    }
}

struct Session {
    client: VncClient,
    frames: mpsc::Sender<FrameRequest>,
    inputs: mpsc::Sender<InputRequest>,
    network_stats: watch::Sender<DesktopNetworkStats>,
    quality_mode: watch::Sender<u8>,
    clipboard: Arc<VncClipboard>,
    #[cfg(any(windows, test))]
    probes: mpsc::Sender<oneshot::Sender<()>>,
    cancel: CancellationToken,
    finished: watch::Sender<bool>,
}

enum InputCommand {
    Single {
        kind: u8,
        code: u32,
        flags: u16,
        x: u16,
        y: u16,
        text: String,
    },
    Batch(Vec<VncInputEvent>),
}

struct InputRequest {
    command: InputCommand,
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PixelOrder {
    r: usize,
    g: usize,
    b: usize,
    a: usize,
}

impl PixelOrder {
    const RGBA: Self = Self {
        r: 0,
        g: 1,
        b: 2,
        a: 3,
    };
    const BGRA: Self = Self {
        r: 2,
        g: 1,
        b: 0,
        a: 3,
    };
    const XRGB_BE: Self = Self {
        r: 1,
        g: 2,
        b: 3,
        a: 0,
    };

    fn from_format(pf: &PixelFormat) -> Result<Self> {
        if !pf.is_native_true_color_32() {
            bail!("VNC 像素格式不受支持");
        }
        let byte_index = |shift: u8| -> usize {
            let index = usize::from(shift / 8);
            if pf.big_endian_flag != 0 {
                3 - index
            } else {
                index
            }
        };
        let r = byte_index(pf.red_shift);
        let g = byte_index(pf.green_shift);
        let b = byte_index(pf.blue_shift);
        let a = 6 - (r + g + b);
        Ok(Self { r, g, b, a })
    }

    fn is_rgba(self) -> bool {
        self == Self::RGBA
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WirePixelFormat {
    TrueColor32(PixelOrder),
    Rgb565Le,
    TrueColor16 {
        big_endian: bool,
        r_max: u16,
        g_max: u16,
        b_max: u16,
        r_shift: u8,
        g_shift: u8,
        b_shift: u8,
    },
}

impl WirePixelFormat {
    fn from_format(pf: &PixelFormat) -> Result<Self> {
        if pf.is_native_true_color_32() {
            return Ok(Self::TrueColor32(PixelOrder::from_format(pf)?));
        }
        if pf.bits_per_pixel == 16 && pf.true_color_flag != 0 {
            if *pf == PixelFormat::rgb565() {
                return Ok(Self::Rgb565Le);
            }
            if pf.red_max == 0 || pf.green_max == 0 || pf.blue_max == 0 {
                bail!("VNC 像素格式不受支持");
            }
            return Ok(Self::TrueColor16 {
                big_endian: pf.big_endian_flag != 0,
                r_max: pf.red_max,
                g_max: pf.green_max,
                b_max: pf.blue_max,
                r_shift: pf.red_shift,
                g_shift: pf.green_shift,
                b_shift: pf.blue_shift,
            });
        }
        bail!("VNC 像素格式不受支持")
    }

    fn bytes_per_pixel(self) -> usize {
        match self {
            Self::TrueColor32(_) => 4,
            Self::Rgb565Le | Self::TrueColor16 { .. } => 2,
        }
    }
}

struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
    pixel_format: WirePixelFormat,
    encoder: FrameEncoder,
}

impl Default for Framebuffer {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            pixels: Vec::new(),
            pixel_format: WirePixelFormat::TrueColor32(PixelOrder::RGBA),
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
        let mut pixels = vec![0; count * 4];
        for px in pixels.chunks_exact_mut(4) {
            px[3] = 255;
        }
        self.pixels = pixels;
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
        let src_bpp = self.pixel_format.bytes_per_pixel();
        if !self.valid(r) || pixels.len() != usize::from(r.width) * usize::from(r.height) * src_bpp
        {
            bail!("VNC 画面数据无效");
        }
        let dst_stride = usize::from(r.width) * 4;
        let src_stride = usize::from(r.width) * src_bpp;
        let fb_width = usize::from(self.width);
        match self.pixel_format {
            WirePixelFormat::TrueColor32(PixelOrder::RGBA) => {
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(4)) {
                        dst[0] = src[0];
                        dst[1] = src[1];
                        dst[2] = src[2];
                        dst[3] = 255;
                    }
                }
            }
            WirePixelFormat::TrueColor32(PixelOrder::BGRA) => {
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(4)) {
                        dst[0] = src[2];
                        dst[1] = src[1];
                        dst[2] = src[0];
                        dst[3] = 255;
                    }
                }
            }
            WirePixelFormat::TrueColor32(PixelOrder::XRGB_BE) => {
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(4)) {
                        dst[0] = src[1];
                        dst[1] = src[2];
                        dst[2] = src[3];
                        dst[3] = 255;
                    }
                }
            }
            WirePixelFormat::TrueColor32(order) => {
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(4)) {
                        dst[0] = src[order.r];
                        dst[1] = src[order.g];
                        dst[2] = src[order.b];
                        dst[3] = 255;
                    }
                }
            }
            WirePixelFormat::Rgb565Le => {
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(2)) {
                        let v = u16::from_le_bytes([src[0], src[1]]);
                        let r5 = ((v >> 11) & 0x1f) as u8;
                        let g6 = ((v >> 5) & 0x3f) as u8;
                        let b5 = (v & 0x1f) as u8;
                        dst[0] = (r5 << 3) | (r5 >> 2);
                        dst[1] = (g6 << 2) | (g6 >> 4);
                        dst[2] = (b5 << 3) | (b5 >> 2);
                        dst[3] = 255;
                    }
                }
            }
            WirePixelFormat::TrueColor16 {
                big_endian,
                r_max,
                g_max,
                b_max,
                r_shift,
                g_shift,
                b_shift,
            } => {
                let (rm, gm, bm) = (u32::from(r_max), u32::from(g_max), u32::from(b_max));
                for row in 0..usize::from(r.height) {
                    let offset = ((usize::from(r.y) + row) * fb_width + usize::from(r.x)) * 4;
                    let dst_row = &mut self.pixels[offset..offset + dst_stride];
                    let src_row = &pixels[row * src_stride..(row + 1) * src_stride];
                    for (dst, src) in dst_row.chunks_exact_mut(4).zip(src_row.chunks_exact(2)) {
                        let v = if big_endian {
                            u16::from_be_bytes([src[0], src[1]])
                        } else {
                            u16::from_le_bytes([src[0], src[1]])
                        };
                        let r = ((u32::from(v) >> r_shift) & rm) * 255 + rm / 2;
                        let g = ((u32::from(v) >> g_shift) & gm) * 255 + gm / 2;
                        let b = ((u32::from(v) >> b_shift) & bm) * 255 + bm / 2;
                        dst[0] = (r / rm) as u8;
                        dst[1] = (g / gm) as u8;
                        dst[2] = (b / bm) as u8;
                        dst[3] = 255;
                    }
                }
            }
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
            VncEvent::SetPixelFormat(pf) => self.pixel_format = WirePixelFormat::from_format(&pf)?,
            VncEvent::DesktopUpdate(update) => {
                if let Some(layout) = update.layout {
                    self.resize(layout.width, layout.height)?;
                }
            }
            VncEvent::RawImage(r, pixels) => self.blit(r, &pixels)?,
            VncEvent::Copy(dst, src) => self.copy(dst, src)?,
            VncEvent::SetCursor(r, mut rgba) => {
                if rgba.len() != usize::from(r.width) * usize::from(r.height) * 4 {
                    bail!("VNC 光标无效");
                }
                if let WirePixelFormat::TrueColor32(order) = self.pixel_format {
                    if !order.is_rgba() {
                        for px in rgba.chunks_exact_mut(4) {
                            let converted = [px[order.r], px[order.g], px[order.b], px[order.a]];
                            px.copy_from_slice(&converted);
                        }
                    }
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
                .snapshot_opaque_rgba(self.width, self.height, &self.pixels, after)
        })
    }
}

pub(crate) async fn connect(
    host: String,
    port: u16,
    username: String,
    password: String,
    ssh_gateway: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    connect_inner(username, password, deadline, async move {
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
            Ok(Transport::Direct {
                stream,
                probe: std::sync::Arc::new(crate::desktop_network::TcpInfoSampler::default()),
            })
        }
    })
    .await
}

#[cfg(windows)]
pub(crate) async fn connect_transport(
    username: String,
    password: String,
    stream: Transport,
) -> Result<u32> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    connect_inner(username, password, deadline, async move { Ok(stream) }).await
}

struct TelemetryContext {
    transport_kind: u8,
    tcp_probe: Option<Arc<TcpInfoSampler>>,
    rx_bytes: Arc<AtomicU64>,
    handshake_rtt: Option<Duration>,
}

async fn connect_inner(
    username: String,
    password: String,
    deadline: tokio::time::Instant,
    open_stream: impl std::future::Future<Output = Result<Transport>>,
) -> Result<u32> {
    let used_ard_username = !username.trim().is_empty();
    let rx_bytes = Arc::new(AtomicU64::new(0));
    let metered_rx = Arc::clone(&rx_bytes);
    let (client, transport_kind, tcp_probe, handshake_rtt) =
        tokio::time::timeout_at(deadline, async move {
            let connect_started = Instant::now();
            let stream = open_stream.await?;
            let (transport_kind, tcp_probe) = match &stream {
                Transport::Direct { probe, .. } => (TRANSPORT_TCP, Some(Arc::clone(probe))),
                Transport::Ssh(_) | Transport::Page(_) => (TRANSPORT_TUNNEL, None),
                #[cfg(windows)]
                Transport::Pipe(_) => (TRANSPORT_TUNNEL, None),
            };
            let handshake_started = Instant::now();
            let metered = MeteredTransport {
                inner: stream,
                rx_bytes: metered_rx,
            };
            let state = VncConnector::new(metered)
                .set_username(username)
                .set_auth_method(async move { Ok(password) })
                .set_pixel_format(PixelFormat::rgba())
                .prefer_server_true_color_32(true)
                .emit_frame_complete(true)
                .output_channel_capacity(128)
                .allow_shared(true)
                .add_encoding(VncEncoding::Zrle)
                .add_encoding(VncEncoding::CopyRect)
                .add_encoding(VncEncoding::Raw)
                .add_encoding(VncEncoding::CursorPseudo)
                .add_encoding(VncEncoding::DesktopSizePseudo)
                .add_encoding(VncEncoding::ExtendedDesktopSizePseudo)
                .add_encoding(VncEncoding::LastRectPseudo)
                .build()
                .map_err(|e| connect_error(e, used_ard_username))?;
            let client = state
                .try_start()
                .await
                .map_err(|e| connect_error(e, used_ard_username))?
                .finish()
                .map_err(|e| connect_error(e, used_ard_username))?;
            let handshake_rtt = Some(if transport_kind == TRANSPORT_TCP {
                handshake_started.saturating_duration_since(connect_started)
            } else {
                handshake_started.elapsed()
            });
            Ok::<_, anyhow::Error>((client, transport_kind, tcp_probe, handshake_rtt))
        })
        .await
        .context("VNC 连接超时")??;
    let initial_stats = DesktopNetworkTracker::new(transport_kind, handshake_rtt).snapshot();
    let (frames, frame_rx) = mpsc::channel(4);
    let (inputs, input_rx) = mpsc::channel(64);
    let (network_stats, _) = watch::channel(initial_stats);
    let (quality_mode, _) = watch::channel(QUALITY_MODE_AUTO);
    #[cfg(any(windows, test))]
    let (probes, probe_rx) = mpsc::channel(4);
    let (finished, _) = watch::channel(false);
    let session = Arc::new(Session {
        client: client.clone(),
        frames,
        inputs,
        network_stats,
        quality_mode,
        clipboard: Arc::new(VncClipboard::new()),
        #[cfg(any(windows, test))]
        probes,
        cancel: CancellationToken::new(),
        finished,
    });
    let telemetry = TelemetryContext {
        transport_kind,
        tcp_probe,
        rx_bytes,
        handshake_rtt,
    };
    let id = crate::desktop_frame::reserve_desktop_session_id();
    SESSIONS.lock().await.insert(id, Arc::clone(&session));
    #[cfg(any(windows, test))]
    tokio::spawn(run(
        session, client, telemetry, frame_rx, input_rx, probe_rx,
    ));
    #[cfg(not(any(windows, test)))]
    tokio::spawn(run(session, client, telemetry, frame_rx, input_rx));
    Ok(id)
}

fn connect_error(error: VncError, used_ard_username: bool) -> anyhow::Error {
    match error {
        VncError::UsernameRequired => anyhow!("VNC_ARD_USERNAME_REQUIRED"),
        VncError::WrongPassword | VncError::NoPassword => {
            if used_ard_username {
                anyhow!("VNC_ARD_AUTH_FAILED")
            } else {
                anyhow!("VNC_AUTH_FAILED")
            }
        }
        VncError::CredentialTooLong => {
            anyhow!("macOS 远程桌面用户名或密码长度不能超过 63 字节")
        }
        VncError::InvalidSecurityTyep(_) | VncError::UnsupportedSecurityType => {
            anyhow!("VNC 服务器认证方式不受支持，请启用标准 VNC 密码或 macOS 屏幕共享")
        }
        // Do not expose arbitrary untrusted server error strings directly in UI.
        VncError::General(_) => anyhow!("VNC 认证或协议协商失败，请检查账号密码及服务器认证方式"),
        _ => anyhow!("VNC 连接失败，请检查地址、端口及服务器设置"),
    }
}

fn quality_tier_from_u8(value: u8) -> QualityTier {
    match value {
        1 => QualityTier::Balanced,
        2 => QualityTier::Low,
        _ => QualityTier::High,
    }
}

fn vnc_frame_interval(tier: QualityTier) -> Duration {
    match tier {
        QualityTier::High => FRAME_INTERVAL,
        QualityTier::Balanced => Duration::from_millis(33),
        QualityTier::Low => Duration::from_millis(50),
    }
}

fn vnc_target_pixel_format(tier: QualityTier, native_32: PixelFormat) -> PixelFormat {
    match tier {
        QualityTier::High | QualityTier::Balanced => native_32,
        QualityTier::Low => PixelFormat::rgb565(),
    }
}

async fn run(
    session: Arc<Session>,
    client: VncClient,
    telemetry: TelemetryContext,
    mut frames: mpsc::Receiver<FrameRequest>,
    mut inputs: mpsc::Receiver<InputRequest>,
    #[cfg(any(windows, test))] mut probes: mpsc::Receiver<oneshot::Sender<()>>,
) {
    let mut image = Framebuffer::default();
    let mut held = HeldInputs::default();
    let mut pending: Option<FrameRequest> = None;
    let mut update_in_flight = true; // The library sends the first full request.
    let mut frame_dirty_since: Option<Instant> = None;
    let mut frame_interval = FRAME_INTERVAL;
    let mut next_refresh_at = Instant::now();
    let mut refresh_sent_at = Instant::now();
    let mut refresh_retry_at = Instant::now() + REFRESH_RETRY;

    let native_pf = client.pixel_format();
    let mut active_pf = native_pf;
    let mut desired_pf = native_pf;
    let mut pending_applied_tier: Option<QualityTier> = None;
    let mut need_full_refresh = false;

    let mut tracker = DesktopNetworkTracker::new(telemetry.transport_kind, telemetry.handshake_rtt);
    let mut published_first_frame = false;
    let mut quality_rx = session.quality_mode.subscribe();
    let mut telemetry_tick = tokio::time::interval_at(
        Instant::now() + Duration::from_secs(1),
        Duration::from_secs(1),
    );
    telemetry_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

    let result: Result<()> = async {
        loop {
            if pending.as_ref().is_some_and(|request| request.reply.is_closed()) {
                pending = None;
            }
            let frame_ready = pending
                .as_ref()
                .is_some_and(|request| image.ready(request.after));
            if frame_ready && !update_in_flight {
                if deliver_pending(&mut pending, &mut image, &mut frame_dirty_since) {
                    tracker.record_frame_delivered();
                    if !published_first_frame {
                        published_first_frame = true;
                        let rx = telemetry.rx_bytes.swap(0, Ordering::Relaxed);
                        tracker.record_rx_bytes(rx as usize);
                        session.network_stats.send_replace(tracker.snapshot());
                    }
                }
                continue;
            }
            if !update_in_flight {
                if let Some(target_tier) = pending_applied_tier {
                    if desired_pf == active_pf {
                        tracker.mark_egfx_applied(target_tier, Instant::now());
                        pending_applied_tier = None;
                    } else {
                        // Drain any already-queued events before changing wire pixel format.
                        let mut drained_update = false;
                        for _ in 0..256 {
                            let Some(next) = client.poll_event().await? else {
                                break;
                            };
                            drained_update = true;
                            accept_event(
                                &mut image,
                                &session.clipboard,
                                &mut update_in_flight,
                                &mut frame_dirty_since,
                                &mut need_full_refresh,
                                next,
                            )?;
                        }
                        if !update_in_flight && !drained_update {
                            tokio::select! {
                                _ = session.cancel.cancelled() => return Ok(()),
                                result = tokio::time::timeout(
                                    INPUT_TIMEOUT,
                                    client.set_pixel_format(desired_pf),
                                ) => {
                                    result
                                        .context("VNC 画质切换超时")?
                                        .map_err(|_| anyhow!("VNC 连接已断开，请重新连接"))?;
                                }
                            }
                            active_pf = desired_pf;
                            need_full_refresh = true;
                            tracker.mark_egfx_applied(target_tier, Instant::now());
                            pending_applied_tier = None;
                            next_refresh_at = Instant::now();
                            continue;
                        }
                    }
                }
            }
            let partial_ready = frame_ready && frame_dirty_since.is_some();
            let deadline = if partial_ready {
                frame_dirty_since.unwrap() + PARTIAL_FLUSH
            } else if !update_in_flight {
                next_refresh_at
            } else {
                refresh_retry_at
            };
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
                changed = quality_rx.changed() => {
                    if changed.is_ok() {
                        let mode = *quality_rx.borrow_and_update();
                        let outcome = tracker.set_quality_mode(mode, Instant::now(), true);
                        let tier = quality_tier_from_u8(outcome.stats.quality_tier);
                        frame_interval = vnc_frame_interval(tier);
                        if let Some(target_tier) = outcome.egfx_reset_target {
                            desired_pf = vnc_target_pixel_format(target_tier, native_pf);
                            pending_applied_tier = Some(target_tier);
                        }
                        session.network_stats.send_replace(outcome.stats);
                    }
                }
                _ = telemetry_tick.tick() => {
                    let rx = telemetry.rx_bytes.swap(0, Ordering::Relaxed);
                    tracker.record_rx_bytes(rx as usize);
                    if let Some(probe) = &telemetry.tcp_probe {
                        if let Some(sample) = probe.latest() {
                            tracker.observe_tcp_sample(sample);
                        }
                    }
                    let frame_backlog = if update_in_flight && pending.is_some() {
                        let elapsed = refresh_sent_at.elapsed();
                        if elapsed >= Duration::from_millis(250) {
                            4
                        } else if elapsed >= Duration::from_millis(120) {
                            2
                        } else {
                            0
                        }
                    } else {
                        0
                    };
                    let outcome = tracker.tick(Instant::now(), true, frame_backlog);
                    let tier = quality_tier_from_u8(outcome.stats.quality_tier);
                    frame_interval = vnc_frame_interval(tier);
                    if let Some(target_tier) = outcome.egfx_reset_target {
                        desired_pf = vnc_target_pixel_format(target_tier, native_pf);
                        pending_applied_tier = Some(target_tier);
                    }
                    session.network_stats.send_replace(outcome.stats);
                }
                event = client.recv_event() => {
                    let mut completed = accept_event(
                        &mut image,
                        &session.clipboard,
                        &mut update_in_flight,
                        &mut frame_dirty_since,
                        &mut need_full_refresh,
                        event?,
                    )?;
                    for _ in 0..256 {
                        if completed && pending.is_some() {
                            break;
                        }
                        let Some(next) = client.poll_event().await? else {
                            break;
                        };
                        completed |= accept_event(
                            &mut image,
                            &session.clipboard,
                            &mut update_in_flight,
                            &mut frame_dirty_since,
                            &mut need_full_refresh,
                            next,
                        )?;
                    }
                }
                request = frames.recv() => pending = request,
                request = inputs.recv() => {
                    if let Some(InputRequest { command, mut reply }) = request {
                        let result = tokio::select! {
                            _ = session.cancel.cancelled() => return Ok(()),
                            _ = reply.closed() => None,
                            result = apply_input_command(&client, &mut held, command) => Some(result),
                        };
                        if !matches!(&result, Some(Ok(()))) {
                            let _ = tokio::time::timeout(
                                Duration::from_millis(200),
                                held.release_transient(&client),
                            )
                            .await;
                        }
                        if let Some(result) = result {
                            let _ = reply.send(result);
                        }
                    }
                }
                _ = tokio::time::sleep_until(deadline), if pending.is_some() => {
                    if partial_ready {
                        for _ in 0..256 {
                            let Some(next) = client.poll_event().await? else {
                                break;
                            };
                            if accept_event(
                                &mut image,
                                &session.clipboard,
                                &mut update_in_flight,
                                &mut frame_dirty_since,
                                &mut need_full_refresh,
                                next,
                            )? {
                                break;
                            }
                        }
                        if deliver_pending(&mut pending, &mut image, &mut frame_dirty_since) {
                            tracker.record_frame_delivered();
                            if !published_first_frame {
                                published_first_frame = true;
                                let rx = telemetry.rx_bytes.swap(0, Ordering::Relaxed);
                                tracker.record_rx_bytes(rx as usize);
                                session.network_stats.send_replace(tracker.snapshot());
                            }
                        }
                    } else {
                        let refresh_event = if need_full_refresh {
                            need_full_refresh = false;
                            X11Event::FullRefresh
                        } else {
                            X11Event::Refresh
                        };
                        tokio::select! {
                            _ = session.cancel.cancelled() => return Ok(()),
                            result = send(&client, refresh_event) => result?,
                        }
                        let now = Instant::now();
                        update_in_flight = true;
                        refresh_sent_at = now;
                        next_refresh_at = now + frame_interval;
                        refresh_retry_at = now + REFRESH_RETRY;
                    }
                }
            }
        }
    }
    .await;
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

fn deliver_pending(
    pending: &mut Option<FrameRequest>,
    image: &mut Framebuffer,
    frame_dirty_since: &mut Option<Instant>,
) -> bool {
    let Some(request) = pending.take() else {
        return false;
    };
    *frame_dirty_since = None;
    if request.reply.is_closed() {
        return false;
    }
    if let Some(frame) = image.frame(request.after) {
        let _ = request
            .reply
            .send(crate::desktop_frame::FrameDelivery { frame, gpu: None });
        true
    } else {
        *pending = Some(request);
        false
    }
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

fn accept_event(
    image: &mut Framebuffer,
    clipboard: &VncClipboard,
    update_in_flight: &mut bool,
    frame_dirty_since: &mut Option<Instant>,
    need_full_refresh: &mut bool,
    event: VncEvent,
) -> Result<bool> {
    match event {
        VncEvent::FrameComplete => {
            *update_in_flight = false;
            return Ok(true);
        }
        VncEvent::Text(text) => {
            clipboard.receive_remote(text);
            return Ok(false);
        }
        VncEvent::SetResolution(size) => {
            if image.width != 0 && (image.width != size.width || image.height != size.height) {
                *need_full_refresh = true;
            }
            image.apply(VncEvent::SetResolution(size))?;
            return Ok(false);
        }
        VncEvent::DesktopUpdate(update) => {
            if let Some(layout) = &update.layout {
                if image.width != 0
                    && (image.width != layout.width || image.height != layout.height)
                {
                    *need_full_refresh = true;
                }
            }
            frame_dirty_since.get_or_insert_with(Instant::now);
            image.apply(VncEvent::DesktopUpdate(update))?;
            return Ok(false);
        }
        VncEvent::RawImage(..) | VncEvent::Copy(..) | VncEvent::SetCursor(..) => {
            frame_dirty_since.get_or_insert_with(Instant::now);
        }
        _ => {}
    }
    image.apply(event)?;
    Ok(false)
}

async fn get(id: u32) -> Result<Arc<Session>> {
    SESSIONS
        .lock()
        .await
        .get(&id)
        .cloned()
        .context("VNC 会话已关闭")
}

pub(crate) async fn network_stats(id: u32) -> Result<DesktopNetworkStats> {
    let session = get(id).await?;
    let stats = *session.network_stats.borrow();
    Ok(stats)
}

pub(crate) async fn set_quality_mode(id: u32, mode: u8) -> Result<()> {
    let session = get(id).await?;
    let clamped = if mode <= QUALITY_MODE_LOW {
        mode
    } else {
        QUALITY_MODE_AUTO
    };
    session.quality_mode.send_replace(clamped);
    Ok(())
}

pub(crate) async fn resize(id: u32, width: u16, height: u16) -> Result<bool> {
    validate_desktop_size(width, height)?;
    let session = get(id).await?;
    let result = tokio::select! {
        _ = session.cancel.cancelled() => bail!("VNC 会话已关闭"),
        result = session.client.resize_desktop(width, height) => result,
    };
    match result {
        Ok(_) => Ok(true),
        Err(ResizeError::Unsupported | ResizeError::UnsupportedLayout | ResizeError::Uncertain) => {
            Ok(false)
        }
        Err(ResizeError::Denied(DesktopStatus::OutOfResources | DesktopStatus::InvalidLayout)) => {
            bail!("远端不支持所选分辨率，请选择较小的尺寸")
        }
        Err(ResizeError::Denied(_)) => Ok(false),
        Err(ResizeError::Timeout | ResizeError::DispatchTimeout) => {
            bail!("远端未确认分辨率调整，已保留当前画面")
        }
        Err(ResizeError::Busy) => bail!("正在调整分辨率，请稍候"),
        Err(ResizeError::InvalidDimensions) => bail!("VNC 画面尺寸无效或过大"),
        Err(ResizeError::Disconnected) => bail!("VNC 会话已关闭"),
    }
}

pub(crate) async fn clipboard_active(id: u32, active: bool) -> Result<()> {
    let session = get(id).await?;
    session.clipboard.set_active(active);
    Ok(())
}

pub(crate) async fn clipboard_update(id: u32, text: Option<String>) -> Result<()> {
    let session = get(id).await?;
    let Some(text) = text else {
        return Ok(());
    };
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.len() > MAX_CLIPBOARD_TEXT {
        bail!("剪贴板文本超出 VNC 大小限制");
    }
    if !session.clipboard.prepare_local_send(&normalized) {
        return Ok(());
    }
    send(&session.client, X11Event::CopyText(normalized)).await
}

pub(crate) async fn clipboard_event(id: u32, after: u32) -> Result<Option<DesktopClipboardEvent>> {
    let session = get(id).await?;
    let mut events = session.clipboard.events.subscribe();
    let mut finished = session.finished.subscribe();
    {
        let current = events.borrow();
        if current.sequence != 0 && current.sequence != after {
            return Ok(Some(current.clone()));
        }
    }
    if *finished.borrow() || session.cancel.is_cancelled() {
        bail!("VNC 剪贴板已断开，请重新连接");
    }
    let wait = async {
        loop {
            tokio::select! {
                _ = session.cancel.cancelled() => bail!("VNC 剪贴板已断开，请重新连接"),
                _ = finished.wait_for(|done| *done) => bail!("VNC 剪贴板已断开，请重新连接"),
                changed = events.changed() => {
                    if changed.is_err() {
                        bail!("VNC 剪贴板已断开，请重新连接");
                    }
                    let current = events.borrow_and_update();
                    if current.sequence != 0 && current.sequence != after {
                        return Ok(Some(current.clone()));
                    }
                }
            }
        }
    };
    tokio::time::timeout(Duration::from_millis(500), wait)
        .await
        .unwrap_or(Ok(None))
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

async fn send_input_command(id: u32, command: InputCommand) -> Result<()> {
    let session = get(id).await?;
    let (reply, result) = oneshot::channel();
    tokio::time::timeout(INPUT_TIMEOUT, async {
        session
            .inputs
            .send(InputRequest { command, reply })
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
pub(crate) async fn input(
    id: u32,
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    anyhow::ensure!(kind <= 2, "VNC 输入类型无效");
    anyhow::ensure!(kind != 2 || text.len() <= 65536, "VNC 输入文本过长");
    send_input_command(
        id,
        InputCommand::Single {
            kind,
            code,
            flags,
            x,
            y,
            text,
        },
    )
    .await
}

pub(crate) async fn input_batch(id: u32, events: Vec<VncInputEvent>) -> Result<()> {
    if events.is_empty() {
        return Ok(());
    }
    anyhow::ensure!(events.len() <= MAX_INPUT_BATCH, "VNC 批量输入过多");
    send_input_command(id, InputCommand::Batch(events)).await
}

async fn apply_input_command(
    client: &VncClient,
    held: &mut HeldInputs,
    command: InputCommand,
) -> Result<()> {
    match command {
        InputCommand::Single {
            kind,
            code,
            flags,
            x,
            y,
            text,
        } => apply_input(client, held, kind, code, flags, x, y, text).await,
        InputCommand::Batch(events) => {
            for event in events {
                let kind = u8::from(event.pointer);
                apply_input(
                    client,
                    held,
                    kind,
                    event.code,
                    event.flags,
                    event.x,
                    event.y,
                    String::new(),
                )
                .await?;
            }
            Ok(())
        }
    }
}

fn map_keysym(code: u32, is_apple_server: bool) -> u32 {
    if !is_apple_server {
        return code;
    }
    // macOS Screen Sharing interprets Alt_L/Alt_R (0xffe9/0xffea) as Command and
    // Meta_L/Meta_R (0xffe7/0xffe8) as Option. Keep Super_L/Super_R as Command
    // and remap Alt to Option so both modifiers work natively on remote Macs.
    match code {
        0xffe9 => 0xffe7,
        0xffea => 0xffe8,
        _ => code,
    }
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
            let code = map_keysym(code, client.is_apple_server());
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
