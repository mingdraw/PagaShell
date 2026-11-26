use core::{ffi::c_void, marker::PhantomData, ptr::NonNull};

use ironrdp_egfx::decode::{DecodedFrame, DecoderError, DecoderResult, H264Decoder, Yuv420Frame};

#[repr(C)]
#[derive(Default)]
struct RawPicture {
    planes: [*const u8; 3],
    strides: [usize; 3],
    width: usize,
    height: usize,
    interleaved_chroma: bool,
}

unsafe extern "C" {
    fn paga_rdp_vaapi_open() -> *mut c_void;
    fn paga_rdp_vaapi_decode(decoder: *mut c_void, bytes: *const u8, len: usize, result: *mut RawPicture) -> bool;
    fn paga_rdp_vaapi_reset(decoder: *mut c_void);
    fn paga_rdp_vaapi_close(decoder: *mut c_void);
}

struct Picture<'a> {
    raw: RawPicture,
    // Data stays valid until we take another exclusive borrow of the decoder.
    _decoder: PhantomData<&'a mut VaapiDecoder>,
}

impl Picture<'_> {
    fn plane(&self, index: usize) -> &[u8] {
        let rows = if index == 0 {
            self.raw.height
        } else {
            self.raw.height.div_ceil(2)
        };
        // Native decode validates width, height, format, non-null planes and
        // positive pitch. FFmpeg owns the CPU transfer buffers.
        unsafe { core::slice::from_raw_parts(self.raw.planes[index], self.raw.strides[index] * rows) }
    }
}

pub(crate) struct VaapiDecoder(NonNull<c_void>);

// AVCodecContext is confined to one exclusive caller at any moment. FFmpeg
// and the VA-API driver manage their own internal thread synchronization.
unsafe impl Send for VaapiDecoder {}

impl VaapiDecoder {
    pub fn new() -> DecoderResult<Self> {
        NonNull::new(unsafe { paga_rdp_vaapi_open() })
            .map(Self)
            .ok_or_else(|| DecoderError::msg("VA-API H.264 is not available"))
    }

    fn picture(&mut self, bytes: &[u8]) -> DecoderResult<Picture<'_>> {
        let mut raw = RawPicture::default();
        if !unsafe { paga_rdp_vaapi_decode(self.0.as_ptr(), bytes.as_ptr(), bytes.len(), &mut raw) } {
            return Err(DecoderError::msg("VA-API returned no matching H.264 frame"));
        }
        Ok(Picture {
            raw,
            _decoder: PhantomData,
        })
    }
}

impl Drop for VaapiDecoder {
    fn drop(&mut self) {
        unsafe { paga_rdp_vaapi_close(self.0.as_ptr()) };
    }
}

impl H264Decoder for VaapiDecoder {
    fn supports_yuv420(&self) -> bool {
        true
    }

    fn decode(&mut self, bytes: &[u8]) -> DecoderResult<DecodedFrame> {
        let mut rgba = Vec::new();
        let (width, height) = self.decode_avc420(bytes, &mut rgba)?;
        Ok(DecodedFrame::new(rgba, width, height))
    }

    fn decode_yuv420(&mut self, bytes: &[u8]) -> DecoderResult<Yuv420Frame> {
        let picture = self.picture(bytes)?;
        let width = picture.raw.width;
        let height = picture.raw.height;
        let chroma_width = width.div_ceil(2);
        let chroma_rows = height.div_ceil(2);
        let mut u = Vec::with_capacity(chroma_width * chroma_rows);
        let mut v = Vec::with_capacity(chroma_width * chroma_rows);
        if picture.raw.interleaved_chroma {
            for row in picture.plane(1).chunks_exact(picture.raw.strides[1]) {
                for pair in row[..chroma_width * 2].chunks_exact(2) {
                    u.push(pair[0]);
                    v.push(pair[1]);
                }
            }
        } else {
            for row in picture.plane(1).chunks_exact(picture.raw.strides[1]) {
                u.extend_from_slice(&row[..chroma_width]);
            }
            for row in picture.plane(2).chunks_exact(picture.raw.strides[2]) {
                v.extend_from_slice(&row[..chroma_width]);
            }
        }
        Yuv420Frame::new(
            width as u16,
            height as u16,
            picture.plane(0).to_vec(),
            picture.raw.strides[0],
            u,
            v,
            chroma_width,
        )
    }

    fn decode_avc420(&mut self, bytes: &[u8], rgba: &mut Vec<u8>) -> DecoderResult<(u32, u32)> {
        let picture = self.picture(bytes)?;
        let width = picture.raw.width as u32;
        let height = picture.raw.height as u32;
        let [y_stride, u_stride, v_stride] = picture.raw.strides.map(|stride| stride as u32);
        rgba.resize(picture.raw.width * picture.raw.height * 4, 0);
        let result = if picture.raw.interleaved_chroma {
            yuv::yuv_nv12_to_rgba(
                &yuv::YuvBiPlanarImage {
                    y_plane: picture.plane(0),
                    uv_plane: picture.plane(1),
                    y_stride,
                    uv_stride: u_stride,
                    width,
                    height,
                },
                rgba,
                width * 4,
                yuv::YuvRange::Full,
                yuv::YuvStandardMatrix::Bt709,
                yuv::YuvConversionMode::Balanced,
            )
        } else {
            yuv::yuv420_to_rgba(
                &yuv::YuvPlanarImage {
                    y_plane: picture.plane(0),
                    u_plane: picture.plane(1),
                    v_plane: picture.plane(2),
                    y_stride,
                    u_stride,
                    v_stride,
                    width,
                    height,
                },
                rgba,
                width * 4,
                yuv::YuvRange::Full,
                yuv::YuvStandardMatrix::Bt709,
            )
        };
        result.map_err(|error| DecoderError::new("convert VA-API H.264 picture", error))?;
        Ok((width, height))
    }

    fn reset(&mut self) {
        unsafe { paga_rdp_vaapi_reset(self.0.as_ptr()) };
    }
}
