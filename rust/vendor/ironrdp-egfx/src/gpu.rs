//! GPU-resident surface composition hooks for hardware-decoded EGFX streams.
//!
//! When an embedder supplies a [`GpuCompositor`] and a hardware [`crate::decode::H264Decoder`]
//! implementing [`crate::decode::H264Decoder::decode_hw`], AVC420 and AVC444/v2 video frames
//! remain on the GPU through color conversion, chroma combination, surface-to-surface blits,
//! cache operations, and presentation into the embedder's external texture.

use core::any::Any;

pub use ironrdp_pdu::geometry::ExclusiveRectangle;

use crate::avc444::Avc444Layout;
use crate::pdu::{Color, Point};

/// Opaque GPU-resident video picture returned by a hardware H.264 decoder
/// (for example a `CVPixelBuffer` on macOS or a D3D11 NV12 texture on Windows).
pub trait HwVideoFrame: Any + Send {
    fn width(&self) -> u32;
    fn height(&self) -> u32;
    fn as_any(&self) -> &dyn Any;
}

/// Opaque GPU-composited output frame ready for direct presentation to an
/// external texture (for example a pooled `CVPixelBuffer` or DXGI shared handle).
pub trait GpuPresentedFrame: Any + Send {
    fn width(&self) -> u16;
    fn height(&self) -> u16;
    fn as_any(&self) -> &dyn Any;
    fn into_any(self: Box<Self>) -> Box<dyn Any + Send>;
}

/// Optional GPU-resident EGFX surface compositor.
///
/// Returning `false` from any mutating command signals an unrecoverable GPU
/// error (such as device removal or out-of-budget allocation) so
/// [`crate::client::GraphicsPipelineClient`] can tear down GPU compositing and
/// fall back to the CPU compositor.
pub trait GpuCompositor: Send {
    fn reset(&mut self, width: u32, height: u32) -> bool;
    fn create_surface(&mut self, id: u16, width: u16, height: u16) -> bool;
    fn delete_surface(&mut self, id: u16);
    fn map_surface_scaled(&mut self, id: u16, origin: (u32, u32), target: (u32, u32)) -> bool;
    fn unmap_surface(&mut self, id: u16);
    fn apply_hw_avc420(
        &mut self,
        surface_id: u16,
        frame: &dyn HwVideoFrame,
        dest: &ExclusiveRectangle,
        rects: &[ExclusiveRectangle],
    ) -> bool;
    fn apply_hw_avc444(
        &mut self,
        surface_id: u16,
        layout: Avc444Layout,
        main: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        auxiliary: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        painted: &[ExclusiveRectangle],
    ) -> bool;
    fn apply_rgba_region(
        &mut self,
        surface_id: u16,
        dest: &ExclusiveRectangle,
        rgba: &[u8],
        source_pitch: usize,
        source_origin: (u16, u16),
    ) -> bool;
    fn apply_clearcodec(&mut self, surface_id: u16, dest: &ExclusiveRectangle, bgra_coverage: &[u8]) -> bool;
    fn solid_fill(&mut self, surface_id: u16, color: &Color, rects: &[ExclusiveRectangle]) -> bool;
    fn surface_to_surface(
        &mut self,
        src_id: u16,
        dst_id: u16,
        src_rect: &ExclusiveRectangle,
        dst_points: &[Point],
    ) -> bool;
    fn surface_to_cache(&mut self, surface_id: u16, cache_slot: u16, src_rect: &ExclusiveRectangle) -> bool;
    fn cache_to_surface(&mut self, cache_slot: u16, surface_id: u16, dst_points: &[Point]) -> bool;
    fn evict_cache_entry(&mut self, cache_slot: u16);
    fn end_frame(&mut self) -> Option<Box<dyn GpuPresentedFrame>>;
}
