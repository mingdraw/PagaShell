//! Embedded RFB desktop connections; passwords never leave the protocol engine.
use anyhow::Result;
use flutter_rust_bridge::{for_generated::DcoCodec, frb};

use crate::api::desktop::{DesktopFrame, DesktopWorkerStarted};
use crate::frb_generated::StreamSink;

/// Starts a Windows VNC worker and returns its cancellable session before any
/// network operation starts. No target or credentials are passed on argv.
pub async fn vnc_worker_open() -> Result<DesktopWorkerStarted> {
    #[cfg(windows)]
    return crate::desktop_worker::open_vnc().await;
    #[cfg(not(windows))]
    anyhow::bail!("VNC 会话进程仅支持 Windows");
}

pub async fn vnc_worker_connect(
    session_id: u32,
    host: String,
    port: u16,
    password: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker
            .vnc_connect(host, port, password, ssh_gateway_id, page_gateway)
            .await;
    }
    let _ = (
        session_id,
        host,
        port,
        password,
        ssh_gateway_id,
        page_gateway,
    );
    anyhow::bail!("VNC 会话进程已关闭");
}

pub async fn vnc_connect(
    host: String,
    port: u16,
    password: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    crate::vnc::connect(host, port, password, ssh_gateway_id, page_gateway).await
}

#[frb(stream_dart_await)]
pub async fn vnc_frame(
    session_id: u32,
    after_sequence: u32,
    sink: StreamSink<Option<DesktopFrame>, DcoCodec>,
) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        let _ = sink.add(worker.vnc_frame(after_sequence).await?);
        return Ok(());
    }
    let frame = crate::vnc::frame(session_id, after_sequence).await?;
    let _ = sink.add(frame);
    Ok(())
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
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.vnc_input(kind, code, flags, x, y, text).await;
    }
    crate::vnc::input(session_id, kind, code, flags, x, y, text).await
}

pub async fn vnc_disconnect(session_id: u32) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::remove_vnc(session_id).await {
        worker.close().await;
        return Ok(());
    }
    crate::vnc::disconnect(session_id).await;
    Ok(())
}
