//! Embedded RFB desktop connections; passwords never leave the protocol engine.
use anyhow::Result;

pub async fn vnc_connect(
    host: String,
    port: u16,
    password: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    crate::vnc::connect(host, port, password, ssh_gateway_id, page_gateway).await
}

pub async fn vnc_frame(
    session_id: u32,
    after_sequence: u32,
) -> Result<Option<crate::api::desktop::DesktopFrame>> {
    crate::vnc::frame(session_id, after_sequence).await
}

/// kind: 0 X11 keysym, 1 pointer with desktop pointer flags, 2 Unicode text.
pub async fn vnc_input(
    session_id: u32,
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    crate::vnc::input(session_id, kind, code, flags, x, y, text).await
}

pub async fn vnc_disconnect(session_id: u32) -> Result<()> {
    crate::vnc::disconnect(session_id).await;
    Ok(())
}
