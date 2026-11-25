use std::io::{self, Write};

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::api::desktop::{
    DesktopClipboardEvent, DesktopFrame, DesktopHandshake, DesktopInputEvent,
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
pub(super) enum Request {
    Prepare {
        version: u32,
        host: String,
        port: u16,
    },
    Authenticate {
        fingerprint: String,
        username: String,
        password: String,
        domain: String,
    },
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
    InputBatch(Vec<DesktopInputEvent>),
    Resize {
        width: u16,
        height: u16,
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
    NeedFrameSpace(u32),
    Resize(bool),
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
        assert_eq!(VERSION, 1);
    }
}
