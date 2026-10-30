use std::collections::{HashMap, VecDeque};
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;

use crate::api::desktop::{DesktopCursor, DesktopFrame, DesktopHandshake};
use crate::desktop_clipboard::{Clipboard, Command as ClipboardCommand};
use crate::desktop_display::{DisplayControl, ResizeRequest};
use crate::desktop_frame::{FrameEncoder, FrameRequest};
use crate::desktop_input::HeldInputs;
use anyhow::{anyhow, bail, Context, Result};
use ironrdp::connector::{self, ClientConnector, Credentials};
use ironrdp::core::WriteBuf;
use ironrdp::dvc::DrdynvcClient;
use ironrdp::pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp::pdu::input::mouse::{MousePdu, PointerFlags};
use ironrdp::session::{ActiveStageBuilder, ActiveStageOutput};
use ironrdp_egfx::client::{GraphicsPipelineClient, GraphicsPipelineHandler};
use ironrdp_egfx::decode::{H264Decoder, OpenH264Decoder};
use ironrdp_tokio::{FramedWrite, TokioFramed};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch, Mutex};
use tokio_rustls::{client::TlsStream, rustls, TlsConnector};
use x509_cert::der::Decode;

pub(crate) enum Transport {
    Direct(TcpStream),
    Ssh(russh::ChannelStream<russh::client::Msg>),
    Page(Box<crate::page::PageStream>),
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
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_flush(cx),
            Self::Ssh(s) => Pin::new(s).poll_flush(cx),
            Self::Page(s) => Pin::new(s).poll_flush(cx),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Direct(s) => Pin::new(s).poll_shutdown(cx),
            Self::Ssh(s) => Pin::new(s).poll_shutdown(cx),
            Self::Page(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}
type Framed = TokioFramed<TlsStream<Transport>>;
const TIMEOUT: Duration = Duration::from_secs(30);
static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Desktop>>>> = LazyLock::new(Default::default);
struct Pending {
    connector: ClientConnector,
    upgraded: ironrdp_tokio::Upgraded,
    framed: Framed,
    public_key: Vec<u8>,
    host: String,
    display: DisplayControl,
    clipboard: Clipboard,
}
struct Desktop {
    fingerprint: String,
    pending: Mutex<Option<Pending>>,
    cancel: watch::Sender<bool>,
    commands: mpsc::Sender<Vec<FastPathInputEvent>>,
    receiver: Mutex<Option<mpsc::Receiver<Vec<FastPathInputEvent>>>>,
    frames: mpsc::Sender<FrameRequest>,
    requests: Mutex<Option<mpsc::Receiver<FrameRequest>>>,
    finished: watch::Sender<Option<String>>,
    resizes: mpsc::Sender<ResizeRequest>,
    resize_receiver: Mutex<Option<mpsc::Receiver<ResizeRequest>>>,
    clipboard: Clipboard,
}

struct GraphicsHandler;
impl GraphicsPipelineHandler for GraphicsHandler {}

fn graphics_pipeline() -> GraphicsPipelineClient {
    // Only advertise the AVC420 decoder we can actually construct. The upstream
    // handler keeps V8/non-AVC fallback and deliberately omits unsupported AVC444.
    let decoder = OpenH264Decoder::new()
        .ok()
        .map(|decoder| Box::new(decoder) as Box<dyn H264Decoder>);
    GraphicsPipelineClient::new(Box::new(GraphicsHandler), decoder)
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
    let pending = tokio::time::timeout(TIMEOUT, async {
        let stream = if let Some(gateway) = page_gateway {
            Transport::Page(Box::new(crate::page::connect(gateway, &host, port).await?))
        } else if let Some(id) = ssh_gateway {
            Transport::Ssh(crate::api::ssh::desktop_tunnel(id, host.clone(), port).await?)
        } else {
            let tcp = TcpStream::connect((host.as_str(), port))
                .await
                .context("RDP TCP 连接失败")?;
            tcp.set_nodelay(true)?;
            Transport::Direct(tcp)
        };
        let mut config = crate::rdp::config();
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
        let mut connector = ClientConnector::new(config, "0.0.0.0:0".parse()?);
        let display = DisplayControl::default();
        let clipboard = Clipboard::new();
        connector.attach_static_channel(clipboard.client());
        connector.attach_static_channel(
            DrdynvcClient::new()
                .with_dynamic_channel(graphics_pipeline())
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
            },
            fingerprint,
            verifier.certificate_error(),
        ))
    })
    .await
    .map_err(|_| anyhow!("RDP 服务连接超时"))?
    .map_err(|error| anyhow!("RDP 服务连接失败：{error:#}"))?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (commands, receiver) = mpsc::channel(256);
    let (frames, requests) = mpsc::channel(4);
    let (resizes, resize_receiver) = mpsc::channel(4);
    let fingerprint = pending.1;
    let clipboard = pending.0.clipboard.clone();
    let entry = Arc::new(Desktop {
        fingerprint: fingerprint.clone(),
        pending: Mutex::new(Some(pending.0)),
        cancel: watch::channel(false).0,
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

pub(crate) async fn authenticate(
    id: u32,
    expected: String,
    username: String,
    password: String,
    domain: String,
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
        } = pending;
        connector.config.credentials = Credentials::UsernamePassword { username, password };
        connector.config.domain = (!domain.is_empty()).then_some(domain);
        let result =
            crate::rdp_connection::finalize(upgraded, connector, &mut framed, host, public_key)
                .await?;
        Ok::<_, anyhow::Error>((result, framed, display, clipboard))
    };
    let result = tokio::select! { biased;
        _ = cancel.changed() => Err(anyhow!("连接已取消")),
        result = task => result,
    };
    let (result, framed, display, clipboard) = match result {
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
            requests,
            (display, clipboard),
            resizes,
        ),
    );
    Ok(())
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

pub(crate) async fn frame(id: u32, after: u32) -> Result<Option<DesktopFrame>> {
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
    let entry = session(id).await?;
    let events = input_events(kind, code, flags, x, y, text)?;
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
        0 => {
            if code > 255 || flags & !7 != 0 {
                bail!("无效的 RDP 按键");
            }
            vec![FastPathInputEvent::KeyboardEvent(
                KeyboardFlags::from_bits_retain(flags as u8),
                code as u8,
            )]
        }
        1 => {
            let flags = PointerFlags::from_bits(flags).context("无效的 RDP 鼠标事件")?;
            let wheel = code.min(255) as i16;
            let wheel = if flags.contains(PointerFlags::WHEEL_NEGATIVE) {
                -wheel
            } else {
                wheel
            };
            vec![FastPathInputEvent::MouseEvent(MousePdu {
                x_position: x,
                y_position: y,
                flags,
                number_of_wheel_rotation_units: wheel,
            })]
        }
        2 => {
            if text.len() > 8192 {
                bail!("RDP 文本过长");
            }
            text.encode_utf16()
                .flat_map(|c| {
                    [
                        FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), c),
                        FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, c),
                    ]
                })
                .collect()
        }
        _ => bail!("无效的 RDP 输入"),
    })
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

async fn run(
    result: connector::ConnectionResult,
    mut framed: Framed,
    mut commands: mpsc::Receiver<Vec<FastPathInputEvent>>,
    mut cancel: watch::Receiver<bool>,
    mut requests: mpsc::Receiver<FrameRequest>,
    controls: (DisplayControl, Clipboard),
    mut resizes: mpsc::Receiver<ResizeRequest>,
) -> Result<()> {
    let (display, clipboard) = controls;
    let mut clipboard_commands = clipboard.receiver();
    let mut clipboard_tick = tokio::time::interval(Duration::from_secs(5));
    clipboard_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let activation_factory = result.activation_factory;
    let mut image = crate::rdp::new_image(result.desktop_size)?;
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
    let mut tick = tokio::time::interval(Duration::from_millis(16));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut encoder = FrameEncoder::new(image.width(), image.height());
    let mut waiting: VecDeque<FrameRequest> = VecDeque::new();
    let mut held = HeldInputs::default();
    let diagnostics = crate::desktop_diagnostics::GraphicsDiagnostics::new();
    let mut pending_resize: Option<ResizeRequest> = None;
    let mut resize_deadline = tokio::time::Instant::now();
    loop {
        if *cancel.borrow() {
            break;
        }
        if let Some(request) = pending_resize.as_ref() {
            if request.reply.is_closed() {
                pending_resize = None;
            } else if let Some(encoded) =
                display.encode_resize(&mut stage, request.width, request.height)
            {
                let request = pending_resize.take().unwrap();
                match encoded {
                    Ok(bytes) => {
                        tokio::time::timeout(TIMEOUT, framed.write_all(&bytes))
                            .await
                            .context("RDP 分辨率请求发送超时")?
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
        let can_render = waiting
            .front()
            .is_some_and(|request| encoder.ready(request.after));
        // Fair polling keeps both sustained graphics and input traffic moving.
        let outputs = tokio::select! {
            _ = cancel.changed() => break,
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
                resize_deadline = tokio::time::Instant::now() + Duration::from_secs(3);
                continue;
            }
            _ = tokio::time::sleep_until(resize_deadline), if pending_resize.is_some() => {
                let request = pending_resize.take().unwrap();
                let _ = request.reply.send(Ok(false));
                continue;
            }
            events = commands.recv() => {
                let Some(events) = events else { break; };
                let outputs = stage.process_fastpath_input(&mut image, &events)?;
                held.record(&events);
                outputs
            }
            _ = tick.tick(), if can_render => {
                let request = waiting.pop_front().unwrap();
                if !request.reply.is_closed() {
                    let _ = request.reply.send(encoder.snapshot(&image, request.after));
                }
                continue;
            }
            request = requests.recv(), if waiting.len() < 4 => {
                let Some(request) = request else { return Ok(()); };
                waiting.push_back(request);
                continue;
            }
            _ = tokio::time::sleep(Duration::from_millis(500)), if !waiting.is_empty() => continue,
            packet = framed.read_pdu() => {
                let (action, bytes) = packet.context("RDP 数据接收失败")?;
                diagnostics.process(|| stage.process(&mut image, action, &bytes))?
            }
        };
        // EGFX may resize independently of connection reactivation. Enforce the
        // same pixel budget as the initial framebuffer and Flutter consumer.
        crate::rdp::validate_desktop_size(image.width(), image.height())?;
        // EGFX reports a bounding rectangle in GraphicsUpdate and preserves the
        // exact regions separately. Keep those regions separate through to Dart.
        let damage = stage.take_damage_regions();
        let exact_damage = !damage.is_empty();
        for rect in damage {
            encoder.damage(rect);
        }
        for output in outputs {
            match output {
                ActiveStageOutput::ResponseFrame(bytes) => {
                    tokio::time::timeout(TIMEOUT, framed.write_all(&bytes))
                        .await
                        .context("RDP 响应发送超时")?
                        .context("RDP 响应发送失败")?
                }
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
                    let mut activation = activation_factory.create();
                    let mut buf = WriteBuf::new();
                    tokio::time::timeout(TIMEOUT, async {
                        loop {
                            ironrdp_tokio::single_sequence_step(
                                &mut framed,
                                &mut activation,
                                &mut buf,
                            )
                            .await?;
                            use connector::connection_activation::ConnectionActivationState;
                            if let ConnectionActivationState::Finalized {
                                desktop_size,
                                share_id,
                                enable_server_pointer,
                                pointer_software_rendering,
                                static_channel_chunk_size,
                                ..
                            } = activation.connection_activation_state()
                            {
                                image = crate::rdp::new_image(desktop_size)?;
                                if !stage.reactivate(
                                    activation.io_channel_id(),
                                    activation.user_channel_id(),
                                    share_id,
                                    enable_server_pointer,
                                    pointer_software_rendering,
                                    static_channel_chunk_size,
                                ) {
                                    bail!("RDP 通道重新激活失败");
                                }
                                encoder = FrameEncoder::new(image.width(), image.height());
                                break;
                            }
                        }
                        Ok::<_, anyhow::Error>(())
                    })
                    .await??;
                }
                _ => {}
            }
        }
    }
    // The UI may be disposed before its queued releases reach native code.
    // Release only inputs actually processed by this session before disconnecting.
    let releases = held.releases();
    if !releases.is_empty() {
        let outputs = stage.process_fastpath_input(&mut image, &releases)?;
        let _ = tokio::time::timeout(Duration::from_millis(500), async {
            for output in outputs {
                if let ActiveStageOutput::ResponseFrame(bytes) = output {
                    framed.write_all(&bytes).await?;
                }
            }
            Ok::<_, std::io::Error>(())
        })
        .await;
    }
    Ok(())
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
            encode_avc420_bitmap_stream, Avc420Region, CapabilitiesConfirmPdu, CapabilityVersion,
            Codec1Type, CreateSurfacePdu, EndFramePdu, GfxPdu, MapSurfaceToOutputPdu, PixelFormat,
            ResetGraphicsPdu, WireToSurface1Pdu,
        };
        use openh264::encoder::Encoder;
        use openh264::formats::{RgbSliceU8, YUVBuffer};

        let mut client = graphics_pipeline();
        let advertised = client.start(1).unwrap();
        let GfxPdu::CapabilitiesAdvertise(advertised) =
            decode::<GfxPdu>(&encode_vec(advertised[0].as_ref()).unwrap()).unwrap()
        else {
            panic!("expected graphics capabilities");
        };
        assert_eq!(
            advertised
                .0
                .iter()
                .map(|cap| cap.version)
                .collect::<Vec<_>>(),
            vec![CapabilityVersion::V8_1, CapabilityVersion::V8],
        );

        // Exercise the actual bundled decoder with a locally generated IDR
        // frame, through the public ZGFX/DVC wire interface and compositor.
        let rgb = [64, 128, 192].repeat(64 * 64);
        let yuv = YUVBuffer::from_rgb_source(RgbSliceU8::new(&rgb, (64, 64)));
        let mut encoder = Encoder::new().unwrap();
        let h264 = encoder.encode(&yuv).unwrap().to_vec();
        let pdus = [
            GfxPdu::CapabilitiesConfirm(CapabilitiesConfirmPdu(advertised.0[0].clone())),
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
        assert_eq!(client.take_output_reset(), Some((64, 64)));
        let updates = client.drain_output();
        assert_eq!(updates.len(), 1);
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

        let mut fallback = GraphicsPipelineClient::new(Box::new(GraphicsHandler), None);
        let advertised = fallback.start(1).unwrap();
        let GfxPdu::CapabilitiesAdvertise(advertised) =
            decode::<GfxPdu>(&encode_vec(advertised[0].as_ref()).unwrap()).unwrap()
        else {
            panic!("expected fallback capabilities");
        };
        assert_eq!(advertised.0.len(), 1);
        assert_eq!(advertised.0[0].version, CapabilityVersion::V8);
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
            .send(DesktopFrame {
                sequence: 10,
                width: 1,
                height: 1,
                bitmap_width: 1,
                bitmap_height: 1,
                rgba: vec![10; 4],
                tiles: vec![],
                cursor: None,
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
}
