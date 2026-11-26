use std::collections::VecDeque;
use std::time::Duration;

use ironrdp::dvc::{encode_dvc_messages, DvcMessage, DvcMessageBatch};
use ironrdp::svc::ChannelFlags;
use ironrdp_egfx::pdu::{FrameAcknowledgePdu, GfxPdu};
use tokio::time::Instant;

// Let the viewer pace delivery, while making progress on a hidden tab, a static
// desktop and a server that pauses sending until it receives an ACK.
const ACK_LIMIT: usize = 8;
const ACK_WAIT: Duration = Duration::from_millis(24);

#[derive(Default)]
pub(crate) struct FrameFlow {
    queue: VecDeque<(FrameAcknowledgePdu, Instant)>,
    channel: Option<u32>,
    delivered: Option<(u32, usize)>,
    consumed: usize,
}

impl FrameFlow {
    pub fn enqueue(&mut self, channel: u32, acks: Vec<FrameAcknowledgePdu>, now: Instant) {
        if acks.is_empty() {
            return;
        }
        debug_assert!(self.queue.is_empty() || self.channel == Some(channel));
        self.channel = Some(channel);
        self.queue
            .extend(acks.into_iter().map(|ack| (ack, now + ACK_WAIT)));
    }

    pub fn delivered(&mut self, sequence: u32) {
        self.delivered = Some((sequence, self.queue.len()));
    }

    pub fn consume(&mut self, after: u32) {
        if let Some((sequence, count)) = self.delivered {
            if after == sequence {
                self.consumed = count;
                self.delivered = None;
            }
        }
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.queue.front().map(|(_, deadline)| *deadline)
    }

    pub fn take_ready(
        &mut self,
        now: Instant,
        flush: bool,
    ) -> anyhow::Result<Option<DvcMessageBatch>> {
        let len = if flush || self.queue.len() >= ACK_LIMIT {
            self.queue.len()
        } else {
            self.consumed.max(
                self.queue
                    .iter()
                    .take_while(|(_, expires)| *expires <= now)
                    .count(),
            )
        };
        if len == 0 {
            return Ok(None);
        }
        self.consumed = self.consumed.saturating_sub(len);
        if let Some((_, count)) = self.delivered.as_mut() {
            *count = count.saturating_sub(len);
        }
        let messages = self
            .queue
            .drain(..len)
            .map(|(ack, _)| Box::new(GfxPdu::FrameAcknowledge(ack)) as DvcMessage)
            .collect();
        let channel = self.channel.expect("a queued ACK always has a channel");
        let messages = encode_dvc_messages(channel, messages, ChannelFlags::empty())?;
        Ok(Some(DvcMessageBatch::try_new(channel, messages)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_egfx::pdu::QueueDepth;

    fn ack(id: u32) -> FrameAcknowledgePdu {
        FrameAcknowledgePdu {
            queue_depth: QueueDepth::AvailableBytes(31),
            frame_id: id,
            total_frames_decoded: id,
        }
    }

    #[test]
    fn presentation_releases_only_its_ack_prefix_without_changing_byte_depth() {
        let now = Instant::now();
        let mut flow = FrameFlow::default();
        flow.enqueue(7, vec![ack(1), ack(2)], now);
        flow.delivered(20);
        flow.enqueue(7, vec![ack(3)], now);
        flow.consume(19);
        assert!(flow.take_ready(now, false).unwrap().is_none());
        flow.consume(20);
        let batch = flow.take_ready(now, false).unwrap().unwrap();
        assert_eq!(batch.channel_id(), 7);
        assert_eq!(
            flow.queue
                .iter()
                .map(|(a, _)| a.frame_id)
                .collect::<Vec<_>>(),
            [3]
        );
        assert_eq!(flow.queue[0].0.queue_depth, QueueDepth::AvailableBytes(31));
        assert!(flow.take_ready(now, false).unwrap().is_none());
        assert!(flow.take_ready(now + ACK_WAIT, false).unwrap().is_some());
        assert!(flow.queue.is_empty());
    }

    #[test]
    fn hidden_view_and_large_batches_release_acks_within_bounds() {
        let now = Instant::now();
        let mut flow = FrameFlow::default();
        flow.enqueue(7, (1..=ACK_LIMIT as u32).map(ack).collect(), now);
        assert!(flow.take_ready(now, false).unwrap().is_some());
        flow.enqueue(7, vec![ack(9)], now);
        flow.delivered(42);
        assert!(flow.take_ready(now + ACK_WAIT, false).unwrap().is_some());
        flow.enqueue(7, vec![ack(10)], now + ACK_WAIT);
        flow.consume(42);
        assert!(flow.take_ready(now + ACK_WAIT, false).unwrap().is_none());
        assert!(flow.take_ready(now + ACK_WAIT, true).unwrap().is_some());
    }
}
