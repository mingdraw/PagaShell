use futures::TryStreamExt;
use tokio_stream::wrappers::ReceiverStream;

use std::{
    future::Future,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc,
    },
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{
        mpsc::{channel, error::TryRecvError, Receiver, Sender},
        oneshot, Mutex,
    },
};
use tokio_util::compat::*;
use tracing::*;

use crate::{codec, PixelFormat, Rect, VncEncoding, VncError, VncEvent, X11Event};
const NETWORK_CHANNEL_SIZE: usize = 4096;
const INPUT_CHANNEL_SIZE: usize = 4096;
const OUTPUT_CHANNEL_SIZE: usize = 2;

mod output;

#[cfg(not(target_arch = "wasm32"))]
use tokio::spawn;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen_futures::spawn_local as spawn;

use super::messages::{ClientMsg, ServerMsg};
use super::resize::DesktopState;

struct ImageRect {
    rect: Rect,
    encoding: VncEncoding,
}

impl TryFrom<[u8; 12]> for ImageRect {
    type Error = VncError;
    fn try_from(buf: [u8; 12]) -> Result<Self, VncError> {
        Ok(Self {
            rect: Rect {
                x: ((buf[0] as u16) << 8) | buf[1] as u16,
                y: ((buf[2] as u16) << 8) | buf[3] as u16,
                width: ((buf[4] as u16) << 8) | buf[5] as u16,
                height: ((buf[6] as u16) << 8) | buf[7] as u16,
            },
            encoding: VncEncoding::from_wire(
                ((buf[8] as u32) << 24)
                    | ((buf[9] as u32) << 16)
                    | ((buf[10] as u32) << 8)
                    | (buf[11] as u32),
            )?,
        })
    }
}

impl ImageRect {
    async fn read<S>(reader: &mut S) -> Result<Self, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let mut rect_buf = [0_u8; 12];
        reader.read_exact(&mut rect_buf).await?;
        rect_buf.try_into()
    }
}

/// The framebuffer size is shared between the decoder, which learns of resizes,
/// and the input path, which sizes refresh requests; pack it into one atomic.
fn pack_screen((width, height): (u16, u16)) -> u32 {
    (u32::from(width) << 16) | u32::from(height)
}

fn unpack_screen(packed: u32) -> (u16, u16) {
    ((packed >> 16) as u16, packed as u16)
}

struct StopHandles {
    decoding_stop: Option<oneshot::Sender<()>>,
    net_conn_stop: Option<oneshot::Sender<()>>,
}

impl StopHandles {
    fn trigger(&mut self) {
        if let Some(stop) = self.net_conn_stop.take() {
            let _ = stop.send(());
        }
        if let Some(stop) = self.decoding_stop.take() {
            let _ = stop.send(());
        }
    }
}

struct VncInner {
    name: String,
    screen: Arc<AtomicU32>,
    pixel_format: Arc<std::sync::Mutex<PixelFormat>>,
    desktop: Arc<DesktopState>,
    input_ch: Sender<ClientMsg>,
    output_ch: Receiver<VncEvent>,
    stop: Arc<std::sync::Mutex<StopHandles>>,
    closed: Arc<AtomicBool>,
}

fn build_input_message(
    screen: &AtomicU32,
    closed: &AtomicBool,
    event: X11Event,
) -> Result<ClientMsg, VncError> {
    if closed.load(Ordering::Acquire) {
        return Err(VncError::ClientNotRunning);
    }
    let (width, height) = unpack_screen(screen.load(Ordering::Acquire));
    let msg = match event {
        X11Event::Refresh => ClientMsg::FramebufferUpdateRequest(
            Rect {
                x: 0,
                y: 0,
                width,
                height,
            },
            1,
        ),
        X11Event::FullRefresh => ClientMsg::FramebufferUpdateRequest(
            Rect {
                x: 0,
                y: 0,
                width,
                height,
            },
            0, // non-incremental: server sends entire framebuffer
        ),
        X11Event::KeyEvent(key) => ClientMsg::KeyEvent(key.keycode, key.down),
        X11Event::PointerEvent(mouse) => {
            ClientMsg::PointerEvent(mouse.position_x, mouse.position_y, mouse.bottons)
        }
        X11Event::CopyText(text) => {
            if text.len() > crate::limits::MAX_TEXT {
                return Err(VncError::InvalidImageData);
            }
            ClientMsg::ClientCutText(text)
        }
    };
    Ok(msg)
}

/// The instance of a connected vnc client
///
impl VncInner {
    #[allow(clippy::too_many_arguments)]
    async fn new<S>(
        mut stream: S,
        shared: bool,
        mut pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
        prefer_server_true_color_32: bool,
        emit_frame_complete: bool,
        output_channel_capacity: Option<usize>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let (conn_ch_tx, conn_ch_rx) = channel(NETWORK_CHANNEL_SIZE);
        let (input_ch_tx, input_ch_rx) = channel(INPUT_CHANNEL_SIZE);
        let output_capacity = output_channel_capacity
            .unwrap_or(OUTPUT_CHANNEL_SIZE)
            .max(2);
        let (output_ch_tx, output_ch_rx) = channel(output_capacity);
        let (decoding_stop_tx, mut decoding_stop_rx) = oneshot::channel();
        let (net_conn_stop_tx, net_conn_stop_rx) = oneshot::channel();

        trace!("client init msg");
        send_client_init(&mut stream, shared).await?;

        trace!("server init msg");
        let (name, (width, height)) = read_server_init_with_options(
            &mut stream,
            &mut pixel_format,
            prefer_server_true_color_32,
            &|e| async {
                output_ch_tx.send(e).await?;
                Ok(())
            },
        )
        .await?;

        let screen = Arc::new(AtomicU32::new(pack_screen((width, height))));
        let decoder_screen = Arc::clone(&screen);
        let initial_pf = *pixel_format.as_ref().unwrap();
        let shared_pf = Arc::new(std::sync::Mutex::new(initial_pf));
        let decoder_pf = Arc::clone(&shared_pf);
        let desktop = Arc::new(DesktopState::default());
        let decoder_desktop = Arc::clone(&desktop);
        let network_desktop = Arc::clone(&desktop);
        trace!("client encodings: {:?}", encodings);
        send_client_encoding(&mut stream, encodings.clone()).await?;

        trace!("Require the first frame");
        input_ch_tx
            .send(ClientMsg::FramebufferUpdateRequest(
                Rect {
                    x: 0,
                    y: 0,
                    width,
                    height,
                },
                0,
            ))
            .await?;

        // start the decoding thread
        spawn(async move {
            trace!("Decoding thread starts");
            let mut conn_ch_rx = {
                let conn_ch_rx = ReceiverStream::new(conn_ch_rx).into_async_read();
                FuturesAsyncReadCompatExt::compat(conn_ch_rx)
            };

            let output_func = |e| async {
                output_ch_tx.send(e).await?;
                Ok(())
            };

            let result = asycn_vnc_read_loop_with_options(
                &mut conn_ch_rx,
                &decoder_pf,
                &output_func,
                &mut decoding_stop_rx,
                &encodings,
                &decoder_screen,
                &decoder_desktop,
                emit_frame_complete,
            )
            .await;
            // Release the network worker and fail any pending resize before waiting
            // for output capacity.
            drop(conn_ch_rx);
            decoder_desktop.close();
            if let Err(error) = result {
                output::report_error(error, &output_ch_tx, &mut decoding_stop_rx).await;
            }
            trace!("Decoding thread stops");
        });

        // start the traffic process thread
        spawn(async move {
            trace!("Net Connection thread starts");
            let _ =
                async_connection_process_loop(stream, input_ch_rx, conn_ch_tx, net_conn_stop_rx)
                    .await;
            network_desktop.close();
            trace!("Net Connection thread stops");
        });

        info!("VNC Client {name} starts");
        Ok(Self {
            name,
            screen,
            pixel_format: shared_pf,
            desktop,
            input_ch: input_ch_tx,
            output_ch: output_ch_rx,
            stop: Arc::new(std::sync::Mutex::new(StopHandles {
                decoding_stop: Some(decoding_stop_tx),
                net_conn_stop: Some(net_conn_stop_tx),
            })),
            closed: Arc::new(AtomicBool::new(false)),
        })
    }

    async fn recv_event(&mut self) -> Result<VncEvent, VncError> {
        if self.closed.load(Ordering::Acquire) {
            Err(VncError::ClientNotRunning)
        } else {
            match self.output_ch.recv().await {
                Some(e) => Ok(e),
                None => {
                    self.closed.store(true, Ordering::Release);
                    Err(VncError::ClientNotRunning)
                }
            }
        }
    }

    async fn poll_event(&mut self) -> Result<Option<VncEvent>, VncError> {
        if self.closed.load(Ordering::Acquire) {
            Err(VncError::ClientNotRunning)
        } else {
            match self.output_ch.try_recv() {
                Err(TryRecvError::Disconnected) => {
                    self.closed.store(true, Ordering::Release);
                    Err(VncError::ClientNotRunning)
                }
                Err(TryRecvError::Empty) => Ok(None),
                Ok(e) => Ok(Some(e)),
            }
            // Ok(self.output_ch.recv().await)
        }
    }

    /// Stop the VNC engine and release resources
    ///
    fn close(&mut self) -> Result<(), VncError> {
        self.closed.store(true, Ordering::Release);
        self.desktop.close();
        self.stop
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .trigger();
        Ok(())
    }
}

impl Drop for VncInner {
    fn drop(&mut self) {
        info!("VNC Client {} stops", self.name);
        let _ = self.close();
    }
}

pub struct VncClient {
    inner: Arc<Mutex<VncInner>>,
    screen: Arc<AtomicU32>,
    pixel_format: Arc<std::sync::Mutex<PixelFormat>>,
    closed: Arc<AtomicBool>,
    stop: Arc<std::sync::Mutex<StopHandles>>,
    desktop: Arc<DesktopState>,
    input_ch: Sender<ClientMsg>,
    is_apple_server: bool,
}

impl VncClient {
    #[cfg(test)]
    pub(super) async fn new<S>(
        stream: S,
        shared: bool,
        pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        Self::new_with_options(
            stream,
            shared,
            pixel_format,
            encodings,
            false,
            false,
            false,
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn new_with_options<S>(
        stream: S,
        shared: bool,
        pixel_format: Option<PixelFormat>,
        encodings: Vec<VncEncoding>,
        prefer_server_true_color_32: bool,
        is_apple_server: bool,
        emit_frame_complete: bool,
        output_channel_capacity: Option<usize>,
    ) -> Result<Self, VncError>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let inner = VncInner::new(
            stream,
            shared,
            pixel_format,
            encodings,
            prefer_server_true_color_32,
            emit_frame_complete,
            output_channel_capacity,
        )
        .await?;
        Ok(Self {
            screen: Arc::clone(&inner.screen),
            pixel_format: Arc::clone(&inner.pixel_format),
            closed: Arc::clone(&inner.closed),
            stop: Arc::clone(&inner.stop),
            desktop: Arc::clone(&inner.desktop),
            input_ch: inner.input_ch.clone(),
            inner: Arc::new(Mutex::new(inner)),
            is_apple_server,
        })
    }

    /// Whether the remote VNC server identified as Apple Screen Sharing / Remote Desktop.
    pub fn is_apple_server(&self) -> bool {
        self.is_apple_server
    }

    /// Currently active decoder pixel format.
    pub fn pixel_format(&self) -> PixelFormat {
        *self
            .pixel_format
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Switch the wire pixel format between updates (call only when no
    /// FramebufferUpdate is in flight). The decoder emits
    /// `VncEvent::SetPixelFormat` before decoding the next frame in the new format.
    pub async fn set_pixel_format(&self, pf: PixelFormat) -> Result<(), VncError> {
        pf.validate()?;
        if self.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        let permit = self.input_ch.reserve().await?;
        if self.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        *self
            .pixel_format
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = pf;
        permit.send(ClientMsg::SetPixelFormat(pf));
        Ok(())
    }

    /// Last validated ExtendedDesktopSize layout; None means support is unconfirmed.
    pub fn desktop_layout(&self) -> Option<crate::DesktopLayout> {
        self.desktop.layout()
    }

    /// Request a negotiated single-screen resize and wait for the server result.
    /// Available on native targets with a Tokio time driver; wasm supports observation only.
    /// Continue draining events concurrently. Each queue/confirmation wait is bounded
    /// to five seconds. Cancellation after dispatch makes later requests uncertain;
    /// reconnect and observe before retrying. Dispatch includes one incremental one-pixel
    /// update request so servers can deliver the confirmation.
    #[cfg(not(target_arch = "wasm32"))]
    pub async fn resize_desktop(
        &self,
        width: u16,
        height: u16,
    ) -> Result<crate::DesktopLayout, crate::ResizeError> {
        self.desktop.request(&self.input_ch, width, height).await
    }

    /// Input a `X11Event` from the frontend
    ///
    pub async fn input(&self, event: X11Event) -> Result<(), VncError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(VncError::ClientNotRunning);
        }
        // Lock-free: recv_event() holds self.inner across awaits; input must not
        // contend with it, and close() publishes closed atomically.
        let permit = self.input_ch.reserve().await?;
        permit.send(build_input_message(&self.screen, &self.closed, event)?);
        Ok(())
    }

    /// Input an ordered sequence of `X11Event`s from the frontend.
    pub async fn input_batch<I>(&self, events: I) -> Result<(), VncError>
    where
        I: IntoIterator<Item = X11Event>,
    {
        for event in events {
            self.input(event).await?;
        }
        Ok(())
    }

    /// Receive a `VncEvent` from the engine
    /// This function will block until a `VncEvent` is received
    ///
    pub async fn recv_event(&self) -> Result<VncEvent, VncError> {
        self.inner.lock().await.recv_event().await
    }

    /// polling `VncEvent` from the engine and give it to the client
    ///
    pub async fn poll_event(&self) -> Result<Option<VncEvent>, VncError> {
        self.inner.lock().await.poll_event().await
    }

    /// Stop the VNC engine and release resources
    ///
    pub async fn close(&self) -> Result<(), VncError> {
        self.closed.store(true, Ordering::Release);
        self.desktop.close();
        self.stop
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .trigger();
        Ok(())
    }
}

impl Clone for VncClient {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            screen: Arc::clone(&self.screen),
            pixel_format: Arc::clone(&self.pixel_format),
            closed: Arc::clone(&self.closed),
            stop: Arc::clone(&self.stop),
            desktop: Arc::clone(&self.desktop),
            input_ch: self.input_ch.clone(),
            is_apple_server: self.is_apple_server,
        }
    }
}

async fn send_client_init<S>(stream: &mut S, shared: bool) -> Result<(), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    trace!("Send shared flag: {}", shared);
    stream.write_u8(shared as u8).await?;
    Ok(())
}

#[cfg(test)]
async fn read_server_init<S, F, Fut>(
    stream: &mut S,
    pf: &mut Option<PixelFormat>,
    output_func: &F,
) -> Result<(String, (u16, u16)), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    read_server_init_with_options(stream, pf, false, output_func).await
}

async fn read_server_init_with_options<S, F, Fut>(
    stream: &mut S,
    pf: &mut Option<PixelFormat>,
    prefer_server_true_color_32: bool,
    output_func: &F,
) -> Result<(String, (u16, u16)), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    // +--------------+--------------+------------------------------+
    // | No. of bytes | Type [Value] | Description                  |
    // +--------------+--------------+------------------------------+
    // | 2            | U16          | framebuffer-width in pixels  |
    // | 2            | U16          | framebuffer-height in pixels |
    // | 16           | PIXEL_FORMAT | server-pixel-format          |
    // | 4            | U32          | name-length                  |
    // | name-length  | U8 array     | name-string                  |
    // +--------------+--------------+------------------------------+

    let screen_width = stream.read_u16().await?;
    let screen_height = stream.read_u16().await?;
    crate::limits::dimensions(screen_width, screen_height)?;
    let mut send_our_pf = false;

    output_func(VncEvent::SetResolution(
        (screen_width, screen_height).into(),
    ))
    .await?;

    let pixel_format = PixelFormat::read(stream).await?;
    if pf.is_none() || (prefer_server_true_color_32 && pixel_format.is_native_true_color_32()) {
        output_func(VncEvent::SetPixelFormat(pixel_format)).await?;
        let _ = pf.insert(pixel_format);
    } else {
        send_our_pf = true;
    }

    let name = crate::limits::string(stream, crate::limits::MAX_NAME).await?;

    if send_our_pf {
        let chosen = *pf.as_ref().unwrap();
        trace!("Send customized pixel format {:#?}", chosen);
        ClientMsg::SetPixelFormat(chosen).write(stream).await?;
        if prefer_server_true_color_32 {
            output_func(VncEvent::SetPixelFormat(chosen)).await?;
        }
    }
    Ok((name, (screen_width, screen_height)))
}

async fn send_client_encoding<S>(
    stream: &mut S,
    encodings: Vec<VncEncoding>,
) -> Result<(), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    ClientMsg::SetEncodings(encodings).write(stream).await?;
    Ok(())
}

#[cfg(test)]
async fn asycn_vnc_read_loop<S, F, Fut>(
    stream: &mut S,
    pf: &PixelFormat,
    output_func: &F,
    stop_ch: &mut oneshot::Receiver<()>,
    encodings: &[VncEncoding],
    screen: &AtomicU32,
    desktop: &DesktopState,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    let shared_pf = std::sync::Mutex::new(*pf);
    asycn_vnc_read_loop_with_options(
        stream,
        &shared_pf,
        output_func,
        stop_ch,
        encodings,
        screen,
        desktop,
        false,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn asycn_vnc_read_loop_with_options<S, F, Fut>(
    stream: &mut S,
    shared_pf: &std::sync::Mutex<PixelFormat>,
    output_func: &F,
    stop_ch: &mut oneshot::Receiver<()>,
    encodings: &[VncEncoding],
    screen: &AtomicU32,
    desktop: &DesktopState,
    emit_frame_complete: bool,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    tokio::select! {
        biased;
        _ = stop_ch => Ok(()),
        result = read_vnc_messages(
            stream,
            shared_pf,
            output_func,
            encodings,
            screen,
            desktop,
            emit_frame_complete,
        ) => result,
    }
}

async fn read_vnc_messages<S, F, Fut>(
    stream: &mut S,
    shared_pf: &std::sync::Mutex<PixelFormat>,
    output_func: &F,
    encodings: &[VncEncoding],
    shared_screen: &AtomicU32,
    desktop: &DesktopState,
    emit_frame_complete: bool,
) -> Result<(), VncError>
where
    S: AsyncRead + Unpin,
    F: Fn(VncEvent) -> Fut,
    Fut: Future<Output = Result<(), VncError>>,
{
    let mut raw_decoder = codec::RawDecoder::new();
    let mut zrle_decoder = codec::ZrleDecoder::new();
    let mut tight_decoder = codec::TightDecoder::new();
    let mut trle_decoder = codec::TrleDecoder::new();
    let mut cursor = codec::CursorDecoder::new();
    let mut screen = unpack_screen(shared_screen.load(Ordering::Acquire));
    let mut active_pf = *shared_pf
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    // main decoding loop
    loop {
        let server_msg = ServerMsg::read(stream).await?;
        trace!("Server message got: {:?}", server_msg);
        match server_msg {
            ServerMsg::FramebufferUpdate(rect_num) => {
                let next_pf = *shared_pf
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if next_pf != active_pf {
                    active_pf = next_pf;
                    output_func(VncEvent::SetPixelFormat(active_pf)).await?;
                }
                let pf = &active_pf;
                let mut updates = crate::desktop::UpdateBatch::default();
                let mut framebuffer_changed = false;
                for _ in 0..rect_num {
                    let rect = ImageRect::read(stream).await?;
                    if rect.encoding != VncEncoding::Raw && !encodings.contains(&rect.encoding) {
                        return Err(VncError::InvalidImageData);
                    }
                    if !matches!(
                        rect.encoding,
                        VncEncoding::DesktopSizePseudo
                            | VncEncoding::ExtendedDesktopSizePseudo
                            | VncEncoding::LastRectPseudo
                            | VncEncoding::CursorPseudo
                    ) {
                        crate::limits::rectangle(&rect.rect, screen)?;
                    }
                    if !matches!(
                        rect.encoding,
                        VncEncoding::CursorPseudo
                            | VncEncoding::ExtendedDesktopSizePseudo
                            | VncEncoding::LastRectPseudo
                    ) {
                        if !updates.is_empty() {
                            return Err(VncError::InvalidImageData);
                        }
                        framebuffer_changed = true;
                    }

                    match rect.encoding {
                        VncEncoding::Raw => {
                            raw_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::CopyRect => {
                            let source_x = stream.read_u16().await?;
                            let source_y = stream.read_u16().await?;
                            let mut src_rect = rect.rect;
                            src_rect.x = source_x;
                            src_rect.y = source_y;
                            crate::limits::rectangle(&src_rect, screen)?;
                            output_func(VncEvent::Copy(rect.rect, src_rect)).await?;
                        }
                        VncEncoding::Tight => {
                            tight_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::Trle => {
                            trle_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::Zrle => {
                            zrle_decoder
                                .decode(pf, &rect.rect, stream, output_func)
                                .await?;
                        }
                        VncEncoding::CursorPseudo => {
                            cursor.decode(pf, &rect.rect, stream, output_func).await?;
                        }
                        VncEncoding::ExtendedDesktopSizePseudo => {
                            // Confirm only after the entire message excludes framebuffer changes.
                            // Cursor metadata may accompany desktop layout updates.
                            if framebuffer_changed {
                                return Err(VncError::InvalidImageData);
                            }
                            updates.push(crate::DesktopUpdate::read(stream, rect.rect).await?)?;
                        }
                        VncEncoding::DesktopSizePseudo => {
                            crate::limits::dimensions(rect.rect.width, rect.rect.height)?;
                            if rect.rect.x != 0 || rect.rect.y != 0 {
                                return Err(VncError::InvalidImageData);
                            }
                            screen = (rect.rect.width, rect.rect.height);
                            shared_screen.store(pack_screen(screen), Ordering::Release);
                            desktop.legacy_resize();
                            output_func(VncEvent::SetResolution(
                                (rect.rect.width, rect.rect.height).into(),
                            ))
                            .await?;
                        }
                        VncEncoding::LastRectPseudo => {
                            break;
                        }
                    }
                }
                for update in updates.into_updates() {
                    if let Some(layout) = &update.layout {
                        screen = (layout.width, layout.height);
                        shared_screen.store(pack_screen(screen), Ordering::Release);
                    }
                    desktop.observe(&update);
                    output_func(VncEvent::DesktopUpdate(update)).await?;
                }
                if emit_frame_complete {
                    output_func(VncEvent::FrameComplete).await?;
                }
            }
            ServerMsg::SetColorMapEntries => {}
            ServerMsg::Bell => {
                output_func(VncEvent::Bell).await?;
            }
            ServerMsg::ServerCutText(text) => {
                output_func(VncEvent::Text(text)).await?;
            }
        }
    }
}

async fn async_connection_process_loop<S>(
    mut stream: S,
    mut input_ch: Receiver<ClientMsg>,
    conn_ch: Sender<std::io::Result<Vec<u8>>>,
    mut stop_ch: oneshot::Receiver<()>,
) -> Result<(), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut buffer = vec![0u8; 131_072];
    let mut write_buf = Vec::with_capacity(256);
    let mut pending = 0;

    loop {
        tokio::select! {
            _ = &mut stop_ch => break,
            _ = conn_ch.closed() => break,
            permit = conn_ch.reserve(), if pending > 0 => {
                match permit {
                    Ok(permit) => {
                        permit.send(Ok(buffer[..pending].to_vec()));
                        pending = 0;
                    }
                    Err(_) => break,
                }
            }
            result = stream.read(&mut buffer), if pending == 0 => {
                match result {
                    Ok(0) | Err(_) => break,
                    Ok(length) => pending = length,
                }
            }
            message = input_ch.recv() => {
                let Some(message) = message else { break; };
                write_buf.clear();
                message.encode_into(&mut write_buf)?;
                for _ in 0..63 {
                    match input_ch.try_recv() {
                        Ok(next) => next.encode_into(&mut write_buf)?,
                        Err(_) => break,
                    }
                }
                tokio::select! {
                    biased;
                    _ = &mut stop_ch => break,
                    result = async {
                        stream.write_all(&write_buf).await?;
                        stream.flush().await
                    } => result?,
                }
                if write_buf.capacity() > 65_536 {
                    write_buf = Vec::with_capacity(256);
                }
            }
        }
    }
    // Dropping the bridge signals EOF without blocking shutdown on a full queue.
    Ok(())
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod queue_tests;

#[cfg(test)]
mod resize_tests;
