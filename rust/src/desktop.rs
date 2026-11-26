use std::collections::{HashMap, VecDeque};
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicU8, Ordering};
use std::sync::{Arc, LazyLock};
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;

#[cfg(any(test, not(any(windows, target_os = "macos"))))]
use crate::api::desktop::DesktopFrame;
use crate::api::desktop::{DesktopCursor, DesktopHandshake, DesktopInputEvent};
use crate::desktop_clipboard::{Clipboard, Command as ClipboardCommand};
use crate::desktop_display::{DisplayControl, ResizeRequest};
use crate::desktop_frame::{FrameDelivery, FrameEncoder, FrameRequest};
use crate::desktop_frame_flow::FrameFlow;
use crate::desktop_transport::{Packet, PacketReader};
use crate::desktop_udp::Sideband;
use anyhow::{anyhow, bail, Context, Result};
use ironrdp::connector::{self, ClientConnector, Credentials};
use ironrdp::core::WriteBuf;
use ironrdp::dvc::{pdu::SoftSyncTunnelType, DrdynvcClient, DvcMessageBatch};
use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags, SynchronizeFlags};
use ironrdp::pdu::input::mouse::{MousePdu, PointerFlags};
use ironrdp::session::{ActiveStage, ActiveStageBuilder, ActiveStageOutput};
use ironrdp_egfx::client::{BitmapUpdate, GraphicsPipelineClient, GraphicsPipelineHandler};
use ironrdp_egfx::decode::{H264Decoder, OpenH264Decoder};
use ironrdp_egfx::pdu::{CacheToSurfacePdu, SolidFillPdu, SurfaceToSurfacePdu};
use ironrdp_tokio::{split_tokio_framed, FramedWrite, TokioFramed};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, WriteHalf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch, Mutex};
use tokio::time::Instant;
use tokio_rustls::{client::TlsStream, rustls, TlsConnector};
use x509_cert::der::Decode;

pub(crate) enum Transport {
    Direct(TcpStream),
    Ssh(russh::ChannelStream<russh::client::Msg>),
    Page(Box<crate::page::PageStream>),
    #[cfg(windows)]
    Pipe(tokio::net::windows::named_pipe::NamedPipeClient),
}
impl AsyncRead for Transport {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_read(cx, buf),
            Self::Ssh(s) => Pin::new(s).poll_read(cx, buf),
            Self::Page(s) => Pin::new(s).poll_read(cx, buf),
            #[cfg(windows)]
            Self::Pipe(s) => Pin::new(s).poll_read(cx, buf),
        }
    }
}
impl AsyncWrite for Transport {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_write(cx, buf),
            Self::Ssh(s) => Pin::new(s).poll_write(cx, buf),
            Self::Page(s) => Pin::new(s).poll_write(cx, buf),
            #[cfg(windows)]
            Self::Pipe(s) => Pin::new(s).poll_write(cx, buf),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_flush(cx),
            Self::Ssh(s) => Pin::new(s).poll_flush(cx),
            Self::Page(s) => Pin::new(s).poll_flush(cx),
            #[cfg(windows)]
            Self::Pipe(s) => Pin::new(s).poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_shutdown(cx),
            Self::Ssh(s) => Pin::new(s).poll_shutdown(cx),
            Self::Page(s) => Pin::new(s).poll_shutdown(cx),
            #[cfg(windows)]
            Self::Pipe(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}
type SessionStream = TlsStream<Transport>;
type Framed = TokioFramed<SessionStream>;
type Writer = TokioFramed<WriteHalf<SessionStream>>;
const TIMEOUT: Duration = Duration::from_secs(30);
const REDRAW_INTERVAL: Duration = Duration::from_secs(2);
static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Desktop>>>> = LazyLock::new(Default::default);

pub(crate) fn reserve_session_id() -> u32 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

struct Pending {
    connector: ClientConnector,
    upgraded: ironrdp_tokio::Upgraded,
    framed: Framed,
    public_key: Vec<u8>,
    host: String,
    display: DisplayControl,
    clipboard: Clipboard,
    graphics: GraphicsEvents,
    udp: Sideband,
}

struct SessionChannels {
    display: DisplayControl,
    clipboard: Clipboard,
    graphics: GraphicsEvents,
    udp: Sideband,
}
struct Desktop {
    fingerprint: String,
    pending: Mutex<Option<Pending>>,
    cancel: watch::Sender<bool>,
    gpu_disable: watch::Sender<bool>,
    commands: mpsc::Sender<Vec<FastPathInputEvent>>,
    receiver: Mutex<Option<mpsc::Receiver<Vec<FastPathInputEvent>>>>,
    frames: mpsc::Sender<FrameRequest>,
    requests: Mutex<Option<mpsc::Receiver<FrameRequest>>>,
    finished: watch::Sender<Option<String>>,
    resizes: mpsc::Sender<ResizeRequest>,
    resize_receiver: Mutex<Option<mpsc::Receiver<ResizeRequest>>>,
    clipboard: Clipboard,
}

const GRAPHICS_RESET: u8 = 1 << 0;
const GRAPHICS_CONTENT: u8 = 1 << 1;
const GRAPHICS_COMMITTED: u8 = 1 << 2;
const GRAPHICS_CLOSED: u8 = 1 << 3;

#[derive(Clone, Default)]
struct GraphicsEvents(Arc<AtomicU8>);

impl GraphicsEvents {
    fn take_transitions(&self) -> u8 {
        // Callbacks run inline in stage.process; only the session drains them.
        let clear = GRAPHICS_RESET | GRAPHICS_CLOSED;
        let state = self.0.load(Ordering::Relaxed);
        if state & clear != 0 {
            self.0.fetch_and(!clear, Ordering::Relaxed);
        }
        state
    }

    fn content(&self) {
        if self.0.load(Ordering::Relaxed) & GRAPHICS_CONTENT == 0 {
            self.0.fetch_or(GRAPHICS_CONTENT, Ordering::Relaxed);
        }
    }

    fn track(
        &self,
        stage: &mut ActiveStage,
        flow: &mut FrameFlow,
        recovery: &mut RedrawRecovery,
        started: Instant,
    ) -> u8 {
        let transitions = self.take_transitions();
        if transitions & GRAPHICS_CLOSED != 0 {
            // The old DVC no longer exists, so its queued ACKs cannot be sent.
            *flow = FrameFlow::default();
        }
        let drops = stage
            .get_dvc_mut::<GraphicsPipelineClient>()
            .map_or(0, |mut channel| {
                let id = channel.channel_id();
                let client = channel.processor_mut();
                flow.enqueue(id, client.take_frame_acks(), started);
                client.dropped_updates()
            });
        recovery.observe(stage.take_bitmap_recovery_request(), drops);
        transitions
    }
}

impl GraphicsPipelineHandler for GraphicsEvents {
    fn small_bitmap_cache(&self) -> bool {
        false
    }

    fn on_reset_graphics(&mut self, _: u32, _: u32) {
        self.0.store(GRAPHICS_RESET, Ordering::Relaxed);
    }

    fn on_bitmap_updated(&mut self, update: &BitmapUpdate) {
        if !update.data.is_empty() {
            self.content();
        }
    }

    fn needs_bitmap_pixels(&self) -> bool {
        false
    }

    fn on_compositor_pixels_applied(&mut self) {
        self.content();
    }

    fn on_solid_fill(&mut self, fill: &SolidFillPdu) {
        if !fill.rectangles.is_empty() {
            self.content();
        }
    }

    fn on_surface_to_surface(&mut self, copy: &SurfaceToSurfacePdu) {
        if !copy.destination_points.is_empty() {
            self.content();
        }
    }

    fn on_cache_to_surface(&mut self, copy: &CacheToSurfacePdu) {
        if !copy.destination_points.is_empty() {
            self.content();
        }
    }

    fn on_frame_complete(&mut self, _: u32) {
        let state = self.0.load(Ordering::Relaxed);
        if state & GRAPHICS_CONTENT != 0 && state & GRAPHICS_COMMITTED == 0 {
            self.0.fetch_or(GRAPHICS_COMMITTED, Ordering::Relaxed);
        }
    }

    fn on_close(&mut self) {
        self.0.fetch_or(GRAPHICS_CLOSED, Ordering::Relaxed);
    }
}

#[derive(Default)]
struct FrameAvailability {
    ready: bool,
    awaiting_egfx_content: bool,
}

impl FrameAvailability {
    fn update(&mut self, transitions: u8, has_damage: bool) {
        if transitions & GRAPHICS_RESET != 0 {
            self.ready = false;
            self.awaiting_egfx_content = true;
        }
        if transitions & (GRAPHICS_COMMITTED | GRAPHICS_CLOSED) != 0 {
            self.awaiting_egfx_content = false;
        }
        // MapSurfaceToOutput can dirty a zero-filled surface on its own. Only
        // resume presenting after a pixel update is committed to the output.
        self.ready |= has_damage && !self.awaiting_egfx_content;
    }
}

struct RedrawRecovery {
    pending: bool,
    next_at: Instant,
    egfx_drops: u64,
    refresh_rect: bool,
    suppress_output: bool,
}

impl RedrawRecovery {
    fn new(refresh_rect: bool, suppress_output: bool) -> Self {
        Self {
            pending: false,
            next_at: Instant::now(),
            egfx_drops: 0,
            refresh_rect,
            suppress_output,
        }
    }

    fn observe(&mut self, bitmap_discarded: bool, egfx_drops: u64) {
        self.pending |= (self.refresh_rect || self.suppress_output)
            && (bitmap_discarded || egfx_drops > self.egfx_drops);
        self.egfx_drops = egfx_drops;
    }

    fn sent(&mut self) {
        self.pending = false;
        self.next_at = Instant::now() + REDRAW_INTERVAL;
    }
}

fn graphics_pipeline(graphics: GraphicsEvents) -> GraphicsPipelineClient {
    // A server may send independent H.264 streams on different surfaces.
    // The bundled decoder exposes YUV planes, allowing AVC444 and AVC444v2.
    let new_decoder = || {
        OpenH264Decoder::new()
            .ok()
            .map(|decoder| Box::new(decoder) as Box<dyn H264Decoder>)
    };
    let shared_decoder = || -> Option<Box<dyn H264Decoder>> {
        let software = OpenH264Decoder::new().ok()?;
        #[cfg(any(windows, target_os = "macos", target_os = "linux"))]
        if std::env::var_os("PAGASHELL_RDP_HWDEC").as_deref() == Some("1".as_ref()) {
            return Some(Box::new(crate::desktop_h264::NativeFallback::new(
                software,
                crate::desktop_h264::open_native,
            )));
        }
        Some(Box::new(software))
    };
    GraphicsPipelineClient::new(Box::new(graphics), shared_decoder())
        .with_h264_decoder_factory(Box::new(new_decoder))
}

pub(crate) async fn prepare(
    host: String,
    port: u16,
    ssh_gateway: Option<u32>,
) -> Result<DesktopHandshake> {
    prepare_with_page(host, port, ssh_gateway, None).await
}

pub(crate) async fn prepare_with_page(
    host: String,
    port: u16,
    ssh_gateway: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<DesktopHandshake> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    prepare_inner(deadline, async move {
        let stream = if let Some(gateway) = page_gateway {
            Transport::Page(Box::new(
                crate::page::connect(gateway, &host, port, deadline).await?,
            ))
        } else if let Some(id) = ssh_gateway {
            Transport::Ssh(crate::api::ssh::desktop_tunnel(id, host.clone(), port).await?)
        } else {
            let tcp = TcpStream::connect((host.as_str(), port))
                .await
                .context("RDP TCP 连接失败")?;
            tcp.set_nodelay(true)?;
            Transport::Direct(tcp)
        };
        Ok((host, stream))
    })
    .await
}

#[cfg(windows)]
pub(crate) async fn prepare_transport(host: String, stream: Transport) -> Result<DesktopHandshake> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    prepare_inner(deadline, async move { Ok((host, stream)) }).await
}

async fn prepare_inner(
    deadline: tokio::time::Instant,
    open_stream: impl std::future::Future<Output = Result<(String, Transport)>>,
) -> Result<DesktopHandshake> {
    let pending = tokio::time::timeout_at(deadline, async {
        let (host, stream) = open_stream.await?;
        let udp_peer = match &stream {
            Transport::Direct(tcp)
                if std::env::var_os("PAGASHELL_RDP_UDP").as_deref() == Some("1".as_ref()) =>
            {
                tcp.peer_addr().ok()
            }
            _ => None,
        };
        let mut config = crate::rdp::config();
        if udp_peer.is_some() {
            config.multitransport_flags = Some(crate::desktop_udp::advertised_flags());
        }
        config.desktop_size = connector::DesktopSize {
            width: 1280,
            height: 800,
        };
        config.bitmap = Some(connector::BitmapConfig {
            color_depth: 32,
            lossy_compression: true,
            codecs: ironrdp::pdu::rdp::capability_sets::client_codecs_capabilities(&[])
                .map_err(|e| anyhow!(e))?,
        });
        // Cursor shapes are sent separately and positioned locally by Flutter.
        // Moving the pointer must not trigger full framebuffer transfers.
        config.enable_server_pointer = true;
        config.pointer_software_rendering = false;
        config.support_dyn_vc_gfx_protocol = true;
        config.enable_gdi_caches =
            std::env::var_os("PAGASHELL_RDP_GDI_CACHE").as_deref() != Some("0".as_ref());
        let mut connector = ClientConnector::new(config, "0.0.0.0:0".parse()?);
        let display = DisplayControl::default();
        let clipboard = Clipboard::new();
        let graphics = GraphicsEvents::default();
        connector.attach_static_channel(clipboard.client());
        connector.attach_static_channel(
            DrdynvcClient::new()
                .with_dynamic_channel(
                    graphics_pipeline(graphics.clone())
                        .with_deferred_frame_acks()
                        .with_direct_output()
                        .with_opaque_surface_base(),
                )
                .with_dynamic_channel(display.client()),
        );
        let mut framed = TokioFramed::new(stream);
        let upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
            .await
            .context("RDP 安全协议协商失败")?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = Arc::new(crate::rdp::FingerprintVerifier::new(provider.clone()));
        let mut tls_config = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()?
            .dangerous()
            .with_custom_certificate_verifier(verifier.clone())
            .with_no_client_auth();
        tls_config.resumption = rustls::client::Resumption::disabled();
        let tls = TlsConnector::from(Arc::new(tls_config))
            .connect(
                rustls::pki_types::ServerName::try_from(host.clone())?,
                framed.into_inner_no_leftover(),
            )
            .await
            .context("RDP TLS 握手失败")?;
        let cert = tls
            .get_ref()
            .1
            .peer_certificates()
            .and_then(|c| c.first())
            .context("RDP 服务器未提供证书")?;
        let udp = match udp_peer {
            Some(peer) => Sideband::direct(peer, host.clone(), cert.clone())?,
            None => Sideband::default(),
        };
        let fingerprint = format!(
            "SHA256:{}",
            Sha256::digest(cert.as_ref())
                .iter()
                .map(|b| format!("{b:02X}"))
                .collect::<Vec<_>>()
                .join(":")
        );
        let cert = x509_cert::Certificate::from_der(cert.as_ref()).context("RDP 证书解析失败")?;
        let public_key = cert
            .tbs_certificate
            .subject_public_key_info
            .subject_public_key
            .as_bytes()
            .context("RDP 证书公钥无效")?
            .to_vec();
        let upgraded = ironrdp_tokio::mark_as_upgraded(upgrade, &mut connector);
        Ok::<_, anyhow::Error>((
            Pending {
                connector,
                upgraded,
                framed: TokioFramed::new(tls),
                public_key,
                host,
                display,
                clipboard,
                graphics,
                udp,
            },
            fingerprint,
            verifier.certificate_error(),
        ))
    })
    .await
    .map_err(|_| anyhow!("RDP 服务连接超时"))?
    .map_err(|error| anyhow!("RDP 服务连接失败：{error:#}"))?;
    let id = reserve_session_id();
    let (commands, receiver) = mpsc::channel(256);
    let (frames, requests) = mpsc::channel(4);
    let (resizes, resize_receiver) = mpsc::channel(4);
    let fingerprint = pending.1;
    let clipboard = pending.0.clipboard.clone();
    let entry = Arc::new(Desktop {
        fingerprint: fingerprint.clone(),
        pending: Mutex::new(Some(pending.0)),
        cancel: watch::channel(false).0,
        gpu_disable: watch::channel(false).0,
        commands,
        receiver: Mutex::new(Some(receiver)),
        frames,
        requests: Mutex::new(Some(requests)),
        finished: watch::channel(None).0,
        resizes,
        resize_receiver: Mutex::new(Some(resize_receiver)),
        clipboard,
    });
    let weak = Arc::downgrade(&entry);
    SESSIONS.lock().await.insert(id, entry);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(180)).await;
        if let Some(entry) = weak.upgrade() {
            let pending = entry.pending.lock().await.is_some();
            if pending {
                disconnect(id).await;
            }
        }
    });
    Ok(DesktopHandshake {
        session_id: id,
        fingerprint,
        certificate_error: pending.2,
    })
}

async fn session(id: u32) -> Result<Arc<Desktop>> {
    SESSIONS
        .lock()
        .await
        .get(&id)
        .cloned()
        .context("RDP 会话已关闭")
}

#[cfg(test)]
pub(crate) async fn authenticate(
    id: u32,
    expected: String,
    username: String,
    password: String,
    domain: String,
    preferences: crate::rdp::ClientPreferences,
) -> Result<()> {
    authenticate_with_gpu(id, expected, username, password, domain, preferences, None).await
}

pub(crate) async fn authenticate_with_gpu(
    id: u32,
    expected: String,
    username: String,
    password: String,
    domain: String,
    preferences: crate::rdp::ClientPreferences,
    gpu_adapter_luid: Option<u64>,
) -> Result<()> {
    let entry = session(id).await?;
    if entry.fingerprint != expected {
        disconnect(id).await;
        bail!("RDP 证书未获信任，已拒绝认证");
    }
    let pending = entry
        .pending
        .lock()
        .await
        .take()
        .context("RDP 会话已经认证或已关闭")?;
    let mut cancel = entry.cancel.subscribe();
    let gpu_disable = entry.gpu_disable.subscribe();
    if *cancel.borrow() {
        bail!("连接已取消");
    }
    let task = async {
        let Pending {
            mut connector,
            upgraded,
            mut framed,
            public_key,
            host,
            display,
            clipboard,
            graphics,
            mut udp,
        } = pending;
        connector.config.credentials = Credentials::UsernamePassword { username, password };
        connector.config.domain = (!domain.is_empty()).then_some(domain);
        preferences.apply_to(&mut connector.config);
        let result = crate::rdp_connection::finalize(
            upgraded,
            connector,
            &mut framed,
            host,
            public_key,
            &mut udp,
        )
        .await?;
        Ok::<_, anyhow::Error>((result, framed, display, clipboard, graphics, udp))
    };
    let result = tokio::select! { biased;
        _ = cancel.changed() => Err(anyhow!("连接已取消")),
        result = task => result,
    };
    let (result, framed, display, clipboard, graphics, udp) = match result {
        Ok(value) => value,
        Err(error) => {
            disconnect(id).await;
            return Err(error);
        }
    };
    let commands = entry
        .receiver
        .lock()
        .await
        .take()
        .context("RDP 会话已关闭")?;
    let requests = entry
        .requests
        .lock()
        .await
        .take()
        .context("RDP 会话已关闭")?;
    let resizes = entry
        .resize_receiver
        .lock()
        .await
        .take()
        .context("RDP 会话已关闭")?;
    start_session(
        entry,
        run(
            result,
            framed,
            commands,
            cancel,
            gpu_disable,
            requests,
            SessionChannels {
                display,
                clipboard,
                graphics,
                udp,
            },
            resizes,
            gpu_adapter_luid,
        ),
    );
    Ok(())
}

pub(crate) async fn disable_gpu(id: u32) {
    if let Ok(entry) = session(id).await {
        entry.gpu_disable.send_replace(true);
    }
}

fn start_session(
    entry: Arc<Desktop>,
    session: impl std::future::Future<Output = Result<()>> + Send + 'static,
) {
    let worker = tokio::spawn(session);
    tokio::spawn(async move {
        let reason = match worker.await {
            Ok(Err(error)) => format!("RDP 会话运行失败：{error:#}").replace('\n', " "),
            Ok(Ok(())) => "远程桌面已断开，请重新连接".into(),
            // Do not expose panic payloads, which may contain arbitrary data.
            Err(_) => "RDP 会话处理异常，请重新连接".into(),
        };
        entry.clipboard.cancel();
        entry.finished.send_replace(Some(reason));
    });
}

async fn session_end(entry: &Desktop) -> anyhow::Error {
    let mut finished = entry.finished.subscribe();
    let mut cancel = entry.cancel.subscribe();
    loop {
        if *cancel.borrow() {
            return anyhow!("RDP 会话已关闭");
        }
        if let Some(reason) = finished.borrow().as_ref() {
            return anyhow!(reason.clone());
        }
        tokio::select! {
            _ = cancel.changed() => {},
            result = finished.changed() => {
                if result.is_err() {
                    return anyhow!("远程桌面已断开，请重新连接");
                }
            }
        }
    }
}

pub(crate) async fn frame_delivery(id: u32, after: u32) -> Result<Option<FrameDelivery>> {
    let entry = session(id).await?;
    let (reply, receiver) = oneshot::channel();
    let wait = async {
        entry
            .frames
            .send(FrameRequest { after, reply })
            .await
            .map_err(|_| ())?;
        receiver.await.map(Some).map_err(|_| ())
    };
    tokio::select! {
        biased;
        error = session_end(&entry) => Err(error),
        result = tokio::time::timeout(Duration::from_millis(500), wait) => match result {
            Ok(Ok(frame)) => Ok(frame),
            // The worker drops its channels before its result is observed.
            // Wait for that result instead of racing it with a generic error.
            Ok(Err(())) => Err(session_end(&entry).await),
            Err(_) => Ok(None),
        },
    }
}

#[cfg(any(test, not(any(windows, target_os = "macos"))))]
pub(crate) async fn frame(id: u32, after: u32) -> Result<Option<DesktopFrame>> {
    Ok(frame_delivery(id, after)
        .await?
        .map(|delivery| delivery.frame))
}

pub(crate) async fn resize(id: u32, width: u16, height: u16) -> Result<bool> {
    DisplayControl::validate_size(width, height)?;
    let entry = session(id).await?;
    let (reply, receiver) = oneshot::channel();
    let request = async {
        entry
            .resizes
            .send(ResizeRequest {
                width,
                height,
                reply,
            })
            .await
            .map_err(|_| ())?;
        receiver.await.map_err(|_| ())
    };
    tokio::select! {
        biased;
        error = session_end(&entry) => Err(error),
        result = tokio::time::timeout(Duration::from_secs(8), request) => match result {
            Ok(Ok(result)) => result,
            Ok(Err(())) => Err(session_end(&entry).await),
            Err(_) => Err(anyhow!("RDP 分辨率调整超时，请重试")),
        },
    }
}

pub(crate) async fn input(
    id: u32,
    kind: u8,
    code: u16,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    let events = input_events(kind, code, flags, x, y, text)?;
    send_inputs(id, events).await
}

pub(crate) async fn input_batch(id: u32, events: Vec<DesktopInputEvent>) -> Result<()> {
    if events.is_empty() || events.len() > 32 {
        bail!("无效的 RDP 输入");
    }
    let events = events
        .into_iter()
        .map(|event| input_event(event.pointer, event.code, event.flags, event.x, event.y))
        .collect::<Result<Vec<_>>>()?;
    send_inputs(id, events).await
}

async fn send_inputs(id: u32, events: Vec<FastPathInputEvent>) -> Result<()> {
    let entry = session(id).await?;
    // Never drop a key/button release. Backpressure is bounded by a timeout.
    tokio::select! {
        biased;
        error = session_end(&entry) => Err(error),
        result = tokio::time::timeout(Duration::from_secs(2), entry.commands.send(events)) => {
            match result.context("RDP 输入队列超时")? {
                Ok(()) => Ok(()),
                Err(_) => Err(session_end(&entry).await),
            }
        }
    }
}
fn input_events(
    kind: u8,
    code: u16,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<Vec<FastPathInputEvent>> {
    Ok(match kind {
        0 | 1 => vec![input_event(kind == 1, code, flags, x, y)?],
        2 => {
            if text.len() > 8192 {
                bail!("RDP 文本过长");
            }
            let mut input = text.encode_utf16().peekable();
            let mut events = Vec::with_capacity(text.len() * 2);
            while let Some(c) = input.next() {
                if c == u16::from(b'\r') && input.peek() == Some(&u16::from(b'\n')) {
                    input.next();
                }
                match c {
                    0x09 | 0x0a | 0x0d => {
                        let scan = if c == 0x09 { 0x0f } else { 0x1c };
                        events.extend([
                            FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), scan),
                            FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, scan),
                        ]);
                    }
                    _ => events.extend([
                        FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), c),
                        FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, c),
                    ]),
                }
            }
            events
        }
        3 => vec![FastPathInputEvent::SyncEvent(
            u8::try_from(flags)
                .ok()
                .and_then(SynchronizeFlags::from_bits)
                .context("无效的 RDP 锁定键状态")?,
        )],
        _ => bail!("无效的 RDP 输入"),
    })
}

fn input_event(pointer: bool, code: u16, flags: u16, x: u16, y: u16) -> Result<FastPathInputEvent> {
    if !pointer {
        if code > 255 || flags & !7 != 0 {
            bail!("无效的 RDP 按键");
        }
        return Ok(FastPathInputEvent::KeyboardEvent(
            KeyboardFlags::from_bits_retain(flags as u8),
            code as u8,
        ));
    }
    let flags = PointerFlags::from_bits(flags).context("无效的 RDP 鼠标事件")?;
    let wheel = code.min(255) as i16;
    Ok(FastPathInputEvent::MouseEvent(MousePdu {
        x_position: x,
        y_position: y,
        flags,
        number_of_wheel_rotation_units: if flags.contains(PointerFlags::WHEEL_NEGATIVE) {
            -wheel
        } else {
            wheel
        },
    }))
}
pub(crate) async fn disconnect(id: u32) {
    let entry = SESSIONS.lock().await.remove(&id);
    if let Some(entry) = entry {
        entry.cancel.send_replace(true);
        entry.clipboard.cancel();
        entry.pending.lock().await.take();
        entry.receiver.lock().await.take();
        entry.requests.lock().await.take();
        entry.resize_receiver.lock().await.take();
    }
}

#[cfg(windows)]
pub(crate) async fn disconnect_worker(id: u32) {
    let Ok(entry) = session(id).await else {
        return;
    };
    let active = entry.receiver.lock().await.is_none();
    let mut finished = entry.finished.subscribe();
    disconnect(id).await;
    if active {
        // Allow the active loop to send its held-key/button releases.
        let _ = tokio::time::timeout(
            Duration::from_millis(650),
            finished.wait_for(Option::is_some),
        )
        .await;
    }
}

#[cfg(any(windows, test))]
pub(crate) async fn probe(id: u32) -> Result<()> {
    let entry = session(id).await?;
    let barrier = entry.clipboard.barrier()?;
    tokio::select! {
        biased;
        error = session_end(&entry) => Err(error),
        result = barrier => result.context("RDP 会话已结束"),
    }
}

pub(crate) async fn clipboard_active(id: u32, active: bool, directory: String) -> Result<()> {
    session(id).await?.clipboard.active(active, directory).await
}

pub(crate) async fn clipboard_update(
    id: u32,
    text: Option<String>,
    files: Vec<String>,
) -> Result<()> {
    let entry = session(id).await?;
    tokio::select! {
        error = session_end(&entry) => Err(error),
        result = entry.clipboard.update(text, files) => result,
    }
}

pub(crate) async fn clipboard_event(
    id: u32,
    after: u32,
) -> Result<Option<crate::api::desktop::DesktopClipboardEvent>> {
    let entry = session(id).await?;
    tokio::select! {
        error = session_end(&entry) => Err(error),
        result = entry.clipboard.next(after) => Ok(result),
    }
}

pub(crate) async fn clipboard_cancel(id: u32) -> Result<()> {
    session(id).await?.clipboard.cancel();
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run(
    result: connector::ConnectionResult,
    framed: Framed,
    commands: mpsc::Receiver<Vec<FastPathInputEvent>>,
    cancel: watch::Receiver<bool>,
    gpu_disable: watch::Receiver<bool>,
    requests: mpsc::Receiver<FrameRequest>,
    channels: SessionChannels,
    resizes: mpsc::Receiver<ResizeRequest>,
    gpu_adapter_luid: Option<u64>,
) -> Result<()> {
    #[cfg(windows)]
    let _timer = RdpTimerResolution::new();
    let (reader, writer) = split_tokio_framed(framed);
    let reader = PacketReader::spawn(reader);
    let writer = Arc::new(Mutex::new(writer));
    let (stop_input, input_stop) = watch::channel(false);
    let mut input = tokio::spawn(crate::desktop_input::write_to_peer(
        Arc::clone(&writer),
        commands,
        cancel.clone(),
        input_stop,
        TIMEOUT,
    ));
    tokio::select! {
        result = run_stage(
            result,
            reader,
            &writer,
            cancel,
            gpu_disable,
            requests,
            channels,
            resizes,
            gpu_adapter_luid,
        ) => {
            let _ = stop_input.send(true);
            if tokio::time::timeout(Duration::from_millis(750), &mut input).await.is_err() {
                input.abort();
            }
            result
        }
        result = &mut input => result.context("RDP 输入任务异常退出")?,
    }
}

fn attach_gpu_compositor(stage: &mut ActiveStage, gpu_adapter_luid: Option<u64>) {
    let Some(luid) = gpu_adapter_luid else {
        return;
    };
    let Some(mut channel) = stage.get_dvc_mut::<GraphicsPipelineClient>() else {
        return;
    };
    let gfx = channel.processor_mut();
    #[cfg(target_os = "macos")]
    {
        let _ = luid;
        if let Some(compositor) = ironrdp_egfx_native::MetalGpuCompositor::new() {
            gfx.set_gpu_compositor(Some(Box::new(compositor)));
            tracing::debug!("Enabled Metal GPU-direct EGFX compositor");
        }
    }
    #[cfg(windows)]
    {
        match ironrdp_egfx_native::D3D11GpuCompositor::new(Some(luid)) {
            Ok(compositor) => {
                let opener = compositor.decoder_opener();
                gfx.set_gpu_compositor(Some(Box::new(compositor)));
                if std::env::var_os("PAGASHELL_RDP_HWDEC").as_deref() == Some("1".as_ref()) {
                    let shared = OpenH264Decoder::new().ok().map(|software| {
                        let opener = opener.clone();
                        Box::new(crate::desktop_h264::NativeFallback::new(
                            software,
                            move || opener.open(ironrdp_egfx_native::YuvMatrix::Bt709Full),
                        )) as Box<dyn H264Decoder>
                    });
                    let factory_opener = opener;
                    let factory: ironrdp_egfx::decode::DecoderFactory = Box::new(move || {
                        let software = OpenH264Decoder::new().ok()?;
                        let opener = factory_opener.clone();
                        Some(Box::new(crate::desktop_h264::NativeFallback::new(
                            software,
                            move || opener.open(ironrdp_egfx_native::YuvMatrix::Bt709Full),
                        )) as Box<dyn H264Decoder>)
                    });
                    gfx.set_h264_decoder(shared, Some(factory));
                }
                tracing::debug!(luid, "Enabled D3D11 GPU-direct EGFX compositor");
            }
            Err(error) => {
                tracing::debug!(%error, luid, "D3D11 GPU-direct EGFX compositor unavailable; using CPU path");
            }
        }
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (luid, gfx);
    }
}

async fn request_gpu_fallback(
    stage: &mut ActiveStage,
    writer: &Mutex<Writer>,
    udp: &Sideband,
    encoder: &mut FrameEncoder,
    recovery: &mut RedrawRecovery,
    image: &ironrdp::session::image::DecodedImage,
) -> Result<()> {
    let reset_batch = stage
        .get_dvc_mut::<GraphicsPipelineClient>()
        .and_then(|mut channel| {
            let channel_id = channel.channel_id();
            let gfx = channel.processor_mut();
            gfx.set_gpu_compositor(None);
            let pdu = gfx.request_protocol_reset()?;
            let messages = ironrdp::dvc::encode_dvc_messages(
                channel_id,
                vec![Box::new(pdu) as ironrdp::dvc::DvcMessage],
                ironrdp::svc::ChannelFlags::empty(),
            )
            .ok()?;
            DvcMessageBatch::try_new(channel_id, messages).ok()
        });
    if let Some(batch) = reset_batch {
        send_dvc(stage, writer, udp, batch, false)
            .await
            .context("RDP GPU 回退重置发送失败")?;
    } else if recovery.refresh_rect || recovery.suppress_output {
        recovery.pending = true;
    }
    encoder.invalidate(image.width(), image.height());
    Ok(())
}

#[cfg(windows)]
struct RdpTimerResolution(bool);

#[cfg(windows)]
impl RdpTimerResolution {
    fn new() -> Self {
        Self(unsafe { windows_sys::Win32::Media::timeBeginPeriod(1) } == 0)
    }
}

#[cfg(windows)]
impl Drop for RdpTimerResolution {
    fn drop(&mut self) {
        if self.0 {
            unsafe { windows_sys::Win32::Media::timeEndPeriod(1) };
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_stage(
    result: connector::ConnectionResult,
    mut reader: PacketReader,
    writer: &Mutex<Writer>,
    mut cancel: watch::Receiver<bool>,
    mut gpu_disable: watch::Receiver<bool>,
    mut requests: mpsc::Receiver<FrameRequest>,
    channels: SessionChannels,
    mut resizes: mpsc::Receiver<ResizeRequest>,
    gpu_adapter_luid: Option<u64>,
) -> Result<()> {
    let SessionChannels {
        display,
        clipboard,
        graphics,
        mut udp,
    } = channels;
    let mut clipboard_commands = clipboard.receiver();
    let mut clipboard_tick = tokio::time::interval(Duration::from_secs(5));
    clipboard_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let soft_sync = result.multitransport_soft_sync();
    let activation_factory = result.activation_factory;
    let mut image = crate::rdp::new_image(result.desktop_size)?;
    let mut recovery =
        RedrawRecovery::new(result.refresh_rect_support, result.suppress_output_support);
    let mut stage = ActiveStageBuilder {
        static_channels: result.static_channels,
        user_channel_id: result.user_channel_id,
        io_channel_id: result.io_channel_id,
        message_channel_id: result.message_channel_id,
        share_id: result.share_id,
        compression_type: result.compression_type,
        enable_server_pointer: true,
        pointer_software_rendering: false,
    }
    .build();
    attach_gpu_compositor(&mut stage, gpu_adapter_luid);
    if udp.transport.is_some() {
        stage.enable_reliable_udp_dvc_tunnel()?;
    }
    let mut encoder = FrameEncoder::new(image.width(), image.height());
    let mut availability = FrameAvailability::default();
    let mut waiting: VecDeque<FrameRequest> = VecDeque::new();
    let mut flow = FrameFlow::default();
    let diagnostics = crate::desktop_diagnostics::GraphicsDiagnostics::new();
    let mut pending_resize: Option<ResizeRequest> = None;
    let mut resize_deadline = Instant::now();
    let mut pending_gpu_frame: Option<Box<dyn ironrdp_egfx::gpu::GpuPresentedFrame>> = None;
    let mut gpu_disabled = false;
    loop {
        if *cancel.borrow() {
            break;
        }
        if let Some(batch) = flow.take_ready(Instant::now(), false)? {
            send_dvc(&mut stage, writer, &udp, batch, false)
                .await
                .context("RDP 帧确认发送失败")?;
        }
        if let Some(request) = pending_resize.as_ref() {
            if request.reply.is_closed() {
                pending_resize = None;
            } else if let Some(encoded) =
                display.prepare_resize(&mut stage, request.width, request.height)
            {
                let request = pending_resize.take().unwrap();
                match encoded {
                    Ok(batch) => {
                        send_dvc(&mut stage, writer, &udp, batch, false)
                            .await
                            .context("RDP 分辨率请求发送失败")?;
                        let _ = request.reply.send(Ok(true));
                    }
                    Err(error) => {
                        let _ = request.reply.send(Err(error));
                    }
                }
            }
        }
        waiting.retain(|request| !request.reply.is_closed());
        let can_render = availability.ready
            && waiting
                .front()
                .is_some_and(|request| pending_gpu_frame.is_some() || encoder.ready(request.after));
        let mut transitions = 0;
        let ack_deadline = flow.deadline();
        let outputs = tokio::select! {
                _ = cancel.changed() => break,
                _ = gpu_disable.changed(), if !gpu_disabled => {
                    if *gpu_disable.borrow() {
                        gpu_disabled = true;
                        pending_gpu_frame = None;
                        request_gpu_fallback(&mut stage, writer, &udp, &mut encoder, &mut recovery, &image).await?;
                    }
                    continue;
                }
                command = clipboard_commands.recv() => {
                    match command {
                        Some(ClipboardCommand::Protocol(message)) => clipboard.process(&mut stage, message),
                        Some(ClipboardCommand::Publish(local)) => clipboard.publish(&mut stage, local),
                        Some(ClipboardCommand::Barrier(reply)) => { let _ = reply.send(()); continue; }
                        None => break,
                    }
                }
                _ = clipboard_tick.tick() => clipboard.timeouts(&mut stage),
                request = resizes.recv(), if pending_resize.is_none() => {
                    let Some(request) = request else { break; };
                    pending_resize = Some(request);
                    resize_deadline = Instant::now() + Duration::from_secs(3);
                    continue;
                }
                _ = tokio::time::sleep_until(resize_deadline), if pending_resize.is_some() => {
                    let request = pending_resize.take().unwrap();
                    let _ = request.reply.send(Ok(false));
                    continue;
                }
                _ = std::future::ready(()), if can_render => {
                    let request = waiting.pop_front().unwrap();
                    if !request.reply.is_closed() {
                        let delivery = if let Some(gpu_frame) = pending_gpu_frame.take() {
                            let frame = encoder.snapshot_gpu(
                                gpu_frame.width(),
                                gpu_frame.height(),
                                request.after,
                            );
                            FrameDelivery {
                                frame,
                                gpu: Some(gpu_frame),
                            }
                        } else {
                            FrameDelivery {
                                frame: encoder.snapshot(&image, request.after),
                                gpu: None,
                            }
                        };
                        let sequence = delivery.frame.sequence;
                        if request.reply.send(delivery).is_ok() {
                            flow.delivered(sequence);
                        }
                    }
                    continue;
                }
                request = requests.recv(), if waiting.len() < 4 => {
                    let Some(request) = request else { return Ok(()); };
                    flow.consume(request.after);
                    waiting.push_back(request);
                    continue;
                }
                _ = async { tokio::time::sleep_until(ack_deadline.unwrap()).await }, if ack_deadline.is_some() => continue,
                _ = async { waiting.front_mut().unwrap().reply.closed().await }, if !waiting.is_empty() => continue,
                _ = tokio::time::sleep_until(recovery.next_at), if recovery.pending => {
                    let redraw = stage.request_full_redraw(
                        image.width(), image.height(), recovery.refresh_rect, recovery.suppress_output,
                    ).context("RDP 无法请求重绘")?;
                    tokio::time::timeout(TIMEOUT, async {
                        let mut writer = writer.lock().await;
                        for frame in redraw {
                            writer.write_all(&frame).await?;
                        }
                        Ok::<_, std::io::Error>(())
                    }).await.context("RDP 重绘请求发送超时")?.context("RDP 重绘请求发送失败")?;
                    recovery.sent();
                    continue;
                }
                packet = reader.read() => {
                    let Packet { action, bytes, received_at } = packet.context("RDP 数据接收失败")?;
                    let ack_started = Instant::now();
                    let outputs = diagnostics.process(|| stage.process(&mut image, action, &bytes, received_at))?;
                    transitions = graphics.track(&mut stage, &mut flow, &mut recovery, ack_started);
                    outputs
                }
                packet = udp.recv() => {
                    let Some(packet) = packet else {
                        if stage.reliable_udp_dvc_tunnel_in_use() {
                            bail!("RDP UDP 通道已断开，请重新连接");
                        }
                        udp.transport = None;
                        stage.disable_reliable_udp_dvc_tunnel()?;
                        continue;
                    };
                    // An RDPEMT datagram can carry only tunnel metadata.
                    if packet.is_empty() {
                        continue;
                    }
                    let ack_started = Instant::now();
                    let (batch, outputs) = diagnostics.process(|| {
                        stage.process_dvc_tunnel(&mut image, SoftSyncTunnelType::RELIABLE_UDP, &packet)
                    })?;
                    send_dvc(&mut stage, writer, &udp, batch, true).await?;
                    transitions = graphics.track(&mut stage, &mut flow, &mut recovery, ack_started);
                    outputs
                }
        };
        // EGFX may resize independently of connection reactivation. Enforce the
        // same pixel budget as the initial framebuffer and Flutter consumer.
        crate::rdp::validate_desktop_size(image.width(), image.height())?;
        if transitions & GRAPHICS_RESET != 0 {
            pending_gpu_frame = None;
            encoder.invalidate(image.width(), image.height());
        }
        let mut gpu_failed = false;
        if let Some(mut channel) = stage.get_dvc_mut::<GraphicsPipelineClient>() {
            let gfx = channel.processor_mut();
            gpu_failed = gfx.take_gpu_failed();
            if let Some(gpu_frame) = gfx.take_gpu_frame() {
                pending_gpu_frame = Some(gpu_frame);
            }
        }
        if gpu_failed {
            gpu_disabled = true;
            pending_gpu_frame = None;
            request_gpu_fallback(
                &mut stage,
                writer,
                &udp,
                &mut encoder,
                &mut recovery,
                &image,
            )
            .await?;
        }
        // EGFX reports a bounding rectangle in GraphicsUpdate and preserves the
        // exact regions separately. Keep those regions separate through to Dart.
        let damage = stage.take_damage_regions();
        let exact_damage = !damage.is_empty();
        let has_damage = pending_gpu_frame.is_some()
            || exact_damage
            || outputs
                .iter()
                .any(|output| matches!(output, ActiveStageOutput::GraphicsUpdate(_)));
        availability.update(transitions, has_damage);
        for rect in damage {
            encoder.damage(rect);
        }
        for output in outputs {
            match output {
                ActiveStageOutput::ResponseFrame(bytes) => tokio::time::timeout(TIMEOUT, async {
                    writer.lock().await.write_all(&bytes).await
                })
                .await
                .context("RDP 响应发送超时")?
                .context("RDP 响应发送失败")?,
                ActiveStageOutput::GraphicsUpdate(rect) if !exact_damage => encoder.damage(rect),
                ActiveStageOutput::PointerDefault | ActiveStageOutput::PointerHidden => {
                    encoder.cursor(DesktopCursor {
                        kind: if matches!(output, ActiveStageOutput::PointerHidden) {
                            1
                        } else {
                            0
                        },
                        width: 0,
                        height: 0,
                        hotspot_x: 0,
                        hotspot_y: 0,
                        rgba: Vec::new(),
                    });
                }
                ActiveStageOutput::PointerBitmap(pointer) => {
                    let mut rgba = pointer.bitmap_data.clone();
                    // Flutter's rgba8888 images use premultiplied alpha.
                    for pixel in rgba.as_chunks_mut::<4>().0 {
                        let alpha = u16::from(pixel[3]);
                        for channel in &mut pixel[..3] {
                            *channel = ((u16::from(*channel) * alpha + 127) / 255) as u8;
                        }
                    }
                    encoder.cursor(DesktopCursor {
                        kind: if pointer.width == 0 || pointer.height == 0 {
                            1
                        } else {
                            2
                        },
                        width: pointer.width,
                        height: pointer.height,
                        hotspot_x: pointer.hotspot_x,
                        hotspot_y: pointer.hotspot_y,
                        rgba,
                    });
                }
                ActiveStageOutput::Terminate(reason) => bail!("RDP 服务器结束了会话：{reason}"),
                ActiveStageOutput::DeactivateAll => {
                    if let Some(batch) = flow.take_ready(Instant::now(), true)? {
                        send_dvc(&mut stage, writer, &udp, batch, false)
                            .await
                            .context("RDP 帧确认发送失败")?;
                    }
                    let mut activation = activation_factory.create();
                    let mut buf = WriteBuf::new();
                    tokio::time::timeout(TIMEOUT, async {
                        // Keep input out of the reactivation exchange.
                        let mut writer = writer.lock().await;
                        loop {
                            let written = reader.activation_step(&mut activation, &mut buf).await?;
                            if written.size().is_some() {
                                writer.write_all(buf.filled()).await?;
                            }
                            use connector::connection_activation::ConnectionActivationState;
                            if let ConnectionActivationState::Finalized {
                                desktop_size,
                                share_id,
                                enable_server_pointer,
                                static_channel_chunk_size,
                                refresh_rect_support,
                                suppress_output_support,
                                ..
                            } = activation.connection_activation_state()
                            {
                                image = crate::rdp::new_image(desktop_size)?;
                                if !stage.reactivate(
                                    activation.io_channel_id(),
                                    activation.user_channel_id(),
                                    share_id,
                                    enable_server_pointer,
                                    false, // Flutter draws the cursor independently.
                                    static_channel_chunk_size,
                                ) {
                                    bail!("RDP 通道重新激活失败");
                                }
                                encoder.invalidate(image.width(), image.height());
                                pending_gpu_frame = None;
                                availability = FrameAvailability::default();
                                recovery.refresh_rect = refresh_rect_support;
                                recovery.suppress_output = suppress_output_support;
                                recovery.pending = false;
                                break;
                            }
                        }
                        Ok::<_, anyhow::Error>(())
                    })
                    .await??;
                }
                ActiveStageOutput::MultitransportRequest(request) => {
                    let id = request.request_id;
                    let outcome = tokio::select! {
                        _ = cancel.changed() => break,
                        outcome = udp.connect(request, soft_sync) => outcome,
                    };
                    if let Some(response) = outcome.response_pdu(id, soft_sync) {
                        let frame = stage.encode_multitransport_response(&response)?;
                        tokio::time::timeout(TIMEOUT, async {
                            writer.lock().await.write_all(&frame).await
                        })
                        .await
                        .context("RDP 多通道应答超时")?
                        .context("RDP 多通道应答失败")?;
                    }
                    if matches!(outcome, connector::MultitransportResult::Success) {
                        stage.enable_reliable_udp_dvc_tunnel()?;
                    }
                }
                _ => {}
            }
        }
    }
    Ok(())
}

async fn send_dvc(
    stage: &mut ActiveStage,
    writer: &Mutex<Writer>,
    udp: &Sideband,
    batch: DvcMessageBatch,
    from_udp: bool,
) -> Result<()> {
    if batch.messages().is_empty() {
        return Ok(());
    }
    let over_udp = from_udp
        || stage.dvc_tunnel_for_channel(batch.channel_id())
            == Some(SoftSyncTunnelType::RELIABLE_UDP);
    let messages = batch.into_messages();
    tokio::time::timeout(TIMEOUT, async {
        if over_udp {
            let transport = udp.transport.as_ref().context("RDP UDP 通道不可用")?;
            for message in messages {
                transport.send(message.encode_unframed_pdu()?).await?;
            }
        } else {
            let bytes = stage.encode_dvc_messages(messages)?;
            writer.lock().await.write_all(&bytes).await?;
        }
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("RDP 虚拟通道发送超时")?
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::{decode, encode_vec};
    use ironrdp::pdu::nego::{
        ConnectionConfirm, ConnectionRequest, ResponseFlags, SecurityProtocol,
    };
    use ironrdp::pdu::x224::X224;
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;

    #[test]
    fn egfx_advertises_supported_codecs_and_decodes_h264_to_output() {
        use ironrdp::dvc::DvcProcessor;
        use ironrdp::graphics::zgfx::wrap_uncompressed;
        use ironrdp::pdu::geometry::ExclusiveRectangle;
        use ironrdp_egfx::pdu::{
            encode_avc420_bitmap_stream, Avc420BitmapStream, Avc420Region, Avc444BitmapStream,
            CapabilitiesConfirmPdu, CapabilityVersion, Codec1Type, CreateSurfacePdu, Encoding,
            EndFramePdu, GfxPdu, MapSurfaceToOutputPdu, PixelFormat, ResetGraphicsPdu,
            WireToSurface1Pdu,
        };
        use openh264::encoder::Encoder;
        use openh264::formats::YUVBuffer;

        let graphics = GraphicsEvents::default();
        let mut client = graphics_pipeline(graphics.clone());
        let mut availability = FrameAvailability::default();
        assert!(!availability.ready);
        let advertised = client.start(1).unwrap();
        let GfxPdu::CapabilitiesAdvertise(advertised) =
            decode::<GfxPdu>(&encode_vec(advertised[0].as_ref()).unwrap()).unwrap()
        else {
            panic!("expected graphics capabilities");
        };
        assert_eq!(advertised.0[0].version, CapabilityVersion::V10_7);
        let avc420 = advertised
            .0
            .iter()
            .find(|cap| cap.version == CapabilityVersion::V8_1)
            .unwrap();
        assert_eq!(advertised.0.last().unwrap().version, CapabilityVersion::V8);

        // Exercise the actual bundled decoder with a locally generated IDR
        // frame, through the public ZGFX/DVC wire interface and compositor.
        // EGFX interprets the picture as full-range BT.709. Supply those
        // planes directly, independent of the encoder helper's RGB matrix.
        let mut planes = vec![119; 64 * 64];
        planes.extend([167; 32 * 32]);
        planes.extend([93; 32 * 32]);
        let yuv = YUVBuffer::from_vec(planes, 64, 64);
        let mut encoder = Encoder::new().unwrap();
        let h264 = encoder.encode(&yuv).unwrap().to_vec();
        let headers = [
            GfxPdu::CapabilitiesConfirm(CapabilitiesConfirmPdu(avc420.clone())),
            GfxPdu::ResetGraphics(ResetGraphicsPdu {
                width: 64,
                height: 64,
                monitors: vec![],
            }),
            GfxPdu::CreateSurface(CreateSurfacePdu {
                surface_id: 1,
                width: 64,
                height: 64,
                pixel_format: PixelFormat::XRgb,
            }),
            GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu {
                surface_id: 1,
                output_origin_x: 0,
                output_origin_y: 0,
            }),
            GfxPdu::EndFrame(EndFramePdu { frame_id: 6 }),
        ];
        let bytes: Vec<_> = headers
            .iter()
            .flat_map(|pdu| encode_vec(pdu).unwrap())
            .collect();
        client.process(1, &wrap_uncompressed(&bytes)).unwrap();
        assert_eq!(client.take_output_reset(), Some((64, 64)));
        let mapped = client.drain_output();
        assert!(!mapped.is_empty(), "mapping can dirty a blank surface");
        availability.update(graphics.take_transitions(), !mapped.is_empty());
        assert!(
            !availability.ready,
            "a mapped but empty surface must stay hidden"
        );

        let pdus = [
            GfxPdu::WireToSurface1(WireToSurface1Pdu {
                surface_id: 1,
                codec_id: Codec1Type::Avc420,
                pixel_format: PixelFormat::XRgb,
                destination_rectangle: ExclusiveRectangle {
                    left: 0,
                    top: 0,
                    right: 64,
                    bottom: 64,
                },
                bitmap_data: encode_avc420_bitmap_stream(
                    &[Avc420Region::full_frame(64, 64, 20)],
                    &h264,
                ),
            }),
            GfxPdu::EndFrame(EndFramePdu { frame_id: 7 }),
        ];
        let bytes: Vec<_> = pdus
            .iter()
            .flat_map(|pdu| encode_vec(pdu).unwrap())
            .collect();
        let responses = client.process(1, &wrap_uncompressed(&bytes)).unwrap();
        assert!(client.codec_capabilities().avc420);
        assert!(!client.codec_capabilities().avc444);
        let updates = client.drain_output();
        assert_eq!(updates.len(), 1);
        availability.update(graphics.take_transitions(), true);
        assert!(availability.ready);
        assert_eq!(updates[0].data.len(), 64 * 64 * 4);
        for pixel in updates[0].data.as_chunks::<4>().0 {
            for (actual, expected) in pixel.iter().zip([64, 128, 192, 255]) {
                assert!(actual.abs_diff(expected) <= 8, "unexpected pixel {pixel:?}");
            }
        }
        assert!(responses.iter().any(|response| matches!(
            decode::<GfxPdu>(&encode_vec(response.as_ref()).unwrap()).unwrap(),
            GfxPdu::FrameAcknowledge(ack) if ack.frame_id == 7
        )));

        // The updated block is in the bright right half. An origin crop would
        // instead paint the dark left half at the same destination.
        let mut planes = vec![24; 64 * 64];
        for row in planes.as_chunks_mut::<64>().0 {
            row[32..].fill(189);
        }
        planes.extend([128; 2 * 32 * 32]);
        let next = encoder
            .encode(&YUVBuffer::from_vec(planes, 64, 64))
            .unwrap()
            .to_vec();
        let region = Avc420Region::new(32, 16, 48, 32, 20, 100);
        send_egfx(
            &mut client,
            [
                GfxPdu::WireToSurface1(WireToSurface1Pdu {
                    surface_id: 1,
                    codec_id: Codec1Type::Avc420,
                    pixel_format: PixelFormat::XRgb,
                    destination_rectangle: region.to_rectangle(),
                    bitmap_data: encode_avc420_bitmap_stream(&[region], &next),
                }),
                GfxPdu::EndFrame(EndFramePdu { frame_id: 8 }),
            ],
        );
        let updates = client.drain_output();
        assert_eq!(updates.len(), 1);
        assert_eq!(
            updates[0].region,
            ExclusiveRectangle {
                left: 32,
                top: 16,
                right: 48,
                bottom: 32,
            }
        );
        assert_eq!(updates[0].data.len(), 16 * 16 * 4);
        assert!(updates[0].data.as_chunks::<4>().0.iter().all(|pixel| {
            pixel[..3].iter().all(|channel| channel.abs_diff(189) <= 8) && pixel[3] == 255
        }));

        client
            .process(1, &wrap_uncompressed(&encode_vec(&headers[1]).unwrap()))
            .unwrap();
        assert_eq!(client.take_output_reset(), Some((64, 64)));
        availability.update(graphics.take_transitions(), false);
        assert!(
            !availability.ready,
            "a same-size reset must hide the new base until painted"
        );

        // Negotiate V10.7 and exercise the actual decoder for both views of an
        // AVC444v2 update, rather than just testing the advertised flags.
        let mut avc444 = graphics_pipeline(GraphicsEvents::default());
        avc444.start(1).unwrap();
        send_egfx(
            &mut avc444,
            [
                GfxPdu::CapabilitiesConfirm(CapabilitiesConfirmPdu(advertised.0[0].clone())),
                headers[1].clone(),
                headers[2].clone(),
                headers[3].clone(),
                headers[4].clone(),
            ],
        );
        let _ = avc444.drain_output();
        let view = encode_avc420_bitmap_stream(&[Avc420Region::full_frame(64, 64, 20)], &h264);
        let stream1 = decode::<Avc420BitmapStream<'_>>(&view).unwrap();
        let bitmap_data = encode_vec(&Avc444BitmapStream {
            encoding: Encoding::LUMA_AND_CHROMA,
            stream1: stream1.clone(),
            stream2: Some(stream1),
        })
        .unwrap();
        send_egfx(
            &mut avc444,
            [
                GfxPdu::WireToSurface1(WireToSurface1Pdu {
                    surface_id: 1,
                    codec_id: Codec1Type::Avc444v2,
                    pixel_format: PixelFormat::XRgb,
                    destination_rectangle: ExclusiveRectangle {
                        left: 0,
                        top: 0,
                        right: 64,
                        bottom: 64,
                    },
                    bitmap_data,
                }),
                GfxPdu::EndFrame(EndFramePdu { frame_id: 7 }),
            ],
        );
        assert!(avc444.codec_capabilities().avc444);
        assert_eq!(avc444.dropped_updates(), 0);
        assert_eq!(avc444.drain_output()[0].data.len(), 64 * 64 * 4);

        let mut fallback = GraphicsPipelineClient::new(Box::<GraphicsEvents>::default(), None);
        let advertised = fallback.start(1).unwrap();
        let GfxPdu::CapabilitiesAdvertise(advertised) =
            decode::<GfxPdu>(&encode_vec(advertised[0].as_ref()).unwrap()).unwrap()
        else {
            panic!("expected fallback capabilities");
        };
        assert_eq!(advertised.0.len(), 1);
        assert_eq!(advertised.0[0].version, CapabilityVersion::V8);
    }

    fn send_egfx(
        client: &mut GraphicsPipelineClient,
        pdus: impl IntoIterator<Item = ironrdp_egfx::pdu::GfxPdu>,
    ) -> Vec<ironrdp::dvc::DvcMessage> {
        use ironrdp::dvc::DvcProcessor;
        use ironrdp::graphics::zgfx::wrap_uncompressed;
        let bytes: Vec<_> = pdus
            .into_iter()
            .flat_map(|pdu| encode_vec(&pdu).unwrap())
            .collect();
        client.process(1, &wrap_uncompressed(&bytes)).unwrap()
    }

    #[test]
    fn egfx_ack_reports_only_unprocessed_graphics_bytes() {
        use ironrdp_egfx::pdu::{EndFramePdu, GfxPdu, QueueDepth};
        let mut client = graphics_pipeline(GraphicsEvents::default());
        let last = GfxPdu::EndFrame(EndFramePdu { frame_id: 2 });
        let pending = encode_vec(&last).unwrap().len() as u32;
        let replies = send_egfx(
            &mut client,
            [GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }), last],
        );
        let acks: Vec<_> = replies
            .iter()
            .map(|pdu| {
                let GfxPdu::FrameAcknowledge(ack) =
                    decode::<GfxPdu>(&encode_vec(pdu.as_ref()).unwrap()).unwrap()
                else {
                    panic!("expected frame acknowledgement");
                };
                (ack.frame_id, ack.queue_depth)
            })
            .collect();
        assert_eq!(
            acks,
            [
                (1, QueueDepth::AvailableBytes(pending)),
                (2, QueueDepth::Unavailable)
            ]
        );
    }

    #[test]
    fn direct_egfx_commit_matches_buffered_output_for_scaled_and_clipped_surfaces() {
        use ironrdp::pdu::geometry::ExclusiveRectangle;
        use ironrdp::session::composite_graphics_pipeline;
        use ironrdp_egfx::pdu::{
            Codec1Type, CreateSurfacePdu, EndFramePdu, GfxPdu, MapSurfaceToOutputPdu,
            MapSurfaceToScaledOutputPdu, PixelFormat, ResetGraphicsPdu, WireToSurface1Pdu,
        };
        for mapped in [
            GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu {
                surface_id: 1,
                output_origin_x: 5,
                output_origin_y: 1,
            }),
            GfxPdu::MapSurfaceToScaledOutput(MapSurfaceToScaledOutputPdu {
                surface_id: 1,
                output_origin_x: 2,
                output_origin_y: 1,
                target_width: 6,
                target_height: 3,
            }),
        ] {
            let play = |mut client: GraphicsPipelineClient| {
                let mut image = crate::rdp::new_image(connector::DesktopSize {
                    width: 1,
                    height: 1,
                })
                .unwrap();
                send_egfx(
                    &mut client,
                    [
                        GfxPdu::ResetGraphics(ResetGraphicsPdu {
                            width: 6,
                            height: 3,
                            monitors: vec![],
                        }),
                        GfxPdu::CreateSurface(CreateSurfacePdu {
                            surface_id: 1,
                            width: 2,
                            height: 2,
                            pixel_format: PixelFormat::XRgb,
                        }),
                        mapped.clone(),
                        GfxPdu::WireToSurface1(WireToSurface1Pdu {
                            surface_id: 1,
                            codec_id: Codec1Type::Uncompressed,
                            pixel_format: PixelFormat::XRgb,
                            destination_rectangle: ExclusiveRectangle {
                                left: 0,
                                top: 0,
                                right: 2,
                                bottom: 2,
                            },
                            bitmap_data: [4, 8, 16, 0, 1, 2, 3, 0, 0, 32, 0, 0, 42, 2, 7, 0]
                                .to_vec(),
                        }),
                        GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }),
                    ],
                );
                let update = composite_graphics_pipeline(&mut client, &mut image).unwrap();
                assert!(update.reset);
                assert_eq!((image.width(), image.height()), (6, 3));
                assert!(!update.regions.is_empty());
                assert!(image.data().contains(&16));
                (update.regions, image.data().to_vec())
            };
            assert_eq!(
                play(graphics_pipeline(GraphicsEvents::default())),
                play(graphics_pipeline(GraphicsEvents::default()).with_direct_output())
            );
        }
    }

    #[test]
    fn desktop_output_stays_opaque_when_alpha_is_copied_from_a_cache_slot() {
        use ironrdp::pdu::geometry::ExclusiveRectangle;
        use ironrdp::session::composite_graphics_pipeline;
        use ironrdp_egfx::pdu::{
            Codec1Type, CreateSurfacePdu, EndFramePdu, GfxPdu, MapSurfaceToOutputPdu, PixelFormat,
            Point, ResetGraphicsPdu, SurfaceToCachePdu, WireToSurface1Pdu,
        };
        let mut client = graphics_pipeline(GraphicsEvents::default())
            .with_direct_output()
            .with_opaque_surface_base();
        let rect = ExclusiveRectangle {
            left: 0,
            top: 0,
            right: 1,
            bottom: 1,
        };
        let create = |surface_id| {
            GfxPdu::CreateSurface(CreateSurfacePdu {
                surface_id,
                width: 2,
                height: 1,
                pixel_format: PixelFormat::ARgb,
            })
        };
        let wire = |codec_id, bitmap_data| {
            GfxPdu::WireToSurface1(WireToSurface1Pdu {
                surface_id: 1,
                codec_id,
                pixel_format: PixelFormat::ARgb,
                destination_rectangle: rect.clone(),
                bitmap_data,
            })
        };
        send_egfx(
            &mut client,
            [
                GfxPdu::ResetGraphics(ResetGraphicsPdu {
                    width: 2,
                    height: 1,
                    monitors: vec![],
                }),
                create(1),
                create(2),
                GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu {
                    surface_id: 2,
                    output_origin_x: 0,
                    output_origin_y: 0,
                }),
                wire(Codec1Type::Uncompressed, vec![7, 8, 9, 0]),
                wire(Codec1Type::Alpha, vec![0x4c, 0x41, 0, 0, 0x80]),
                GfxPdu::SurfaceToCache(SurfaceToCachePdu {
                    surface_id: 1,
                    cache_key: 1,
                    cache_slot: 1,
                    source_rectangle: rect.clone(),
                }),
                GfxPdu::CacheToSurface(CacheToSurfacePdu {
                    cache_slot: 1,
                    surface_id: 2,
                    destination_points: vec![Point { x: 1, y: 0 }],
                }),
                GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }),
            ],
        );
        assert!(client.drain_buffered_output().is_empty());
        let mut image = crate::rdp::new_image(connector::DesktopSize {
            width: 2,
            height: 1,
        })
        .unwrap();
        composite_graphics_pipeline(&mut client, &mut image).unwrap();
        assert_eq!(image.data(), &[0, 0, 0, 255, 9, 8, 7, 255]);
        assert_eq!(
            FrameEncoder::new(2, 1).snapshot(&image, 0).rgba,
            image.data()
        );
    }

    #[test]
    fn keyboard_lock_sync_encodes_toggle_bits_without_simulated_keys() {
        let events = input_events(3, 0, 0x05, 0, 0, String::new()).unwrap();
        let frames = ironrdp::session::encode_fastpath_input(&events).unwrap();
        let packet = decode::<ironrdp::pdu::input::fast_path::FastPathInput>(&frames[0]).unwrap();
        assert_eq!(
            packet.input_events(),
            [FastPathInputEvent::SyncEvent(
                SynchronizeFlags::SCROLL_LOCK | SynchronizeFlags::CAPS_LOCK
            )]
        );
        assert!(input_events(3, 0, 0x80, 0, 0, String::new()).is_err());
    }

    #[test]
    fn egfx_clearcodec_and_glyph_hits_preserve_unpainted_pixels() {
        use ironrdp::pdu::codecs::clearcodec::{FLAG_GLYPH_HIT, FLAG_GLYPH_INDEX};
        use ironrdp::pdu::geometry::ExclusiveRectangle;
        use ironrdp_egfx::pdu::{
            Codec1Type, CreateSurfacePdu, EndFramePdu, GfxPdu, MapSurfaceToOutputPdu, PixelFormat,
            ResetGraphicsPdu, WireToSurface1Pdu,
        };
        let mut client = graphics_pipeline(GraphicsEvents::default());
        let rect = ExclusiveRectangle {
            left: 1,
            top: 1,
            right: 3,
            bottom: 2,
        };
        let bitmap = |codec_id, bitmap_data| {
            GfxPdu::WireToSurface1(WireToSurface1Pdu {
                surface_id: 1,
                codec_id,
                pixel_format: PixelFormat::XRgb,
                destination_rectangle: rect.clone(),
                bitmap_data,
            })
        };
        let end = |frame_id| GfxPdu::EndFrame(EndFramePdu { frame_id });
        send_egfx(
            &mut client,
            [
                GfxPdu::ResetGraphics(ResetGraphicsPdu {
                    width: 4,
                    height: 2,
                    monitors: vec![],
                }),
                GfxPdu::CreateSurface(CreateSurfacePdu {
                    surface_id: 1,
                    width: 4,
                    height: 2,
                    pixel_format: PixelFormat::XRgb,
                }),
                GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu {
                    surface_id: 1,
                    output_origin_x: 0,
                    output_origin_y: 0,
                }),
                bitmap(Codec1Type::Uncompressed, [0, 192, 0, 0].repeat(2)),
                end(1),
            ],
        );
        let _ = client.drain_output();

        // No residual or bands. Raw subcodec paints only the second pixel black.
        let mut glyph = vec![FLAG_GLYPH_INDEX, 0, 1, 0];
        glyph.extend_from_slice(&[
            0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        ]);
        send_egfx(&mut client, [bitmap(Codec1Type::ClearCodec, glyph), end(2)]);
        let output = client.drain_output();
        assert_eq!(output.len(), 1);
        assert_eq!(output[0].data, [0, 192, 0, 255, 0, 0, 0, 255]);

        // The cache describes encoded colors, not the green background on the
        // first draw. A hit against blue should leave that blue intact.
        send_egfx(
            &mut client,
            [
                bitmap(Codec1Type::Uncompressed, [192, 0, 0, 0].repeat(2)),
                end(3),
            ],
        );
        let _ = client.drain_output();
        send_egfx(
            &mut client,
            [
                bitmap(
                    Codec1Type::ClearCodec,
                    vec![FLAG_GLYPH_INDEX | FLAG_GLYPH_HIT, 1, 1, 0],
                ),
                end(4),
            ],
        );
        assert_eq!(client.dropped_updates(), 0);
        assert_eq!(
            client.drain_output()[0].data,
            [0, 0, 192, 255, 0, 0, 0, 255]
        );
    }

    #[test]
    fn egfx_missing_cache_entry_is_counted_for_redraw() {
        use ironrdp_egfx::pdu::{CreateSurfacePdu, EndFramePdu, GfxPdu, PixelFormat, Point};
        let mut client = graphics_pipeline(GraphicsEvents::default());
        send_egfx(
            &mut client,
            [
                GfxPdu::CreateSurface(CreateSurfacePdu {
                    surface_id: 1,
                    width: 1,
                    height: 1,
                    pixel_format: PixelFormat::XRgb,
                }),
                GfxPdu::CacheToSurface(CacheToSurfacePdu {
                    surface_id: 1,
                    cache_slot: 42,
                    destination_points: vec![Point { x: 0, y: 0 }],
                }),
                GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }),
            ],
        );
        assert_eq!(client.dropped_updates(), 1);
        assert!(client.drain_output().is_empty());
        let mut recovery = RedrawRecovery::new(true, false);
        recovery.observe(false, client.dropped_updates());
        assert!(recovery.pending);
    }

    #[tokio::test(start_paused = true)]
    async fn redraw_recovery_coalesces_graphics_failures_and_respects_capabilities() {
        let mut unsupported = RedrawRecovery::new(false, false);
        unsupported.observe(true, 1);
        assert!(!unsupported.pending);

        let mut recovery = RedrawRecovery::new(true, false);
        recovery.observe(false, 1);
        assert!(recovery.pending && recovery.next_at <= Instant::now());
        recovery.sent();
        recovery.observe(false, 1);
        assert!(
            !recovery.pending,
            "an old drop must not cause repeated redraws"
        );
        recovery.observe(false, 2);
        recovery.observe(true, 3);
        assert!(recovery.pending && recovery.next_at > Instant::now());
        tokio::time::advance(REDRAW_INTERVAL).await;
        assert!(recovery.pending && recovery.next_at <= Instant::now());
        recovery.sent();
        assert!(!recovery.pending);
    }

    #[test]
    fn windows_srl_streams_decode_without_trailing_zeros() {
        use ironrdp::graphics::srl::{decode_srl, SrlError};

        // Windows may omit both the terminator byte and trailing zero bits.
        assert_eq!(decode_srl(&[0x84], 5, 4).unwrap(), [3, 0, 0, 0, 0]);
        assert_eq!(decode_srl(&[], 4096, 4).unwrap(), vec![0; 4096]);
        assert_eq!(
            decode_srl(&[0x90], 1, 16),
            Err(SrlError::InvalidBitCount(16)),
        );
    }

    #[test]
    fn progressive_upgrade_applies_windows_srl_without_a_terminator() {
        use ironrdp::graphics::progressive::{decode_upgrade_pass, SIGN_POSITIVE, SIGN_ZERO};
        use ironrdp::pdu::codecs::rfx::progressive::ComponentCodecQuant;

        let mut coefficients = [0i16; 4096];
        let mut sign = [SIGN_POSITIVE; 4096];
        sign[0] = SIGN_ZERO;
        let mut previous = ComponentCodecQuant::LOSSLESS;
        previous.hl1 = 4;
        let mut current = ComponentCodecQuant::LOSSLESS;
        current.hl1 = 2;

        // A positive +1 SRL refinement shifted by the current bit position.
        decode_upgrade_pass(
            &[0x90],
            &[],
            &previous,
            &current,
            false,
            &mut coefficients,
            &mut sign,
        )
        .unwrap();

        assert_eq!(coefficients[0], 4);
        assert_eq!(sign[0], SIGN_POSITIVE);
        assert!(coefficients[1..]
            .iter()
            .all(|coefficient| *coefficient == 0));
    }

    #[test]
    fn egfx_and_initial_desktop_use_the_same_pixel_limit() {
        assert!(crate::rdp::validate_desktop_size(4096, 4096).is_ok());
        for (width, height) in [(0, 100), (100, 0), (4097, 4096)] {
            assert!(crate::rdp::validate_desktop_size(width, height).is_err());
        }
    }

    #[tokio::test]
    async fn incompatible_security_reports_the_stage_without_falling_back_to_plain_rdp() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let peer = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut framed = TokioFramed::new(tcp);
            framed.read_pdu().await.unwrap();
            framed
                .write_all(
                    &encode_vec(&X224(ConnectionConfirm::Response {
                        flags: ResponseFlags::empty(),
                        protocol: SecurityProtocol::empty(),
                    }))
                    .unwrap(),
                )
                .await
                .unwrap();
        });
        let error = prepare("127.0.0.1".into(), port, None).await.err().unwrap();
        assert!(error.to_string().contains("RDP 安全协议协商失败"));
        assert!(error.to_string().contains("STANDARD_RDP_SECURITY"));
        peer.await.unwrap();
    }

    #[tokio::test]
    async fn tls_and_nla_servers_reach_certificate_review_before_any_credentials() {
        for protocol in [SecurityProtocol::SSL, SecurityProtocol::HYBRID] {
            tokio::time::timeout(Duration::from_secs(5), async {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let port = listener.local_addr().unwrap().port();
                let key = rcgen::KeyPair::generate().unwrap();
                let cert = rcgen::CertificateParams::new(vec!["127.0.0.1".into()])
                    .unwrap()
                    .self_signed(&key)
                    .unwrap();
                let server = rustls::ServerConfig::builder_with_provider(Arc::new(
                    rustls::crypto::ring::default_provider(),
                ))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![cert.der().clone()],
                    rustls::pki_types::PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
                )
                .unwrap();
                let peer = tokio::spawn(async move {
                    let (tcp, _) = listener.accept().await.unwrap();
                    let mut framed = TokioFramed::new(tcp);
                    let (_, request) = framed.read_pdu().await.unwrap();
                    let request = decode::<X224<ConnectionRequest>>(&request).unwrap().0;
                    assert!(request.protocol.contains(SecurityProtocol::SSL));
                    assert!(request.protocol.contains(SecurityProtocol::HYBRID));
                    let response = encode_vec(&X224(ConnectionConfirm::Response {
                        flags: ResponseFlags::empty(),
                        protocol,
                    }))
                    .unwrap();
                    framed.write_all(&response).await.unwrap();
                    let mut tls = tokio_rustls::TlsAcceptor::from(Arc::new(server))
                        .accept(framed.into_inner_no_leftover())
                        .await
                        .unwrap();
                    // The client must stop at certificate review for both modes;
                    // neither CredSSP nor the TLS Client Info packet may be sent.
                    assert!(
                        tokio::time::timeout(Duration::from_millis(50), tls.read_u8())
                            .await
                            .is_err()
                    );
                });
                let handshake = prepare("127.0.0.1".into(), port, None).await.unwrap();
                assert!(handshake.certificate_error.is_some());
                let entry = session(handshake.session_id).await.unwrap();
                assert_eq!(
                    entry
                        .pending
                        .lock()
                        .await
                        .as_ref()
                        .unwrap()
                        .connector
                        .should_perform_credssp(),
                    protocol == SecurityProtocol::HYBRID
                );
                peer.await.unwrap();
                disconnect(handshake.session_id).await;
            })
            .await
            .unwrap();
        }
    }

    #[tokio::test]
    #[ignore = "requires PAGAGATEWAY_BIN; uses real Go relay on loopback"]
    async fn page_go_relay_reaches_rdp_certificate_review_before_credentials() {
        for (use_tls, protocol) in [
            (true, SecurityProtocol::SSL),
            (true, SecurityProtocol::HYBRID),
            (false, SecurityProtocol::SSL),
            (false, SecurityProtocol::HYBRID),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let key = rcgen::KeyPair::generate().unwrap();
            let cert = rcgen::CertificateParams::new(vec!["127.0.0.1".into()])
                .unwrap()
                .self_signed(&key)
                .unwrap();
            let server = rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            )
            .unwrap();
            let peer = tokio::spawn(async move {
                let (tcp, _) = listener.accept().await.unwrap();
                let mut framed = TokioFramed::new(tcp);
                framed.read_pdu().await.unwrap();
                framed
                    .write_all(
                        &encode_vec(&X224(ConnectionConfirm::Response {
                            flags: ResponseFlags::empty(),
                            protocol,
                        }))
                        .unwrap(),
                    )
                    .await
                    .unwrap();
                let mut tls = tokio_rustls::TlsAcceptor::from(Arc::new(server))
                    .accept(framed.into_inner_no_leftover())
                    .await
                    .unwrap();
                assert!(
                    tokio::time::timeout(Duration::from_millis(75), tls.read_u8())
                        .await
                        .is_err()
                );
            });
            let relay = crate::page::GoRelay::start(&[port], use_tls).await;
            let handshake =
                prepare_with_page("127.0.0.1".into(), port, None, Some(relay.gateway.clone()))
                    .await
                    .unwrap();
            assert!(handshake.certificate_error.is_some());
            peer.await.unwrap();
            disconnect(handshake.session_id).await;
            assert!(!SESSIONS.lock().await.contains_key(&handshake.session_id));
        }
    }

    /// Explicit opt-in diagnostic: negotiates RDP/TLS only, never authenticates.
    #[tokio::test]
    #[ignore = "requires PAGASHELL_RDP_PROBE_HOST; does not send login credentials"]
    async fn desktop_handshake_probe() {
        let host = std::env::var("PAGASHELL_RDP_PROBE_HOST").expect("set PAGASHELL_RDP_PROBE_HOST");
        let port = std::env::var("PAGASHELL_RDP_PROBE_PORT")
            .map(|s| s.parse().unwrap())
            .unwrap_or(3389);
        match prepare(host, port, None).await {
            Ok(handshake) => {
                println!(
                    "RDP/TLS handshake succeeded; certificate validation: {:?}",
                    handshake.certificate_error
                );
                let entry = session(handshake.session_id).await.unwrap();
                println!(
                    "CredSSP selected: {}",
                    entry
                        .pending
                        .lock()
                        .await
                        .as_ref()
                        .unwrap()
                        .connector
                        .should_perform_credssp()
                );
                disconnect(handshake.session_id).await;
            }
            Err(error) => panic!("{error:#}"),
        }
    }

    async fn test_session() -> (u32, Arc<Desktop>) {
        let (commands, receiver) = mpsc::channel(8);
        let (frames, requests) = mpsc::channel(4);
        let (resizes, resize_receiver) = mpsc::channel(4);
        let entry = Arc::new(Desktop {
            fingerprint: "trusted-cert".into(),
            clipboard: Clipboard::new(),
            pending: Mutex::new(None),
            cancel: watch::channel(false).0,
            gpu_disable: watch::channel(false).0,
            commands,
            receiver: Mutex::new(Some(receiver)),
            frames,
            requests: Mutex::new(Some(requests)),
            finished: watch::channel(None).0,
            resizes,
            resize_receiver: Mutex::new(Some(resize_receiver)),
        });
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        SESSIONS.lock().await.insert(id, entry.clone());
        (id, entry)
    }

    #[tokio::test]
    async fn wrong_certificate_rejects_before_authentication_and_removes_session() {
        let (id, entry) = test_session().await;
        let error = authenticate(
            id,
            "untrusted-cert".into(),
            "user".into(),
            "secret-password".into(),
            String::new(),
            crate::rdp::ClientPreferences::default(),
        )
        .await
        .unwrap_err();
        assert_eq!(error.to_string(), "RDP 证书未获信任，已拒绝认证");
        assert!(!error.to_string().contains("secret-password"));
        assert!(session(id).await.is_err());
        assert!(*entry.cancel.borrow());
        assert!(entry.receiver.lock().await.is_none());
    }

    #[tokio::test]
    async fn batched_keyboard_and_pointer_edges_share_one_ordered_fast_path_pdu() {
        use ironrdp::pdu::input::fast_path::FastPathInput;

        let (id, entry) = test_session().await;
        let receiver = entry.receiver.lock().await.take().unwrap();
        let (ours, peer) = tokio::io::duplex(1024);
        let mut peer = TokioFramed::new(peer);
        let (stop, stopped) = watch::channel(false);
        let input_task = tokio::spawn(crate::desktop_input::write_to_peer(
            Arc::new(Mutex::new(TokioFramed::new(ours))),
            receiver,
            entry.cancel.subscribe(),
            stopped,
            Duration::from_secs(1),
        ));
        let key = |flags| DesktopInputEvent {
            pointer: false,
            code: 0x1d,
            flags,
            x: 0,
            y: 0,
        };
        let click = |flags| DesktopInputEvent {
            pointer: true,
            code: 0,
            flags,
            x: 9,
            y: 10,
        };
        input_batch(id, vec![key(2), click(0x9000), click(0x1000), key(3)])
            .await
            .unwrap();
        // The transport sends the ordered PDU without an ActiveStage or image.
        let (action, bytes) = tokio::time::timeout(Duration::from_secs(1), peer.read_pdu())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(action, ironrdp::pdu::Action::FastPath);
        let input = decode::<FastPathInput>(&bytes).unwrap();
        assert!(matches!(input.input_events(), [
            FastPathInputEvent::KeyboardEvent(KeyboardFlags::EXTENDED, 0x1d),
            FastPathInputEvent::MouseEvent(down),
            FastPathInputEvent::MouseEvent(up),
            FastPathInputEvent::KeyboardEvent(release, 0x1d),
        ] if down.flags == PointerFlags::LEFT_BUTTON | PointerFlags::DOWN
            && up.flags == PointerFlags::LEFT_BUTTON
            && (down.x_position, down.y_position) == (9, 10)
            && *release == KeyboardFlags::EXTENDED | KeyboardFlags::RELEASE
        ));
        // Disconnect while a key is held; the same writer supplies the release.
        input_batch(id, vec![key(2)]).await.unwrap();
        let (_, bytes) = tokio::time::timeout(Duration::from_secs(1), peer.read_pdu())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            decode::<FastPathInput>(&bytes).unwrap().input_events(),
            [FastPathInputEvent::KeyboardEvent(
                KeyboardFlags::EXTENDED,
                0x1d
            )]
        ));
        disconnect(id).await;
        let (_, bytes) = tokio::time::timeout(Duration::from_secs(1), peer.read_pdu())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(decode::<FastPathInput>(&bytes).unwrap().input_events(),
            [FastPathInputEvent::KeyboardEvent(flags, 0x1d)] if *flags == KeyboardFlags::EXTENDED | KeyboardFlags::RELEASE)
        );
        input_task.await.unwrap().unwrap();
        drop(stop);
    }

    #[tokio::test]
    async fn worker_probe_requires_the_active_loop_to_ack_even_on_a_static_desktop() {
        let (id, entry) = test_session().await;
        let mut commands = entry.clipboard.receiver();
        let awaiting = tokio::spawn(probe(id));
        let Some(ClipboardCommand::Barrier(reply)) = commands.recv().await else {
            panic!("the active loop must receive the probe");
        };
        assert!(!awaiting.is_finished());
        reply.send(()).unwrap();
        assert!(awaiting.await.unwrap().is_ok());
        disconnect(id).await;
    }

    #[tokio::test]
    async fn worker_failure_reaches_inflight_and_later_polls_and_input() {
        let (id, entry) = test_session().await;
        let mut requests = entry.requests.lock().await.take().unwrap();
        let commands = entry.receiver.lock().await.take().unwrap();
        let (fail, failed) = oneshot::channel();
        start_session(entry.clone(), async move {
            let request = requests.recv().await.unwrap();
            failed.await.unwrap();
            drop(request);
            drop(commands);
            bail!("RDP 图形或会话处理失败：EGFX test decode failure");
        });
        let polling = tokio::spawn(frame(id, 0));
        fail.send(()).unwrap();
        let error = tokio::time::timeout(Duration::from_secs(1), polling)
            .await
            .unwrap()
            .unwrap()
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("EGFX test decode failure"));
        assert_eq!(frame(id, 0).await.err().unwrap().to_string(), error);
        assert_eq!(
            input(id, 0, 30, 0, 0, 0, String::new())
                .await
                .unwrap_err()
                .to_string(),
            error
        );
        disconnect(id).await;
    }

    #[tokio::test]
    async fn worker_panic_wakes_polls_without_exposing_the_payload() {
        let (id, entry) = test_session().await;
        start_session(entry, async { panic!("private test panic payload") });
        let error = tokio::time::timeout(Duration::from_secs(1), frame(id, 0))
            .await
            .unwrap()
            .err()
            .unwrap()
            .to_string();
        assert_eq!(error, "RDP 会话处理异常，请重新连接");
        disconnect(id).await;
    }

    #[tokio::test]
    async fn frame_poll_requests_pixels_on_demand_and_disconnect_wakes_waiter() {
        let (id, entry) = test_session().await;
        let mut requests = entry.requests.lock().await.take().unwrap();
        assert!(requests.try_recv().is_err());
        let polling = tokio::spawn(frame(id, 0));
        let request = requests.recv().await.unwrap();
        assert_eq!(request.after, 0);
        assert!(request
            .reply
            .send(FrameDelivery {
                frame: DesktopFrame {
                    sequence: 10,
                    width: 1,
                    height: 1,
                    bitmap_width: 1,
                    bitmap_height: 1,
                    rgba: vec![10; 4],
                    tiles: vec![],
                    cursor: None,
                    texture_id: None,
                },
                gpu: None,
            })
            .is_ok());
        let latest = polling.await.unwrap().unwrap().unwrap();
        assert_eq!(latest.sequence, 10);
        assert_eq!(latest.rgba, vec![10; 4]);
        let waiting = tokio::spawn(frame(id, 10));
        let request = requests.recv().await.unwrap();
        assert_eq!(request.after, 10);
        disconnect(id).await;
        assert!(tokio::time::timeout(Duration::from_secs(1), waiting)
            .await
            .unwrap()
            .unwrap()
            .is_err());
    }

    #[tokio::test]
    async fn resize_waits_independently_of_input_and_disconnect_wakes_it() {
        let (id, entry) = test_session().await;
        let mut resizes = entry.resize_receiver.lock().await.take().unwrap();
        let mut commands = entry.receiver.lock().await.take().unwrap();
        let resizing = tokio::spawn(resize(id, 1920, 1080));
        let request = resizes.recv().await.unwrap();
        assert_eq!((request.width, request.height), (1920, 1080));
        input(id, 0, 30, 0, 0, 0, String::new()).await.unwrap();
        assert!(!commands.recv().await.unwrap().is_empty());
        assert!(!resizing.is_finished());
        disconnect(id).await;
        let error = tokio::time::timeout(Duration::from_secs(1), resizing)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(error.to_string(), "RDP 会话已关闭");
        assert!(request.reply.is_closed());
        assert!(entry.resize_receiver.lock().await.is_none());
    }

    #[tokio::test]
    async fn unsupported_resize_keeps_session_usable_and_failure_reaches_resize() {
        let (id, entry) = test_session().await;
        let mut resizes = entry.resize_receiver.lock().await.take().unwrap();
        let resizing = tokio::spawn(resize(id, 3840, 2160));
        resizes.recv().await.unwrap().reply.send(Ok(false)).unwrap();
        assert!(!resizing.await.unwrap().unwrap());
        assert!(session(id).await.is_ok());
        start_session(entry, async move {
            let request = resizes.recv().await.unwrap();
            drop(request);
            bail!("RDP 数据接收失败");
        });
        let error = tokio::time::timeout(Duration::from_secs(1), resize(id, 1920, 1080))
            .await
            .unwrap()
            .unwrap_err()
            .to_string();
        assert_eq!(error, "RDP 会话运行失败：RDP 数据接收失败");
        assert_eq!(resize(id, 1280, 800).await.unwrap_err().to_string(), error);
        disconnect(id).await;
    }

    #[test]
    fn pointer_wheel_preserves_both_directions() {
        for (flags, wheel) in [(0x0200, 120), (0x0300, -120), (0x0500, -120)] {
            let event = input_events(1, 120, flags, 640, 400, String::new()).unwrap();
            let FastPathInputEvent::MouseEvent(mouse) = &event[0] else {
                panic!("expected mouse event");
            };
            assert_eq!(mouse.number_of_wheel_rotation_units, wheel);
        }
    }
    #[test]
    fn validates_keyboard_and_preserves_unicode_surrogate_pairs() {
        assert!(input_events(0, 256, 0, 0, 0, String::new()).is_err());
        assert!(input_events(0, 30, 8, 0, 0, String::new()).is_err());
        let events = input_events(2, 0, 0, 0, 0, "中😀".into()).unwrap();
        assert_eq!(events.len(), 6);
        assert!(matches!(
            events[0],
            FastPathInputEvent::UnicodeKeyboardEvent(_, 0x4e2d)
        ));
        assert!(matches!(
            events[1],
            FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, 0x4e2d)
        ));
    }

    #[test]
    fn clipboard_text_uses_one_enter_for_crlf_and_tab_scan_codes() {
        let events = input_events(2, 0, 0, 0, 0, "\r\n\t\n".into()).unwrap();
        assert_eq!(events.len(), 6);
        for (i, scan) in [0x1c, 0x0f, 0x1c].into_iter().enumerate() {
            assert!(matches!(events[2 * i],
                FastPathInputEvent::KeyboardEvent(flags, code)
                if flags.is_empty() && code == scan));
            assert!(matches!(events[2 * i + 1],
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, code)
                if code == scan));
        }
    }

    #[test]
    fn classic_gdi_bitmap_glyph_and_offscreen_orders_render_and_reset() {
        use ironrdp::pdu::Action;
        use ironrdp::session::image::DecodedImage;
        use ironrdp::svc::StaticChannelSet;

        fn wrap_fastpath_orders(number_orders: u16, body: &[u8]) -> Vec<u8> {
            let mut payload = Vec::with_capacity(2 + body.len());
            payload.extend_from_slice(&number_orders.to_le_bytes());
            payload.extend_from_slice(body);
            // Fast-Path update header: code=0 (Orders), frag=0 (Single), compression=0
            let mut update = Vec::with_capacity(3 + payload.len());
            update.push(0x00);
            update.extend_from_slice(&(payload.len() as u16).to_le_bytes());
            update.extend_from_slice(&payload);
            // Fast-Path output header: action=0 (FastPath), length (2 bytes with 0x80 high bit)
            let total = 3 + update.len();
            let mut pdu = Vec::with_capacity(total);
            pdu.push(0x00);
            pdu.push(((total >> 8) as u8) | 0x80);
            pdu.push((total & 0xFF) as u8);
            pdu.extend_from_slice(&update);
            pdu
        }

        fn push_secondary(buf: &mut Vec<u8>, extra_flags: u16, order_type: u8, body: &[u8]) {
            buf.push(0x03); // TS_STANDARD | TS_SECONDARY
            let order_length = (body.len() as i16) - 7;
            buf.extend_from_slice(&order_length.to_le_bytes());
            buf.extend_from_slice(&extra_flags.to_le_bytes());
            buf.push(order_type);
            buf.extend_from_slice(body);
        }

        let mut stage = ActiveStageBuilder {
            static_channels: StaticChannelSet::new(),
            user_channel_id: 1001,
            io_channel_id: 1003,
            message_channel_id: None,
            share_id: 1,
            compression_type: None,
            enable_server_pointer: false,
            pointer_software_rendering: false,
        }
        .build();
        let mut image = DecodedImage::new_opaque_rgba(64, 64);

        let pixel = |img: &DecodedImage, x: usize, y: usize| -> [u8; 4] {
            let off = (y * usize::from(img.width()) + x) * 4;
            img.data()[off..off + 4].try_into().unwrap()
        };

        // 1) CacheBitmapUncompressedRev2 (cache_id=1, 32bpp => bpp_id=6, 2x2 BGRX bottom-up) + MemBlt to (4, 4)
        let mut orders = Vec::new();
        let mut bm_body = vec![
            2,  // width
            2,  // height
            16, // bitmap_size (1 byte compressed u32)
            3,  // cache_index = 3
        ];
        // Bottom row (y=1): blue (B=200,G=0,R=0,X=0), green (B=0,G=180,R=0,X=0)
        // Top row (y=0): red (B=0,G=0,R=220,X=0), yellow (B=0,G=210,R=210,X=0)
        bm_body.extend_from_slice(&[
            200, 0, 0, 0, 0, 180, 0, 0, // bottom row
            0, 0, 220, 0, 0, 210, 210, 0, // top row
        ]);
        let extra = 1u16 | (6u16 << 3); // cache_id=1, bpp_id=6 (32bpp)
        push_secondary(&mut orders, extra, 0x04, &bm_body);

        // Primary MemBlt (0x0D): TS_STANDARD | TS_TYPE_CHANGE, all 9 fields (0x01FF)
        orders.push(0x01 | 0x08);
        orders.push(0x0D);
        orders.extend_from_slice(&0x01FFu16.to_le_bytes());
        orders.extend_from_slice(&1u16.to_le_bytes()); // cache_id = 1
        orders.extend_from_slice(&4i16.to_le_bytes()); // left
        orders.extend_from_slice(&4i16.to_le_bytes()); // top
        orders.extend_from_slice(&2i16.to_le_bytes()); // width
        orders.extend_from_slice(&2i16.to_le_bytes()); // height
        orders.push(0xCC); // SRCCOPY
        orders.extend_from_slice(&0i16.to_le_bytes()); // src_x
        orders.extend_from_slice(&0i16.to_le_bytes()); // src_y
        orders.extend_from_slice(&3u16.to_le_bytes()); // cache_index = 3

        let packet = wrap_fastpath_orders(2, &orders);
        let outputs = stage
            .process(&mut image, Action::FastPath, &packet, None)
            .unwrap();
        assert!(outputs
            .iter()
            .any(|o| matches!(o, ActiveStageOutput::GraphicsUpdate(_))));
        assert_eq!(pixel(&image, 4, 4), [220, 0, 0, 255]);
        assert_eq!(pixel(&image, 5, 4), [210, 210, 0, 255]);
        assert_eq!(pixel(&image, 4, 5), [0, 0, 200, 255]);
        assert_eq!(pixel(&image, 5, 5), [0, 180, 0, 255]);

        // 2) Overlapping ScrBlt scroll from (4,4) size 2x2 -> (5,4)
        let mut scr = Vec::new();
        scr.push(0x01 | 0x08);
        scr.push(0x02); // ScrBlt
        scr.push(0x7F); // all 7 fields
        scr.extend_from_slice(&5i16.to_le_bytes());
        scr.extend_from_slice(&4i16.to_le_bytes());
        scr.extend_from_slice(&2i16.to_le_bytes());
        scr.extend_from_slice(&2i16.to_le_bytes());
        scr.push(0xCC);
        scr.extend_from_slice(&4i16.to_le_bytes());
        scr.extend_from_slice(&4i16.to_le_bytes());
        stage
            .process(
                &mut image,
                Action::FastPath,
                &wrap_fastpath_orders(1, &scr),
                None,
            )
            .unwrap();
        assert_eq!(pixel(&image, 5, 4), [220, 0, 0, 255]);
        assert_eq!(pixel(&image, 6, 4), [210, 210, 0, 255]);

        // 3) OffscreenBitmapCache: Create(id=7, 4x4) -> SwitchSurface(7) -> OpaqueRect(fill 12,34,56) -> SwitchSurface(0xFFFF)
        let mut off_draw = Vec::new();
        // AltSec CreateOffscreenBitmap (orderType=1 => controlFlags=0x04)
        off_draw.push(0x01 << 2);
        off_draw.extend_from_slice(&7u16.to_le_bytes());
        off_draw.extend_from_slice(&4u16.to_le_bytes());
        off_draw.extend_from_slice(&4u16.to_le_bytes());
        // AltSec SwitchSurface(7) (orderType=0 => controlFlags=0x00)
        off_draw.push(0x00);
        off_draw.extend_from_slice(&7u16.to_le_bytes());
        // OpaqueRect (0x0A) filling offscreen (0,0,4,4) with RGB(12,34,56)
        off_draw.push(0x01 | 0x08);
        off_draw.push(0x0A);
        off_draw.push(0x7F);
        off_draw.extend_from_slice(&0i16.to_le_bytes());
        off_draw.extend_from_slice(&0i16.to_le_bytes());
        off_draw.extend_from_slice(&4i16.to_le_bytes());
        off_draw.extend_from_slice(&4i16.to_le_bytes());
        off_draw.extend_from_slice(&[12, 34, 56]);
        // AltSec SwitchSurface(0xFFFF) back to primary
        off_draw.push(0x00);
        off_draw.extend_from_slice(&0xFFFFu16.to_le_bytes());
        let off_out = stage
            .process(
                &mut image,
                Action::FastPath,
                &wrap_fastpath_orders(4, &off_draw),
                None,
            )
            .unwrap();
        // Drawing purely to offscreen surface must NOT dirty the primary framebuffer.
        assert!(!off_out
            .iter()
            .any(|o| matches!(o, ActiveStageOutput::GraphicsUpdate(_))));

        // Now MemBlt from offscreen (cache_id=0xFF, cache_index=7) to primary (20, 20)
        let mut blit_off = Vec::new();
        blit_off.push(0x01 | 0x08);
        blit_off.push(0x0D);
        blit_off.extend_from_slice(&0x01FFu16.to_le_bytes());
        blit_off.extend_from_slice(&0x00FFu16.to_le_bytes()); // offscreen cache_id
        blit_off.extend_from_slice(&20i16.to_le_bytes());
        blit_off.extend_from_slice(&20i16.to_le_bytes());
        blit_off.extend_from_slice(&4i16.to_le_bytes());
        blit_off.extend_from_slice(&4i16.to_le_bytes());
        blit_off.push(0xCC);
        blit_off.extend_from_slice(&0i16.to_le_bytes());
        blit_off.extend_from_slice(&0i16.to_le_bytes());
        blit_off.extend_from_slice(&7u16.to_le_bytes());
        stage
            .process(
                &mut image,
                Action::FastPath,
                &wrap_fastpath_orders(1, &blit_off),
                None,
            )
            .unwrap();
        assert_eq!(pixel(&image, 20, 20), [12, 34, 56, 255]);
        assert_eq!(pixel(&image, 23, 23), [12, 34, 56, 255]);

        // 4) CacheGlyphV2 (cache_id=2, 1 glyph at idx=5: 2x2 diagonal 0x80, 0x40) + FastIndex with fragment store & reuse
        let mut glyph_orders = Vec::new();
        let glyph_body = [
            5u8, // cache_index = 5
            0, 0, // x=0, y=0
            2, 2,    // cx=2, cy=2
            0x80, // row 0: bit 0 set => (0, 0)
            0x40, // row 1: bit 1 set => (1, 1)
        ];
        // extra_flags: cache_id=2, count=1 in high byte
        push_secondary(&mut glyph_orders, 2u16 | (1u16 << 8), 0x09, &glyph_body);

        // FastIndex (0x13): draw glyph 5 twice (x=30 and x=34) in RGB(250, 10, 20) on bg RGB(5, 6, 7)
        glyph_orders.push(0x01 | 0x08);
        glyph_orders.push(0x13);
        glyph_orders.extend_from_slice(&0x7FFFu16.to_le_bytes());
        glyph_orders.push(2); // cache_id = 2
        glyph_orders.extend_from_slice(&0x0004u16.to_le_bytes()); // ulCharInc=4, flAccel=0
        glyph_orders.extend_from_slice(&[250, 10, 20]); // backColor = glyph foreground
        glyph_orders.extend_from_slice(&[5, 6, 7]); // foreColor = opRect background
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // bk_left
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // bk_top
        glyph_orders.extend_from_slice(&38i16.to_le_bytes()); // bk_right
        glyph_orders.extend_from_slice(&34i16.to_le_bytes()); // bk_bottom
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // op_left
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // op_top
        glyph_orders.extend_from_slice(&38i16.to_le_bytes()); // op_right
        glyph_orders.extend_from_slice(&34i16.to_le_bytes()); // op_bottom
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // x
        glyph_orders.extend_from_slice(&30i16.to_le_bytes()); // y
        let stream = [5u8, 0xFF, 0, 1, 0xFE, 0]; // glyph 5, store frag 0 (len 1), replay frag 0
        glyph_orders.push(stream.len() as u8);
        glyph_orders.extend_from_slice(&stream);
        stage
            .process(
                &mut image,
                Action::FastPath,
                &wrap_fastpath_orders(2, &glyph_orders),
                None,
            )
            .unwrap();
        assert_eq!(pixel(&image, 30, 30), [250, 10, 20, 255]); // glyph #1 (0,0)
        assert_eq!(pixel(&image, 31, 30), [5, 6, 7, 255]); // opRect background
        assert_eq!(pixel(&image, 31, 31), [250, 10, 20, 255]); // glyph #1 (1,1)
        assert_eq!(pixel(&image, 34, 30), [250, 10, 20, 255]); // replayed frag glyph #2 (0,0)
        assert_eq!(pixel(&image, 35, 31), [250, 10, 20, 255]); // replayed frag glyph #2 (1,1)

        // 5) Reactivation clears caches so old cached bitmap is gone.
        assert!(stage.reactivate(1003, 1001, 2, false, false, 1600));
        let post_reset = stage
            .process(
                &mut image,
                Action::FastPath,
                &wrap_fastpath_orders(1, &blit_off),
                None,
            )
            .unwrap();
        assert!(!post_reset
            .iter()
            .any(|o| matches!(o, ActiveStageOutput::GraphicsUpdate(_))));
    }
}
