use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use ironrdp::displaycontrol::client::DisplayControlClient;
use ironrdp::session::ActiveStage;
use tokio::sync::oneshot;

pub(crate) struct ResizeRequest {
    pub width: u16,
    pub height: u16,
    pub reply: oneshot::Sender<Result<bool>>,
}

#[derive(Default)]
pub(crate) struct DisplayControl {
    max_area: Arc<AtomicU64>,
}

impl DisplayControl {
    pub fn client(&self) -> DisplayControlClient {
        let max_area = self.max_area.clone();
        DisplayControlClient::new(move |caps| {
            max_area.store(caps.max_monitor_area(), Ordering::Relaxed);
            Ok(Vec::new())
        })
    }

    pub fn validate_size(width: u16, height: u16) -> Result<()> {
        if !(200..=8192).contains(&width)
            || !(200..=8192).contains(&height)
            || !width.is_multiple_of(2)
        {
            bail!("无效的 RDP 分辨率");
        }
        crate::rdp::validate_desktop_size(width, height)
    }

    fn validate_server_limit(&self, width: u16, height: u16) -> Result<()> {
        Self::validate_size(width, height)?;
        if u64::from(width) * u64::from(height) > self.max_area.load(Ordering::Relaxed) {
            bail!("远端不支持所选分辨率，请选择较小的尺寸");
        }
        Ok(())
    }

    /// None means the server's display channel is not ready yet.
    pub fn encode_resize(
        &self,
        stage: &mut ActiveStage,
        width: u16,
        height: u16,
    ) -> Option<Result<Vec<u8>>> {
        if stage.display_control_ready() != Some(true) {
            return None;
        }
        if let Err(error) = self.validate_server_limit(width, height) {
            return Some(Err(error));
        }
        stage
            .encode_resize(u32::from(width), u32::from(height), None, None)
            .map(|result| result.context("RDP 分辨率请求编码失败"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::encode_vec;
    use ironrdp::displaycontrol::pdu::{DisplayControlCapabilities, DisplayControlPdu};
    use ironrdp::dvc::DvcProcessor;

    #[test]
    fn resize_waits_for_server_capabilities_and_enforces_both_pixel_budgets() {
        let display = DisplayControl::default();
        let mut client = display.client();
        assert!(!client.ready());
        assert!(display.validate_server_limit(1920, 1080).is_err());
        let caps = DisplayControlPdu::Caps(DisplayControlCapabilities::new(1, 1920, 1080).unwrap());
        assert!(client
            .process(7, &encode_vec(&caps).unwrap())
            .unwrap()
            .is_empty());
        assert!(client.ready());
        assert!(display.validate_server_limit(1920, 1080).is_ok());
        assert!(display.validate_server_limit(2560, 1440).is_err());
        assert!(!client
            .encode_single_primary_monitor(7, 1920, 1080, None, None)
            .unwrap()
            .is_empty());
        for (width, height) in [
            (0, 800),
            (1281, 800),
            (8194, 200),
            (200, 8193),
            (8192, 8192),
        ] {
            assert!(DisplayControl::validate_size(width, height).is_err());
        }
        assert!(DisplayControl::validate_size(3840, 2160).is_ok());
    }
}
