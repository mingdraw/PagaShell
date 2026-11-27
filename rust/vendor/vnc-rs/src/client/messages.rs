use crate::{PixelFormat, Rect, VncEncoding, VncError};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[derive(Debug)]
pub(super) enum ClientMsg {
    SetPixelFormat(PixelFormat),
    SetEncodings(Vec<VncEncoding>),
    FramebufferUpdateRequest(Rect, u8),
    KeyEvent(u32, bool),
    PointerEvent(u16, u16, u8),
    ClientCutText(String),
    #[cfg(not(target_arch = "wasm32"))]
    SetDesktopSize(crate::DesktopLayout),
}

impl ClientMsg {
    pub(super) fn encode_into(self, payload: &mut Vec<u8>) -> Result<(), VncError> {
        match self {
            ClientMsg::SetPixelFormat(pf) => {
                payload.extend_from_slice(&[0_u8, 0, 0, 0]);
                payload.extend(<PixelFormat as Into<Vec<u8>>>::into(pf));
                Ok(())
            }
            ClientMsg::SetEncodings(encodings) => {
                payload.extend_from_slice(&[2, 0]);
                payload.extend_from_slice(&(encodings.len() as u16).to_be_bytes());
                for e in encodings {
                    payload.extend_from_slice(&u32::from(e).to_be_bytes());
                }
                Ok(())
            }
            ClientMsg::FramebufferUpdateRequest(rect, incremental) => {
                payload.extend_from_slice(&[3, incremental]);
                payload.extend_from_slice(&rect.x.to_be_bytes());
                payload.extend_from_slice(&rect.y.to_be_bytes());
                payload.extend_from_slice(&rect.width.to_be_bytes());
                payload.extend_from_slice(&rect.height.to_be_bytes());
                Ok(())
            }
            ClientMsg::KeyEvent(keycode, down) => {
                payload.extend_from_slice(&[4, down as u8, 0, 0]);
                payload.extend_from_slice(&keycode.to_be_bytes());
                Ok(())
            }
            ClientMsg::PointerEvent(x, y, mask) => {
                payload.extend_from_slice(&[5, mask]);
                payload.extend_from_slice(&x.to_be_bytes());
                payload.extend_from_slice(&y.to_be_bytes());
                Ok(())
            }
            #[cfg(not(target_arch = "wasm32"))]
            ClientMsg::SetDesktopSize(layout) => {
                layout.validate()?;
                payload.extend_from_slice(&[251, 0]);
                payload.extend_from_slice(&layout.width.to_be_bytes());
                payload.extend_from_slice(&layout.height.to_be_bytes());
                payload.extend_from_slice(&[layout.screens.len() as u8, 0]);
                for screen in layout.screens {
                    payload.extend_from_slice(&screen.id.to_be_bytes());
                    payload.extend_from_slice(&screen.x.to_be_bytes());
                    payload.extend_from_slice(&screen.y.to_be_bytes());
                    payload.extend_from_slice(&screen.width.to_be_bytes());
                    payload.extend_from_slice(&screen.height.to_be_bytes());
                    payload.extend_from_slice(&screen.flags.to_be_bytes());
                }
                // Some servers release resize confirmations only with an outstanding
                // update request. Keep it ordered with the resize and bounded to one pixel.
                payload.extend_from_slice(&[3, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
                Ok(())
            }
            ClientMsg::ClientCutText(s) => {
                payload.extend_from_slice(&[6_u8, 0, 0, 0]);
                payload.extend_from_slice(&(s.len() as u32).to_be_bytes());
                payload.extend_from_slice(s.as_bytes());
                Ok(())
            }
        }
    }

    pub(super) async fn write<S>(self, writer: &mut S) -> Result<(), VncError>
    where
        S: AsyncWrite + Unpin,
    {
        let mut payload = Vec::with_capacity(64);
        self.encode_into(&mut payload)?;
        writer.write_all(&payload).await?;
        writer.flush().await?;
        Ok(())
    }
}

#[derive(Debug)]
pub(super) enum ServerMsg {
    FramebufferUpdate(u16),
    SetColorMapEntries,
    Bell,
    ServerCutText(String),
}

impl ServerMsg {
    pub(super) async fn read<S>(reader: &mut S) -> Result<Self, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let server_msg = reader.read_u8().await?;

        match server_msg {
            0 => {
                // FramebufferUpdate
                //   +--------------+--------------+----------------------+
                //   | No. of bytes | Type [Value] | Description          |
                //   +--------------+--------------+----------------------+
                //   | 1            | U8 [0]       | message-type         |
                //   | 1            |              | padding              |
                //   | 2            | U16          | number-of-rectangles |
                //   +--------------+--------------+----------------------+
                let _padding = reader.read_u8().await?;
                let rects = reader.read_u16().await?;
                Ok(ServerMsg::FramebufferUpdate(rects))
            }
            1 => {
                // SetColorMapEntries
                // +--------------+--------------+------------------+
                // | No. of bytes | Type [Value] | Description      |
                // +--------------+--------------+------------------+
                // | 1            | U8 [1]       | message-type     |
                // | 1            |              | padding          |
                // | 2            | U16          | first-color      |
                // | 2            | U16          | number-of-colors |
                // +--------------+--------------+------------------+
                let _padding = reader.read_u8().await?;
                let _first_color = reader.read_u16().await?;
                let num_colors = usize::from(reader.read_u16().await?);
                let mut remaining = num_colors * 6;
                let mut scratch = [0u8; 384];
                while remaining > 0 {
                    let take = remaining.min(scratch.len());
                    reader.read_exact(&mut scratch[..take]).await?;
                    remaining -= take;
                }
                Ok(ServerMsg::SetColorMapEntries)
            }
            2 => {
                // Bell
                //   +--------------+--------------+--------------+
                //   | No. of bytes | Type [Value] | Description  |
                //   +--------------+--------------+--------------+
                //   | 1            | U8 [2]       | message-type |
                //   +--------------+--------------+--------------+
                Ok(ServerMsg::Bell)
            }
            3 => {
                // ServerCutText
                // +--------------+--------------+--------------+
                // | No. of bytes | Type [Value] | Description  |
                // +--------------+--------------+--------------+
                // | 1            | U8 [3]       | message-type |
                // | 3            |              | padding      |
                // | 4            | U32          | length       |
                // | length       | U8 array     | text         |
                // +--------------+--------------+--------------+
                let mut padding = [0; 3];
                reader.read_exact(&mut padding).await?;
                Ok(Self::ServerCutText(
                    crate::limits::string(reader, crate::limits::MAX_TEXT).await?,
                ))
            }
            _ => Err(VncError::WrongServerMessage),
        }
    }
}
