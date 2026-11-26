//! The native transform is optional. On stream loss retain SPS/PPS and switch
//! to OpenH264 on a new IDR, never mispairing an AVC444 chroma update.
use ironrdp_egfx::decode::{
    DecodedFrame, DecoderError, DecoderResult, H264Decoder, OpenH264Decoder, Yuv420Frame,
};
use ironrdp_egfx::gpu::HwVideoFrame;
use ironrdp_egfx::pdu::{annex_b_units, avc_to_annex_b_into, is_avc_format};

type OpenNative = Box<dyn Fn() -> DecoderResult<Box<dyn H264Decoder>> + Send>;

pub(crate) struct NativeFallback {
    software: OpenH264Decoder,
    open_native: Option<OpenNative>,
    native: Option<Box<dyn H264Decoder>>,
    native_needs_parameters: bool,
    waiting_for_idr: bool,
    parameters: [Vec<u8>; 2],
    annex_b: Vec<u8>,
    recovery: Vec<u8>,
}

impl NativeFallback {
    pub fn new(
        software: OpenH264Decoder,
        open_native: impl Fn() -> DecoderResult<Box<dyn H264Decoder>> + Send + 'static,
    ) -> Self {
        Self {
            software,
            open_native: Some(Box::new(open_native)),
            native: None,
            native_needs_parameters: true,
            waiting_for_idr: false,
            parameters: Default::default(),
            annex_b: Vec::new(),
            recovery: Vec::new(),
        }
    }

    fn decode_with<T>(
        &mut self,
        data: &[u8],
        mut decode: impl FnMut(&mut dyn H264Decoder, &[u8]) -> DecoderResult<T>,
    ) -> DecoderResult<T> {
        if self.open_native.is_none() && self.native.is_none() && !self.waiting_for_idr {
            return decode(&mut self.software, data);
        }
        let data = if is_avc_format(data) {
            avc_to_annex_b_into(data, &mut self.annex_b);
            &self.annex_b
        } else {
            data
        };
        let mut idr = false;
        let mut picture = false;
        for nal in annex_b_units(data) {
            let kind = nal[0] & 31;
            picture |= (1..=5).contains(&kind);
            idr |= kind == 5;
            if matches!(kind, 7 | 8) && nal.len() <= 16 * 1024 {
                let bytes = &mut self.parameters[usize::from(kind - 7)];
                bytes.clear();
                bytes.extend_from_slice(&[0, 0, 0, 1]);
                bytes.extend_from_slice(nal);
            }
        }

        if picture {
            if let Some(open) = self.open_native.take() {
                if idr {
                    self.native = open().ok();
                    self.waiting_for_idr = self.native.is_none();
                }
            }
            if let Some(native) = self.native.as_mut() {
                let sample = if self.native_needs_parameters {
                    self.recovery.clear();
                    self.recovery.extend_from_slice(&self.parameters[0]);
                    self.recovery.extend_from_slice(&self.parameters[1]);
                    self.recovery.extend_from_slice(data);
                    self.native_needs_parameters = false;
                    &self.recovery
                } else {
                    data
                };
                match decode(native.as_mut(), sample) {
                    Ok(frame) => return Ok(frame),
                    Err(_) => {
                        tracing::debug!("Native RDP H.264 failed; waiting for a software keyframe");
                        self.native = None;
                        self.software.reset();
                        self.waiting_for_idr = true;
                    }
                }
            }
        } else if self.native.is_some() || self.open_native.is_some() {
            return Err(DecoderError::msg("H.264 access unit contains no picture"));
        }

        if self.waiting_for_idr {
            if !idr {
                return Err(DecoderError::msg("waiting for an H.264 keyframe"));
            }
            self.recovery.clear();
            self.recovery.extend_from_slice(&self.parameters[0]);
            self.recovery.extend_from_slice(&self.parameters[1]);
            self.recovery.extend_from_slice(data);
            let result = decode(&mut self.software, &self.recovery);
            if result.is_ok() {
                self.waiting_for_idr = false;
                self.recovery = Vec::new();
                self.annex_b = Vec::new();
                self.parameters = Default::default();
            }
            return result;
        }
        decode(&mut self.software, data)
    }
}

impl H264Decoder for NativeFallback {
    fn supports_yuv420(&self) -> bool {
        true
    }

    fn supports_hw_frame(&self) -> bool {
        self.open_native.is_some()
            || self
                .native
                .as_ref()
                .is_some_and(|native| native.supports_hw_frame())
    }

    fn decode_hw(&mut self, data: &[u8]) -> DecoderResult<Option<Box<dyn HwVideoFrame>>> {
        if self.open_native.is_none() && self.native.is_none() {
            return Ok(None);
        }
        let data = if is_avc_format(data) {
            avc_to_annex_b_into(data, &mut self.annex_b);
            &self.annex_b
        } else {
            data
        };
        let mut idr = false;
        let mut picture = false;
        for nal in annex_b_units(data) {
            let kind = nal[0] & 31;
            picture |= (1..=5).contains(&kind);
            idr |= kind == 5;
            if matches!(kind, 7 | 8) && nal.len() <= 16 * 1024 {
                let bytes = &mut self.parameters[usize::from(kind - 7)];
                bytes.clear();
                bytes.extend_from_slice(&[0, 0, 0, 1]);
                bytes.extend_from_slice(nal);
            }
        }
        if !picture {
            return Err(DecoderError::msg("H.264 access unit contains no picture"));
        }
        if let Some(open) = self.open_native.take() {
            if idr {
                self.native = open().ok();
                self.waiting_for_idr = self.native.is_none();
            } else {
                self.open_native = Some(open);
                return Ok(None);
            }
        }
        let Some(native) = self.native.as_mut() else {
            return Ok(None);
        };
        if !native.supports_hw_frame() {
            return Ok(None);
        }
        let sample = if self.native_needs_parameters {
            self.recovery.clear();
            self.recovery.extend_from_slice(&self.parameters[0]);
            self.recovery.extend_from_slice(&self.parameters[1]);
            self.recovery.extend_from_slice(data);
            self.native_needs_parameters = false;
            &self.recovery
        } else {
            data
        };
        match native.decode_hw(sample) {
            Ok(Some(frame)) => Ok(Some(frame)),
            Ok(None) => Ok(None),
            Err(_) => {
                tracing::debug!("Native GPU RDP H.264 failed; switching to software fallback");
                self.native = None;
                self.software.reset();
                self.waiting_for_idr = true;
                // Returning Ok(None) lets the caller immediately try software decoding
                // on the same sample (which succeeds immediately when it is an IDR).
                Ok(None)
            }
        }
    }

    fn decode(&mut self, data: &[u8]) -> DecoderResult<DecodedFrame> {
        self.decode_with(data, |decoder, bytes| decoder.decode(bytes))
    }

    fn decode_yuv420(&mut self, data: &[u8]) -> DecoderResult<Yuv420Frame> {
        self.decode_with(data, |decoder, bytes| decoder.decode_yuv420(bytes))
    }

    fn decode_avc420(&mut self, data: &[u8], rgba: &mut Vec<u8>) -> DecoderResult<(u32, u32)> {
        self.decode_with(data, |decoder, bytes| decoder.decode_avc420(bytes, rgba))
    }

    fn reset(&mut self) {
        self.waiting_for_idr = false;
        self.native_needs_parameters = true;
        self.parameters.iter_mut().for_each(Vec::clear);
        self.software.reset();
        if let Some(native) = self.native.as_mut() {
            native.reset();
        }
    }
}

#[cfg(windows)]
pub(crate) fn open_native() -> DecoderResult<Box<dyn H264Decoder>> {
    use ironrdp_egfx_native::{MediaFoundationH264Decoder, YuvMatrix};
    Ok(Box::new(MediaFoundationH264Decoder::new(
        YuvMatrix::Bt709Full,
    )?))
}

#[cfg(target_os = "macos")]
pub(crate) fn open_native() -> DecoderResult<Box<dyn H264Decoder>> {
    Ok(Box::new(
        ironrdp_egfx_native::VideoToolboxH264Decoder::new()?
    ))
}

#[cfg(target_os = "linux")]
pub(crate) fn open_native() -> DecoderResult<Box<dyn H264Decoder>> {
    ironrdp_egfx_native::open_vaapi()
}

#[cfg(test)]
mod tests {
    use super::*;
    use openh264::{encoder::Encoder, formats::YUVBuffer};

    fn synthetic_picture() -> Vec<u8> {
        let picture = YUVBuffer::from_vec(
            [
                vec![118; 128 * 96],
                vec![99; 128 * 96 / 4],
                vec![202; 128 * 96 / 4],
            ]
            .concat(),
            128,
            96,
        );
        Encoder::new().unwrap().encode(&picture).unwrap().to_vec()
    }

    #[test]
    fn failed_native_decode_falls_back_with_captured_parameter_sets() {
        let bytes = synthetic_picture();
        let mut bootstrap = Vec::new();
        let mut sample = Vec::new();
        for nal in annex_b_units(&bytes) {
            let target = if matches!(nal[0] & 31, 7 | 8) {
                &mut bootstrap
            } else {
                &mut sample
            };
            target.extend_from_slice(&[0, 0, 0, 1]);
            target.extend_from_slice(nal);
        }
        let mut decoder = NativeFallback::new(OpenH264Decoder::new().unwrap(), || {
            Err(DecoderError::msg("test native initialization failure"))
        });
        assert!(decoder.decode_yuv420(&bootstrap).is_err());
        let decoded = decoder.decode_yuv420(&sample).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (128, 96));
        assert!(!decoder.waiting_for_idr);
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a physical Mac and VideoToolbox device access"]
    fn videotoolbox_returns_the_current_picture_and_correct_planes() {
        let bytes = synthetic_picture();
        let mut native = open_native().unwrap();
        let mut sw = OpenH264Decoder::new().unwrap();
        let expected = sw.decode_yuv420(&bytes).unwrap();
        let actual = native.decode_yuv420(&bytes).unwrap();
        assert_eq!((actual.width(), actual.height()), (128, 96));
        for (actual, expected) in [
            (actual.luma_row(10).unwrap(), expected.luma_row(10).unwrap()),
            (actual.u_row(5).unwrap(), expected.u_row(5).unwrap()),
            (actual.v_row(5).unwrap(), expected.v_row(5).unwrap()),
        ] {
            assert!(actual
                .iter()
                .zip(expected)
                .all(|(&a, &b)| a.abs_diff(b) <= 2));
        }
    }
}
