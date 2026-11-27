//! Embedded RFB desktop connections; passwords never leave the protocol engine.
use anyhow::Result;
use flutter_rust_bridge::{for_generated::DcoCodec, frb};

use crate::api::desktop::{
    DesktopClipboardEvent, DesktopFrame, DesktopNetworkStats, DesktopWorkerStarted,
};
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
    username: String,
    password: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker
            .vnc_connect(host, port, username, password, ssh_gateway_id, page_gateway)
            .await;
    }
    let _ = (
        session_id,
        host,
        port,
        username,
        password,
        ssh_gateway_id,
        page_gateway,
    );
    anyhow::bail!("VNC 会话进程已关闭");
}

pub async fn vnc_connect(
    host: String,
    port: u16,
    username: String,
    password: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    crate::vnc::connect(host, port, username, password, ssh_gateway_id, page_gateway).await
}

#[cfg_attr(any(windows, test), derive(serde::Serialize, serde::Deserialize))]
pub struct VncInputEvent {
    pub pointer: bool,
    pub code: u32,
    pub flags: u16,
    pub x: u16,
    pub y: u16,
}

#[frb(stream_dart_await)]
pub async fn vnc_frame(
    session_id: u32,
    after_sequence: u32,
    sink: StreamSink<Option<DesktopFrame>, DcoCodec>,
) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        let _ = sink.add(worker.vnc_frame(session_id, after_sequence).await?);
        return Ok(());
    }
    let frame = match crate::vnc::frame(session_id, after_sequence).await? {
        None => None,
        Some(frame) => {
            #[cfg(any(windows, target_os = "macos", target_os = "linux"))]
            let presented = crate::desktop_texture::present(session_id, frame).await;
            #[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
            let presented: std::result::Result<DesktopFrame, ()> = Ok(frame);
            match presented {
                Ok(frame) => Some(frame),
                Err(()) => crate::vnc::frame(session_id, 0).await?,
            }
        }
    };
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

/// Send ordered VNC keyboard and pointer events in one batched call.
pub async fn vnc_input_batch(session_id: u32, events: Vec<VncInputEvent>) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.vnc_input_batch(events).await;
    }
    crate::vnc::input_batch(session_id, events).await
}

/// Returns the latest VNC network latency, speed, packet loss, and adaptive quality snapshot.
pub async fn vnc_network_stats(session_id: u32) -> Result<DesktopNetworkStats> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.network_stats().await;
    }
    crate::vnc::network_stats(session_id).await
}

/// Selects the VNC adaptive quality policy: 0 = Auto, 1 = High, 2 = Balanced, 3 = Low.
pub async fn vnc_set_quality_mode(session_id: u32, mode: u8) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.set_quality_mode(mode).await;
    }
    crate::vnc::set_quality_mode(session_id, mode).await
}

/// Requests a VNC ExtendedDesktopSize resize. False means the server does not support it.
pub async fn vnc_resize(session_id: u32, width: u16, height: u16) -> Result<bool> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.resize(width, height).await;
    }
    crate::vnc::resize(session_id, width, height).await
}

pub async fn vnc_clipboard_active(session_id: u32, active: bool) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.clipboard_active(active, String::new()).await;
    }
    crate::vnc::clipboard_active(session_id, active).await
}

pub async fn vnc_clipboard_update(session_id: u32, text: Option<String>) -> Result<()> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.clipboard_update(text, Vec::new()).await;
    }
    crate::vnc::clipboard_update(session_id, text).await
}

pub async fn vnc_clipboard_event(
    session_id: u32,
    after_sequence: u32,
) -> Result<Option<DesktopClipboardEvent>> {
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::get_vnc(session_id).await {
        return worker.clipboard_event(after_sequence).await;
    }
    crate::vnc::clipboard_event(session_id, after_sequence).await
}

pub async fn vnc_disconnect(session_id: u32) -> Result<()> {
    #[cfg(any(windows, target_os = "macos", target_os = "linux"))]
    crate::desktop_texture::pagashell_rdp_texture_detach(session_id);
    #[cfg(windows)]
    if let Some(worker) = crate::desktop_worker::remove_vnc(session_id).await {
        worker.close().await;
        return Ok(());
    }
    crate::vnc::disconnect(session_id).await;
    Ok(())
}
