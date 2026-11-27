use std::io::{self, Write};

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::api::desktop::{
    DesktopClipboardEvent, DesktopFrame, DesktopHandshake, DesktopInputEvent, DesktopNetworkStats,
};

pub(super) const VERSION: u32 = 1;
pub(super) const MAX_IN_FLIGHT: usize = 16;
#[cfg(windows)]
pub(super) const MAX_FRAME_BYTES: usize = 128 * 1024 * 1024;
// Clipboard text can be 16 MiB; JSON control-character escaping can expand it
// by six. Desktop pixels are never encoded into a pipe message.
const MAX_RECORD: usize = 98 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
pub(super) struct Packet<T> {
    pub id: u32,
    pub body: T,
}

#[derive(Serialize, Deserialize)]
pub(super) struct MapOffer {
    pub handle: u64,
    pub capacity: u32,
}

#[derive(Serialize, Deserialize)]
pub(super) struct GpuSurfaceOffer {
    pub handle: u64,
    pub generation: u64,
}

#[derive(Serialize, Deserialize)]
pub(super) enum Request {
    Prepare {
        version: u32,
        host: String,
        port: u16,
    },
    PreparePage {
        version: u32,
        host: String,
        port: u16,
        gateway: crate::api::page::PageGateway,
    },
    PrepareTunnel {
        version: u32,
        host: String,
        tunnel_handle: u64,
    },
    VncConnect {
        version: u32,
        host: String,
        port: u16,
        password: String,
        page_gateway: Option<crate::api::page::PageGateway>,
    },
    VncConnectTunnel {
        version: u32,
        password: String,
        tunnel_handle: u64,
    },
    Authenticate {
        fingerprint: String,
        username: String,
        password: String,
        domain: String,
        #[serde(default)]
        preferences: crate::rdp::ClientPreferences,
        #[serde(default)]
        gpu_adapter_luid: Option<u64>,
    },
    DisableGpu,
    Frame {
        after: u32,
        mapping: Option<MapOffer>,
    },
    Input {
        kind: u8,
        code: u16,
        flags: u16,
        x: u16,
        y: u16,
        text: String,
    },
    VncInput {
        kind: u8,
        code: u32,
        flags: u16,
        x: u16,
        y: u16,
        text: String,
    },
    InputBatch(Vec<DesktopInputEvent>),
    Resize {
        width: u16,
        height: u16,
    },
    NetworkStats,
    SetQualityMode {
        mode: u8,
    },
    ClipboardActive {
        active: bool,
        directory: String,
    },
    ClipboardUpdate {
        text: Option<String>,
        files: Vec<String>,
    },
    ClipboardEvent {
        after: u32,
    },
    ClipboardCancel,
    Probe,
    Close,
}

#[derive(Serialize, Deserialize)]
pub(super) enum Reply {
    Done,
    Handshake(DesktopHandshake),
    Frame(Option<DesktopFrame>),
    GpuFrame {
        frame: DesktopFrame,
        surface: GpuSurfaceOffer,
    },
    NeedFrameSpace(u32),
    Resize(bool),
    NetworkStats(DesktopNetworkStats),
    Clipboard(Option<DesktopClipboardEvent>),
    Error(String),
}

fn invalid() -> io::Error {
    // Original parser errors may include protocol data, including credentials.
    io::Error::new(io::ErrorKind::InvalidData, "invalid desktop worker message")
}

pub(super) async fn read<T: DeserializeOwned>(
    source: &mut (impl AsyncRead + Unpin),
) -> io::Result<Packet<T>> {
    let len = source.read_u32_le().await? as usize;
    if len == 0 || len > MAX_RECORD {
        return Err(invalid());
    }
    let mut bytes = vec![0; len];
    source.read_exact(&mut bytes).await?;
    serde_json::from_slice(&bytes).map_err(|_| invalid())
}

pub(super) async fn write<T: Serialize>(
    target: &mut (impl AsyncWrite + Unpin),
    message: Packet<T>,
) -> io::Result<()> {
    // Release strings such as passwords before waiting for the pipe to drain.
    let mut bytes = BoundedRecord(Vec::new());
    serde_json::to_writer(&mut bytes, &message).map_err(|_| invalid())?;
    drop(message);
    target.write_u32_le(bytes.0.len() as u32).await?;
    target.write_all(&bytes.0).await?;
    target.flush().await
}

struct BoundedRecord(Vec<u8>);

impl Write for BoundedRecord {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.len() > MAX_RECORD - self.0.len() {
            return Err(invalid());
        }
        self.0.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_oversized_records_before_waiting_for_the_body() {
        let (mut writer, mut reader) = tokio::io::duplex(4);
        writer.write_u32_le(MAX_RECORD as u32 + 1).await.unwrap();
        let result = read::<Request>(&mut reader).await;
        assert!(matches!(result, Err(error) if error.kind() == io::ErrorKind::InvalidData));
    }

    #[tokio::test]
    async fn frame_records_keep_sequence_and_size_without_large_pixel_data() {
        let (mut writer, mut reader) = tokio::io::duplex(512);
        write(
            &mut writer,
            Packet {
                id: 42,
                body: Reply::Frame(Some(DesktopFrame {
                    sequence: 2,
                    width: 1280,
                    height: 800,
                    bitmap_width: 1280,
                    bitmap_height: 800,
                    rgba: vec![32; 1280 * 800 * 4],
                    tiles: vec![],
                    cursor: None,
                    texture_id: Some(99),
                })),
            },
        )
        .await
        .unwrap();
        let packet = read::<Reply>(&mut reader).await.unwrap();
        let Reply::Frame(Some(frame)) = packet.body else {
            panic!("expected frame record")
        };
        assert_eq!((packet.id, frame.sequence, frame.width), (42, 2, 1280));
        assert!(frame.rgba.is_empty());
        assert!(frame.texture_id.is_none());
        assert_eq!(VERSION, 1);
    }

    #[tokio::test]
    async fn gateway_rdp_and_vnc_requests_round_trip_over_pipe() {
        let (mut writer, mut reader) = tokio::io::duplex(4096);
        let gateway = crate::api::page::PageGateway {
            server_host: "page.example.com".into(),
            server_port: 443,
            client_id: "client-1".into(),
            token: "tok".into(),
            server_fingerprint: "SHA256:AA".into(),
        };
        let requests = [
            Request::PreparePage {
                version: VERSION,
                host: "rdp.internal".into(),
                port: 3389,
                gateway: gateway.clone(),
            },
            Request::PrepareTunnel {
                version: VERSION,
                host: "rdp.internal".into(),
                tunnel_handle: 0x1234,
            },
            Request::VncConnect {
                version: VERSION,
                host: "vnc.internal".into(),
                port: 5900,
                password: "pw".into(),
                page_gateway: Some(gateway),
            },
            Request::VncConnectTunnel {
                version: VERSION,
                password: "pw".into(),
                tunnel_handle: 0x5678,
            },
            Request::VncInput {
                kind: 0,
                code: 0x0100_4e2d,
                flags: 0,
                x: 0,
                y: 0,
                text: String::new(),
            },
        ];
        for (index, body) in requests.into_iter().enumerate() {
            write(
                &mut writer,
                Packet {
                    id: index as u32 + 1,
                    body,
                },
            )
            .await
            .unwrap();
        }
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::PreparePage { port: 3389, .. }
        ));
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::PrepareTunnel {
                tunnel_handle: 0x1234,
                ..
            }
        ));
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::VncConnect {
                port: 5900,
                page_gateway: Some(_),
                ..
            }
        ));
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::VncConnectTunnel {
                tunnel_handle: 0x5678,
                ..
            }
        ));
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::VncInput {
                code: 0x0100_4e2d,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn gpu_frame_and_disable_gpu_round_trip_over_pipe() {
        let (mut writer, mut reader) = tokio::io::duplex(2048);
        write(
            &mut writer,
            Packet {
                id: 7,
                body: Request::DisableGpu,
            },
        )
        .await
        .unwrap();
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::DisableGpu
        ));

        write(
            &mut writer,
            Packet {
                id: 8,
                body: Reply::GpuFrame {
                    frame: DesktopFrame {
                        sequence: 5,
                        width: 1920,
                        height: 1080,
                        bitmap_width: 0,
                        bitmap_height: 0,
                        rgba: Vec::new(),
                        tiles: Vec::new(),
                        cursor: None,
                        texture_id: None,
                    },
                    surface: GpuSurfaceOffer {
                        handle: 0xDEAD_BEEF,
                        generation: 3,
                    },
                },
            },
        )
        .await
        .unwrap();
        let Reply::GpuFrame { frame, surface } = read::<Reply>(&mut reader).await.unwrap().body
        else {
            panic!("expected GpuFrame reply");
        };
        assert_eq!((frame.sequence, frame.width, frame.height), (5, 1920, 1080));
        assert_eq!((surface.handle, surface.generation), (0xDEAD_BEEF, 3));
    }

    #[tokio::test]
    async fn network_stats_and_quality_mode_round_trip_over_pipe() {
        let (mut writer, mut reader) = tokio::io::duplex(2048);
        write(
            &mut writer,
            Packet {
                id: 11,
                body: Request::NetworkStats,
            },
        )
        .await
        .unwrap();
        write(
            &mut writer,
            Packet {
                id: 12,
                body: Request::SetQualityMode { mode: 2 },
            },
        )
        .await
        .unwrap();
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::NetworkStats
        ));
        assert!(matches!(
            read::<Request>(&mut reader).await.unwrap().body,
            Request::SetQualityMode { mode: 2 }
        ));

        let expected = DesktopNetworkStats {
            rtt_ms: Some(42),
            throughput_kbps: 2400,
            bandwidth_kbps: Some(12000),
            packet_loss_permille: Some(5),
            fps: 58,
            signal_level: 4,
            quality_tier: 1,
            quality_mode: 0,
            transport_kind: 1,
        };
        write(
            &mut writer,
            Packet {
                id: 11,
                body: Reply::NetworkStats(expected),
            },
        )
        .await
        .unwrap();
        let Reply::NetworkStats(actual) = read::<Reply>(&mut reader).await.unwrap().body else {
            panic!("expected NetworkStats reply");
        };
        assert_eq!(actual, expected);
    }
}
