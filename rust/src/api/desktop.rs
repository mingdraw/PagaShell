//! Interactive RDP desktop APIs, over direct TCP or an SSH gateway.
use anyhow::Result;
use flutter_rust_bridge::{for_generated::DcoCodec, frb};

use crate::frb_generated::StreamSink;

macro_rules! route_worker {
    ($id:expr, $method:ident($($arg:expr),* $(,)?)) => {
        #[cfg(windows)]
        if let Some(worker) = crate::desktop_worker::get($id).await {
            return worker.$method($($arg),*).await;
        }
    };
}

#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopHandshake {
    pub session_id: u32,
    pub fingerprint: String,
    pub certificate_error: Option<String>,
}

#[derive(Clone, Debug, Default)]
#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopClipboardEvent {
    pub sequence: u32,
    /// 0: ready, 1: Unicode text, 2: cached files, 3: receiving, 4: error.
    pub kind: u8,
    pub text: Option<String>,
    pub files: Vec<String>,
    pub transferred: u64,
    pub total: u64,
    pub error: Option<String>,
}

pub async fn desktop_clipboard_active(
    session_id: u32,
    active: bool,
    cache_directory: String,
) -> Result<()> {
    route_worker!(session_id, clipboard_active(active, cache_directory));
    crate::desktop::clipboard_active(session_id, active, cache_directory).await
}

pub async fn desktop_clipboard_update(
    session_id: u32,
    text: Option<String>,
    files: Vec<String>,
) -> Result<()> {
    route_worker!(session_id, clipboard_update(text, files));
    crate::desktop::clipboard_update(session_id, text, files).await
}

pub async fn desktop_clipboard_event(
    session_id: u32,
    after_sequence: u32,
) -> Result<Option<DesktopClipboardEvent>> {
    route_worker!(session_id, clipboard_event(after_sequence));
    crate::desktop::clipboard_event(session_id, after_sequence).await
}

pub async fn desktop_clipboard_cancel(session_id: u32) -> Result<()> {
    route_worker!(session_id, clipboard_cancel());
    crate::desktop::clipboard_cancel(session_id).await
}

#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopFrame {
    pub sequence: u32,
    /// Full desktop size. Pixels contain the whole image or a packed atlas.
    pub width: u16,
    pub height: u16,
    pub bitmap_width: u16,
    pub bitmap_height: u16,
    // The process transport carries the actual pixels in shared memory.
    #[cfg_attr(any(windows, test), serde(skip))]
    pub rgba: Vec<u8>,
    pub tiles: Vec<DesktopTile>,
    pub cursor: Option<DesktopCursor>,
}

#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopTile {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub source_x: u16,
    pub source_y: u16,
}

#[derive(Clone)]
#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopCursor {
    /// 0: local default pointer; 1: hidden; 2: RGBA bitmap.
    pub kind: u8,
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub rgba: Vec<u8>,
}

pub struct DesktopWorkerStarted {
    pub session_id: u32,
    pub process_id: u32,
}

/// Starts a Windows direct RDP worker and returns its cancellable session before
/// any network operation starts. No target or credentials are passed on argv.
pub async fn desktop_worker_open() -> Result<DesktopWorkerStarted> {
    #[cfg(windows)]
    return crate::desktop_worker::open().await;
    #[cfg(not(windows))]
    anyhow::bail!("RDP 会话进程仅支持 Windows");
}

pub async fn desktop_worker_handshake(
    session_id: u32,
    host: String,
    port: u16,
) -> Result<DesktopHandshake> {
    route_worker!(session_id, handshake(session_id, host, port));
    let _ = (session_id, host, port);
    anyhow::bail!("RDP 会话进程已关闭");
}

/// An SSH gateway ID must refer to an already authenticated/verified session.
pub async fn desktop_handshake(
    host: String,
    port: u16,
    ssh_gateway_id: Option<u32>,
) -> Result<DesktopHandshake> {
    crate::desktop::prepare(host, port, ssh_gateway_id).await
}

pub async fn desktop_handshake_via_page(
    host: String,
    port: u16,
    gateway: crate::api::page::PageGateway,
) -> Result<DesktopHandshake> {
    crate::desktop::prepare_with_page(host, port, None, Some(gateway)).await
}

pub async fn desktop_authenticate(
    session_id: u32,
    expected_fingerprint: String,
    username: String,
    password: String,
    domain: String,
) -> Result<()> {
    route_worker!(
        session_id,
        authenticate(expected_fingerprint, username, password, domain)
    );
    crate::desktop::authenticate(session_id, expected_fingerprint, username, password, domain).await
}

async fn frame_for_session(session_id: u32, after_sequence: u32) -> Result<Option<DesktopFrame>> {
    route_worker!(session_id, frame(after_sequence));
    crate::desktop::frame(session_id, after_sequence).await
}

/// Long poll coalesced damage. Pixels are copied only when a consumer is ready.
/// The single result travels as DCO typed data rather than byte-by-byte SSE.
#[frb(stream_dart_await)]
pub async fn desktop_frame(
    session_id: u32,
    after_sequence: u32,
    sink: StreamSink<Option<DesktopFrame>, DcoCodec>,
) -> Result<()> {
    let frame = frame_for_session(session_id, after_sequence).await?;
    let _ = sink.add(frame);
    Ok(())
}

/// kind: 0 scan code, 1 pointer, 2 Unicode text. Flags are RDP wire flags.
pub async fn desktop_input(
    session_id: u32,
    kind: u8,
    code: u16,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    route_worker!(session_id, input(kind, code, flags, x, y, text));
    crate::desktop::input(session_id, kind, code, flags, x, y, text).await
}

#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct DesktopInputEvent {
    pub pointer: bool,
    pub code: u16,
    pub flags: u16,
    pub x: u16,
    pub y: u16,
}

/// Send ordered keyboard and pointer edges in one Fast-Path input PDU.
pub async fn desktop_input_batch(session_id: u32, events: Vec<DesktopInputEvent>) -> Result<()> {
    route_worker!(session_id, input_batch(events));
    crate::desktop::input_batch(session_id, events).await
}

/// Requests a remote monitor size. False means Display Control was unavailable.
pub async fn desktop_resize(session_id: u32, width: u16, height: u16) -> Result<bool> {
    route_worker!(session_id, resize(width, height));
    crate::desktop::resize(session_id, width, height).await
}

pub async fn desktop_disconnect(session_id: u32) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::remove(session_id).await {
        worker.close().await;
        return Ok(());
    }
    crate::desktop::disconnect(session_id).await;
    Ok(())
}
