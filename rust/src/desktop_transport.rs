use std::io;

use anyhow::{anyhow, Result};
use ironrdp::connector::{MonotonicInstant, Sequence, Written};
use ironrdp::core::WriteBuf;
use ironrdp::pdu::Action;
use ironrdp_tokio::TokioFramed;
use tokio::io::AsyncRead;
use tokio::sync::mpsc;

pub(crate) struct Packet {
    pub action: Action,
    pub bytes: bytes::BytesMut,
    pub received_at: Option<MonotonicInstant>,
}

pub(crate) struct PacketReader(mpsc::Receiver<io::Result<Packet>>);

impl PacketReader {
    /// TLS reads and input writes can progress while a graphics packet
    /// decodes. The small queue bounds read-ahead and hands off the original
    /// bytes without copying them.
    pub fn spawn<S>(mut reader: TokioFramed<S>) -> Self
    where
        S: Send + Sync + Unpin + AsyncRead + 'static,
    {
        let (send, receive) = mpsc::channel(8);
        tokio::spawn(async move {
            while let Ok(slot) = send.reserve().await {
                let read = tokio::select! {
                    _ = send.closed() => break,
                    packet = reader.read_pdu() => packet,
                };
                let failed = read.is_err();
                slot.send(read.map(|(action, bytes)| Packet {
                    action,
                    bytes,
                    received_at: reader.last_read_at(),
                }));
                if failed {
                    break;
                }
            }
        });
        Self(receive)
    }

    pub async fn read(&mut self) -> io::Result<Packet> {
        self.0
            .recv()
            .await
            .unwrap_or_else(|| Err(io::ErrorKind::UnexpectedEof.into()))
    }

    /// The reactivation sequence expects X.224 frames (or no input).
    /// Discard intervening Fast-Path updates just as X224_HINT did when TLS
    /// framing and protocol processing lived on the same task.
    pub async fn activation_step(
        &mut self,
        activation: &mut impl Sequence,
        output: &mut WriteBuf,
    ) -> Result<Written> {
        output.clear();
        if activation.next_pdu_hint().is_none() {
            return Ok(activation.step_no_input(output)?);
        }
        loop {
            let packet = self.read().await?;
            if packet.action != Action::X224 {
                continue;
            }
            let hint = activation
                .next_pdu_hint()
                .ok_or_else(|| anyhow!("RDP reactivation lost its input state"))?;
            if hint
                .find_size(&packet.bytes)?
                .is_some_and(|(matches, len)| matches && len == packet.bytes.len())
            {
                return Ok(activation.step(&packet.bytes, packet.received_at, output)?);
            }
        }
    }
}
