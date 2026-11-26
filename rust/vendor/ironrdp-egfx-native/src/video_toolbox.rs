//! Hardware-only VideoToolbox H.264 with zero-readback CVPixelBuffer & Metal GPU composition.
use core::any::Any;
use core::ffi::c_void;
use core::ptr::NonNull;
use ironrdp_egfx::avc444::Avc444Layout;
use ironrdp_egfx::decode::{DecodedFrame, DecoderError, DecoderResult, H264Decoder, Yuv420Frame};
use ironrdp_egfx::gpu::{ExclusiveRectangle, GpuCompositor, GpuPresentedFrame, HwVideoFrame};
use ironrdp_egfx::pdu::{Color, Point, annex_b_units};

#[repr(C)]
#[derive(Default)]
struct Planes {
    image: *mut c_void,
    y: *const u8,
    uv: *const u8,
    y_stride: usize,
    uv_stride: usize,
    width: usize,
    height: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MetalRect {
    left: u16,
    top: u16,
    right: u16,
    bottom: u16,
}

impl From<&ExclusiveRectangle> for MetalRect {
    fn from(r: &ExclusiveRectangle) -> Self {
        Self {
            left: r.left,
            top: r.top,
            right: r.right,
            bottom: r.bottom,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MetalPoint {
    x: u16,
    y: u16,
}

impl From<&Point> for MetalPoint {
    fn from(p: &Point) -> Self {
        Self { x: p.x, y: p.y }
    }
}

unsafe extern "C" {
    fn paga_rdp_vt_supported() -> bool;
    fn paga_rdp_vt_open(sps: *const u8, sps_len: usize, pps: *const u8, pps_len: usize) -> *mut c_void;
    fn paga_rdp_vt_decode(context: *mut c_void, bytes: *const u8, len: usize, planes: *mut Planes) -> bool;
    fn paga_rdp_vt_decode_pixel_buffer(
        context: *mut c_void,
        bytes: *const u8,
        len: usize,
        width: *mut usize,
        height: *mut usize,
    ) -> *mut c_void;
    fn paga_rdp_vt_release_pixel_buffer(image: *mut c_void);
    fn paga_rdp_vt_release_frame(image: *mut c_void);
    fn paga_rdp_vt_close(context: *mut c_void);

    fn paga_metal_compositor_new() -> *mut c_void;
    fn paga_metal_compositor_free(handle: *mut c_void);
    fn paga_metal_compositor_reset(handle: *mut c_void, width: u32, height: u32) -> bool;
    fn paga_metal_compositor_create_surface(handle: *mut c_void, id: u16, width: u16, height: u16) -> bool;
    fn paga_metal_compositor_delete_surface(handle: *mut c_void, id: u16);
    fn paga_metal_compositor_map_surface(
        handle: *mut c_void,
        id: u16,
        origin_x: u32,
        origin_y: u32,
        target_w: u32,
        target_h: u32,
    ) -> bool;
    fn paga_metal_compositor_unmap_surface(handle: *mut c_void, id: u16);
    fn paga_metal_compositor_apply_avc420(
        handle: *mut c_void,
        id: u16,
        pb: *mut c_void,
        dest: MetalRect,
        rects: *const MetalRect,
        rect_count: usize,
    ) -> bool;
    fn paga_metal_compositor_apply_avc444(
        handle: *mut c_void,
        id: u16,
        is_v2: bool,
        main_pb: *mut c_void,
        main_rects: *const MetalRect,
        main_count: usize,
        aux_pb: *mut c_void,
        aux_rects: *const MetalRect,
        aux_count: usize,
        painted: *const MetalRect,
        painted_count: usize,
    ) -> bool;
    fn paga_metal_compositor_apply_rgba(
        handle: *mut c_void,
        id: u16,
        dest: MetalRect,
        rgba: *const u8,
        pitch: usize,
        src_x: u16,
        src_y: u16,
    ) -> bool;
    fn paga_metal_compositor_apply_clearcodec(
        handle: *mut c_void,
        id: u16,
        dest: MetalRect,
        bgra_coverage: *const u8,
    ) -> bool;
    fn paga_metal_compositor_solid_fill(
        handle: *mut c_void,
        id: u16,
        r: u8,
        g: u8,
        b: u8,
        rects: *const MetalRect,
        rect_count: usize,
    ) -> bool;
    fn paga_metal_compositor_surface_to_surface(
        handle: *mut c_void,
        src_id: u16,
        dst_id: u16,
        src_rect: MetalRect,
        dsts: *const MetalPoint,
        dst_count: usize,
    ) -> bool;
    fn paga_metal_compositor_surface_to_cache(
        handle: *mut c_void,
        surface_id: u16,
        slot: u16,
        src_rect: MetalRect,
    ) -> bool;
    fn paga_metal_compositor_cache_to_surface(
        handle: *mut c_void,
        slot: u16,
        surface_id: u16,
        dsts: *const MetalPoint,
        dst_count: usize,
    ) -> bool;
    fn paga_metal_compositor_evict_cache(handle: *mut c_void, slot: u16);
    fn paga_metal_compositor_end_frame(handle: *mut c_void, width: *mut u16, height: *mut u16) -> *mut c_void;
}

/// GPU-resident VideoToolbox NV12 `CVPixelBuffer` (IOSurface-backed).
pub struct VtHwFrame {
    pixel_buffer: NonNull<c_void>,
    width: u32,
    height: u32,
}

// CVPixelBufferRef is thread-safe for read-only IOSurface consumption.
unsafe impl Send for VtHwFrame {}

impl VtHwFrame {
    pub fn as_ptr(&self) -> *mut c_void {
        self.pixel_buffer.as_ptr()
    }
}

impl Drop for VtHwFrame {
    fn drop(&mut self) {
        unsafe { paga_rdp_vt_release_pixel_buffer(self.pixel_buffer.as_ptr()) };
    }
}

impl HwVideoFrame for VtHwFrame {
    fn width(&self) -> u32 {
        self.width
    }

    fn height(&self) -> u32 {
        self.height
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Metal-composited `CVPixelBuffer` (`kCVPixelFormatType_32BGRA`, IOSurface-backed)
/// ready for direct zero-copy presentation into Flutter's `FlutterTexture`.
pub struct MetalPresentedFrame {
    pixel_buffer: NonNull<c_void>,
    width: u16,
    height: u16,
}

unsafe impl Send for MetalPresentedFrame {}

impl MetalPresentedFrame {
    /// Raw `CVPixelBufferRef` pointer as `u64` for passing across the runner FFI.
    /// Valid while `self` is alive; the receiver must `CFRetain` if storing beyond the call.
    pub fn raw_pixel_buffer(&self) -> u64 {
        self.pixel_buffer.as_ptr() as usize as u64
    }
}

impl Drop for MetalPresentedFrame {
    fn drop(&mut self) {
        unsafe { paga_rdp_vt_release_pixel_buffer(self.pixel_buffer.as_ptr()) };
    }
}

impl GpuPresentedFrame for MetalPresentedFrame {
    fn width(&self) -> u16 {
        self.width
    }

    fn height(&self) -> u16 {
        self.height
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any + Send> {
        self
    }
}

/// Metal GPU-resident EGFX surface compositor for macOS.
pub struct MetalGpuCompositor {
    handle: NonNull<c_void>,
}

// Exclusively mutated by the EGFX pipeline owner; Metal objects are safe to move across threads.
unsafe impl Send for MetalGpuCompositor {}

impl MetalGpuCompositor {
    pub fn new() -> Option<Self> {
        NonNull::new(unsafe { paga_metal_compositor_new() }).map(|handle| Self { handle })
    }
}

impl Drop for MetalGpuCompositor {
    fn drop(&mut self) {
        unsafe { paga_metal_compositor_free(self.handle.as_ptr()) };
    }
}

impl GpuCompositor for MetalGpuCompositor {
    fn reset(&mut self, width: u32, height: u32) -> bool {
        unsafe { paga_metal_compositor_reset(self.handle.as_ptr(), width, height) }
    }

    fn create_surface(&mut self, id: u16, width: u16, height: u16) -> bool {
        unsafe { paga_metal_compositor_create_surface(self.handle.as_ptr(), id, width, height) }
    }

    fn delete_surface(&mut self, id: u16) {
        unsafe { paga_metal_compositor_delete_surface(self.handle.as_ptr(), id) };
    }

    fn map_surface_scaled(&mut self, id: u16, origin: (u32, u32), target: (u32, u32)) -> bool {
        unsafe {
            paga_metal_compositor_map_surface(self.handle.as_ptr(), id, origin.0, origin.1, target.0, target.1)
        }
    }

    fn unmap_surface(&mut self, id: u16) {
        unsafe { paga_metal_compositor_unmap_surface(self.handle.as_ptr(), id) };
    }

    fn apply_hw_avc420(
        &mut self,
        surface_id: u16,
        frame: &dyn HwVideoFrame,
        dest: &ExclusiveRectangle,
        rects: &[ExclusiveRectangle],
    ) -> bool {
        let Some(vt) = frame.as_any().downcast_ref::<VtHwFrame>() else {
            return false;
        };
        let raw_rects: Vec<MetalRect> = rects.iter().map(MetalRect::from).collect();
        unsafe {
            paga_metal_compositor_apply_avc420(
                self.handle.as_ptr(),
                surface_id,
                vt.as_ptr(),
                MetalRect::from(dest),
                raw_rects.as_ptr(),
                raw_rects.len(),
            )
        }
    }

    fn apply_hw_avc444(
        &mut self,
        surface_id: u16,
        layout: Avc444Layout,
        main: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        auxiliary: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        painted: &[ExclusiveRectangle],
    ) -> bool {
        let (main_pb, main_rects) = match main {
            Some((frame, rects)) => {
                let Some(vt) = frame.as_any().downcast_ref::<VtHwFrame>() else {
                    return false;
                };
                (vt.as_ptr(), rects.iter().map(MetalRect::from).collect::<Vec<_>>())
            }
            None => (core::ptr::null_mut(), Vec::new()),
        };
        let (aux_pb, aux_rects) = match auxiliary {
            Some((frame, rects)) => {
                let Some(vt) = frame.as_any().downcast_ref::<VtHwFrame>() else {
                    return false;
                };
                (vt.as_ptr(), rects.iter().map(MetalRect::from).collect::<Vec<_>>())
            }
            None => (core::ptr::null_mut(), Vec::new()),
        };
        let painted_rects: Vec<MetalRect> = painted.iter().map(MetalRect::from).collect();
        unsafe {
            paga_metal_compositor_apply_avc444(
                self.handle.as_ptr(),
                surface_id,
                matches!(layout, Avc444Layout::V2),
                main_pb,
                main_rects.as_ptr(),
                main_rects.len(),
                aux_pb,
                aux_rects.as_ptr(),
                aux_rects.len(),
                painted_rects.as_ptr(),
                painted_rects.len(),
            )
        }
    }

    fn apply_rgba_region(
        &mut self,
        surface_id: u16,
        dest: &ExclusiveRectangle,
        rgba: &[u8],
        source_pitch: usize,
        source_origin: (u16, u16),
    ) -> bool {
        if dest.left >= dest.right || dest.top >= dest.bottom {
            return true;
        }
        let width = usize::from(dest.right - dest.left);
        let height = usize::from(dest.bottom - dest.top);
        let row_bytes = width.saturating_mul(4);
        let start = usize::from(source_origin.1)
            .saturating_mul(source_pitch)
            .saturating_add(usize::from(source_origin.0).saturating_mul(4));
        let needed = start
            .saturating_add(height.saturating_sub(1).saturating_mul(source_pitch))
            .saturating_add(row_bytes);
        if source_pitch < row_bytes || needed > rgba.len() {
            return false;
        }
        unsafe {
            paga_metal_compositor_apply_rgba(
                self.handle.as_ptr(),
                surface_id,
                MetalRect::from(dest),
                rgba.as_ptr(),
                source_pitch,
                source_origin.0,
                source_origin.1,
            )
        }
    }

    fn apply_clearcodec(&mut self, surface_id: u16, dest: &ExclusiveRectangle, bgra_coverage: &[u8]) -> bool {
        if dest.left >= dest.right || dest.top >= dest.bottom {
            return true;
        }
        let expected = usize::from(dest.right - dest.left)
            .saturating_mul(usize::from(dest.bottom - dest.top))
            .saturating_mul(4);
        if bgra_coverage.len() < expected {
            return false;
        }
        unsafe {
            paga_metal_compositor_apply_clearcodec(
                self.handle.as_ptr(),
                surface_id,
                MetalRect::from(dest),
                bgra_coverage.as_ptr(),
            )
        }
    }

    fn solid_fill(&mut self, surface_id: u16, color: &Color, rects: &[ExclusiveRectangle]) -> bool {
        let raw_rects: Vec<MetalRect> = rects.iter().map(MetalRect::from).collect();
        unsafe {
            paga_metal_compositor_solid_fill(
                self.handle.as_ptr(),
                surface_id,
                color.r,
                color.g,
                color.b,
                raw_rects.as_ptr(),
                raw_rects.len(),
            )
        }
    }

    fn surface_to_surface(
        &mut self,
        src_id: u16,
        dst_id: u16,
        src_rect: &ExclusiveRectangle,
        dst_points: &[Point],
    ) -> bool {
        let raw_points: Vec<MetalPoint> = dst_points.iter().map(MetalPoint::from).collect();
        unsafe {
            paga_metal_compositor_surface_to_surface(
                self.handle.as_ptr(),
                src_id,
                dst_id,
                MetalRect::from(src_rect),
                raw_points.as_ptr(),
                raw_points.len(),
            )
        }
    }

    fn surface_to_cache(&mut self, surface_id: u16, cache_slot: u16, src_rect: &ExclusiveRectangle) -> bool {
        unsafe {
            paga_metal_compositor_surface_to_cache(
                self.handle.as_ptr(),
                surface_id,
                cache_slot,
                MetalRect::from(src_rect),
            )
        }
    }

    fn cache_to_surface(&mut self, cache_slot: u16, surface_id: u16, dst_points: &[Point]) -> bool {
        let raw_points: Vec<MetalPoint> = dst_points.iter().map(MetalPoint::from).collect();
        unsafe {
            paga_metal_compositor_cache_to_surface(
                self.handle.as_ptr(),
                cache_slot,
                surface_id,
                raw_points.as_ptr(),
                raw_points.len(),
            )
        }
    }

    fn evict_cache_entry(&mut self, cache_slot: u16) {
        unsafe { paga_metal_compositor_evict_cache(self.handle.as_ptr(), cache_slot) };
    }

    fn end_frame(&mut self) -> Option<Box<dyn GpuPresentedFrame>> {
        let mut width = 0u16;
        let mut height = 0u16;
        let ptr = unsafe { paga_metal_compositor_end_frame(self.handle.as_ptr(), &mut width, &mut height) };
        let pixel_buffer = NonNull::new(ptr)?;
        Some(Box::new(MetalPresentedFrame {
            pixel_buffer,
            width,
            height,
        }))
    }
}

impl Drop for Planes {
    fn drop(&mut self) {
        unsafe { paga_rdp_vt_release_frame(self.image) };
    }
}

impl Planes {
    fn luma(&self) -> &[u8] {
        // The native call locked both planes and checked their dimensions.
        unsafe { core::slice::from_raw_parts(self.y, self.y_stride * self.height) }
    }

    fn chroma(&self) -> &[u8] {
        unsafe { core::slice::from_raw_parts(self.uv, self.uv_stride * self.height.div_ceil(2)) }
    }
}

pub struct VideoToolboxH264Decoder {
    context: Option<NonNull<c_void>>,
    parameter_sets: [Vec<u8>; 2],
    sample: Vec<u8>,
}

// The context is accessed only through exclusive calls. Each decode waits
// for its callbacks to finish before Rust can send the context to a new task.
unsafe impl Send for VideoToolboxH264Decoder {}

impl VideoToolboxH264Decoder {
    pub fn new() -> DecoderResult<Self> {
        if !unsafe { paga_rdp_vt_supported() } {
            return Err(DecoderError::msg("VideoToolbox has no H.264 hardware decoder"));
        }
        Ok(Self {
            context: None,
            parameter_sets: Default::default(),
            sample: Vec::new(),
        })
    }

    fn close(&mut self) {
        if let Some(context) = self.context.take() {
            unsafe { paga_rdp_vt_close(context.as_ptr()) };
        }
    }

    fn prepare_sample(&mut self, bytes: &[u8]) -> DecoderResult<NonNull<c_void>> {
        self.sample.clear();
        let mut changed = false;
        for nal in annex_b_units(bytes) {
            let kind = nal[0] & 31;
            if matches!(kind, 7 | 8) {
                if nal.len() > 16 * 1024 {
                    return Err(DecoderError::msg("VideoToolbox H.264 parameter set too large"));
                }
                let parameters = &mut self.parameter_sets[usize::from(kind - 7)];
                if parameters.as_slice() != nal {
                    parameters.clear();
                    parameters.extend_from_slice(nal);
                    changed = true;
                }
            } else {
                let len = u32::try_from(nal.len()).map_err(|_| DecoderError::msg("H.264 NAL too large"))?;
                self.sample.extend_from_slice(&len.to_be_bytes());
                self.sample.extend_from_slice(nal);
            }
        }
        if self.sample.is_empty() {
            return Err(DecoderError::msg("Empty H.264 sample"));
        }
        if self.context.is_none() || changed {
            self.close();
            let [sps, pps] = &self.parameter_sets;
            if sps.is_empty() || pps.is_empty() {
                return Err(DecoderError::msg("VideoToolbox requires H.264 SPS and PPS"));
            }
            self.context = NonNull::new(unsafe { paga_rdp_vt_open(sps.as_ptr(), sps.len(), pps.as_ptr(), pps.len()) });
        }
        self.context
            .ok_or_else(|| DecoderError::msg("VideoToolbox rejected H.264 configuration"))
    }

    fn picture(&mut self, bytes: &[u8]) -> DecoderResult<Planes> {
        let context = self.prepare_sample(bytes)?;
        let mut planes = Planes::default();
        if !unsafe { paga_rdp_vt_decode(context.as_ptr(), self.sample.as_ptr(), self.sample.len(), &mut planes) } {
            return Err(DecoderError::msg("VideoToolbox returned no matching H.264 frame"));
        }
        Ok(planes)
    }
}

impl Drop for VideoToolboxH264Decoder {
    fn drop(&mut self) {
        self.close();
    }
}

impl H264Decoder for VideoToolboxH264Decoder {
    fn supports_yuv420(&self) -> bool {
        true
    }

    fn supports_hw_frame(&self) -> bool {
        true
    }

    fn decode_hw(&mut self, bytes: &[u8]) -> DecoderResult<Option<Box<dyn HwVideoFrame>>> {
        let context = self.prepare_sample(bytes)?;
        let mut width = 0usize;
        let mut height = 0usize;
        let ptr = unsafe {
            paga_rdp_vt_decode_pixel_buffer(
                context.as_ptr(),
                self.sample.as_ptr(),
                self.sample.len(),
                &mut width,
                &mut height,
            )
        };
        let pixel_buffer =
            NonNull::new(ptr).ok_or_else(|| DecoderError::msg("VideoToolbox returned no matching H.264 frame"))?;
        Ok(Some(Box::new(VtHwFrame {
            pixel_buffer,
            width: width as u32,
            height: height as u32,
        })))
    }

    fn decode(&mut self, bytes: &[u8]) -> DecoderResult<DecodedFrame> {
        let mut rgba = Vec::new();
        let (width, height) = self.decode_avc420(bytes, &mut rgba)?;
        Ok(DecodedFrame::new(rgba, width, height))
    }

    fn decode_avc420(&mut self, bytes: &[u8], rgba: &mut Vec<u8>) -> DecoderResult<(u32, u32)> {
        let picture = self.picture(bytes)?;
        let width = picture.width as u32;
        let height = picture.height as u32;
        rgba.resize(picture.width * picture.height * 4, 0);
        yuv::yuv_nv12_to_rgba(
            &yuv::YuvBiPlanarImage {
                y_plane: picture.luma(),
                uv_plane: picture.chroma(),
                y_stride: picture.y_stride as u32,
                uv_stride: picture.uv_stride as u32,
                width,
                height,
            },
            rgba,
            width * 4,
            yuv::YuvRange::Full,
            yuv::YuvStandardMatrix::Bt709,
            yuv::YuvConversionMode::Balanced,
        )
        .map_err(|error| DecoderError::new("convert VideoToolbox NV12", error))?;
        Ok((width, height))
    }

    fn decode_yuv420(&mut self, bytes: &[u8]) -> DecoderResult<Yuv420Frame> {
        let picture = self.picture(bytes)?;
        let stride = picture.width.div_ceil(2);
        let mut u = Vec::with_capacity(stride * picture.height.div_ceil(2));
        let mut v = Vec::with_capacity(u.capacity());
        for row in picture.chroma().chunks_exact(picture.uv_stride) {
            for pair in row[..stride * 2].chunks_exact(2) {
                u.push(pair[0]);
                v.push(pair[1]);
            }
        }
        Yuv420Frame::new(
            picture.width as u16,
            picture.height as u16,
            picture.luma().to_vec(),
            picture.y_stride,
            u,
            v,
            stride,
        )
    }

    fn reset(&mut self) {
        self.close();
        self.parameter_sets.iter_mut().for_each(Vec::clear);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" {
        fn CVPixelBufferLockBaseAddress(pb: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferUnlockBaseAddress(pb: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferGetBaseAddress(pb: *mut c_void) -> *const u8;
        fn CVPixelBufferGetBytesPerRow(pb: *mut c_void) -> usize;
    }

    fn read_bgra_pixel(frame: &MetalPresentedFrame, x: usize, y: usize) -> [u8; 4] {
        let pb = frame.raw_pixel_buffer() as usize as *mut c_void;
        assert_eq!(unsafe { CVPixelBufferLockBaseAddress(pb, 1) }, 0);
        let base = unsafe { CVPixelBufferGetBaseAddress(pb) };
        let stride = unsafe { CVPixelBufferGetBytesPerRow(pb) };
        let px = unsafe {
            let p = base.add(y * stride + x * 4);
            [*p, *p.add(1), *p.add(2), *p.add(3)]
        };
        assert_eq!(unsafe { CVPixelBufferUnlockBaseAddress(pb, 1) }, 0);
        px
    }

    #[test]
    fn metal_compositor_renders_solid_rgba_clearcodec_scroll_and_cache_to_cvpixelbuffer() {
        let Some(mut gpu) = MetalGpuCompositor::new() else {
            return; // Headless CI without Metal device.
        };
        assert!(gpu.reset(64, 64));
        assert!(gpu.create_surface(1, 64, 64));
        assert!(gpu.map_surface_scaled(1, (0, 0), (64, 64)));

        // SolidFill (r=10, g=20, b=30) -> BGRA [30, 20, 10, 255]
        let bg = Color {
            b: 30,
            g: 20,
            r: 10,
            xa: 0,
        };
        assert!(gpu.solid_fill(
            1,
            &bg,
            &[ExclusiveRectangle {
                left: 0,
                top: 0,
                right: 64,
                bottom: 64,
            }],
        ));

        // RGBA patch (r=200, g=100, b=50, a=0) -> forced opaque BGRA [50, 100, 200, 255]
        let rgba = [200u8, 100, 50, 0].repeat(4 * 4);
        assert!(gpu.apply_rgba_region(
            1,
            &ExclusiveRectangle {
                left: 4,
                top: 4,
                right: 8,
                bottom: 8,
            },
            &rgba,
            16,
            (0, 0),
        ));

        // ClearCodec BGRA coverage patch: pixel (0,0) alpha=0 (preserved), pixel (1,0) alpha=255 (replaced)
        let clear = [
            0u8, 0, 0, 0, // skipped -> preserves (4,4) RGBA patch
            90, 80, 70, 255, // painted -> BGRA [90, 80, 70, 255]
        ];
        assert!(gpu.apply_clearcodec(
            1,
            &ExclusiveRectangle {
                left: 4,
                top: 4,
                right: 6,
                bottom: 5,
            },
            &clear,
        ));

        // Overlapping self-copy (SurfaceToSurface) & Cache round-trip
        assert!(gpu.surface_to_surface(
            1,
            1,
            &ExclusiveRectangle {
                left: 4,
                top: 4,
                right: 8,
                bottom: 8,
            },
            &[Point { x: 6, y: 4 }],
        ));
        assert!(gpu.surface_to_cache(
            1,
            7,
            &ExclusiveRectangle {
                left: 6,
                top: 4,
                right: 10,
                bottom: 8,
            },
        ));
        assert!(gpu.cache_to_surface(7, 1, &[Point { x: 32, y: 32 }]));

        let presented = gpu.end_frame().expect("expected Metal CVPixelBuffer frame");
        assert_eq!((presented.width(), presented.height()), (64, 64));
        let metal = presented
            .as_any()
            .downcast_ref::<MetalPresentedFrame>()
            .expect("MetalPresentedFrame");

        assert_eq!(read_bgra_pixel(metal, 0, 0), [30, 20, 10, 255]);
        assert_eq!(read_bgra_pixel(metal, 4, 4), [50, 100, 200, 255]);
        assert_eq!(read_bgra_pixel(metal, 5, 4), [90, 80, 70, 255]);
        assert_eq!(read_bgra_pixel(metal, 6, 4), [50, 100, 200, 255]);
        assert_eq!(read_bgra_pixel(metal, 7, 4), [90, 80, 70, 255]);
        assert_eq!(read_bgra_pixel(metal, 32, 32), [50, 100, 200, 255]);
        assert_eq!(read_bgra_pixel(metal, 33, 32), [90, 80, 70, 255]);
    }
}
