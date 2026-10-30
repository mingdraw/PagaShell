//! Interactive RDP desktop APIs, over direct TCP or an SSH gateway.
use anyhow::Result;

pub struct DesktopHandshake {
    pub session_id: u32,
    pub fingerprint: String,
    pub certificate_error: Option<String>,
}

#[derive(Clone, Debug, Default)]
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
    crate::desktop::clipboard_active(session_id, active, cache_directory).await
}

pub async fn desktop_clipboard_update(
    session_id: u32,
    text: Option<String>,
    files: Vec<String>,
) -> Result<()> {
    crate::desktop::clipboard_update(session_id, text, files).await
}

pub async fn desktop_clipboard_event(
    session_id: u32,
    after_sequence: u32,
) -> Result<Option<DesktopClipboardEvent>> {
    crate::desktop::clipboard_event(session_id, after_sequence).await
}

pub async fn desktop_clipboard_cancel(session_id: u32) -> Result<()> {
    crate::desktop::clipboard_cancel(session_id).await
}

pub struct DesktopFrame {
    pub sequence: u32,
    /// Full desktop size. Pixels contain a packed atlas of changed tiles.
    pub width: u16,
    pub height: u16,
    pub bitmap_width: u16,
    pub bitmap_height: u16,
    pub rgba: Vec<u8>,
    pub tiles: Vec<DesktopTile>,
    pub cursor: Option<DesktopCursor>,
}

pub struct DesktopTile {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub source_x: u16,
    pub source_y: u16,
}

#[derive(Clone)]
pub struct DesktopCursor {
    /// 0: local default pointer; 1: hidden; 2: RGBA bitmap.
    pub kind: u8,
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub rgba: Vec<u8>,
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
    crate::desktop::authenticate(session_id, expected_fingerprint, username, password, domain).await
}

/// Long poll coalesced damage. Pixels are copied only when a consumer is ready.
pub async fn desktop_frame(session_id: u32, after_sequence: u32) -> Result<Option<DesktopFrame>> {
    crate::desktop::frame(session_id, after_sequence).await
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
    crate::desktop::input(session_id, kind, code, flags, x, y, text).await
}

/// Requests a remote monitor size. False means Display Control was unavailable.
pub async fn desktop_resize(session_id: u32, width: u16, height: u16) -> Result<bool> {
    crate::desktop::resize(session_id, width, height).await
}

pub async fn desktop_disconnect(session_id: u32) -> Result<()> {
    crate::desktop::disconnect(session_id).await;
    Ok(())
}
