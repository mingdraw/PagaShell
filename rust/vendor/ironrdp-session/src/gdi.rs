//! Classic MS-RDPEGDI drawing orders and client-side bitmap, glyph, and offscreen caches.
//!
//! Used by non-EGFX RDP servers (and fallback GDI paths) to avoid re-transmitting
//! repeated UI bitmaps, glyphs, and offscreen window surfaces.

use std::collections::BTreeMap;

use ironrdp_core::ReadCursor;
use ironrdp_graphics::color_conversion::{rdp_15bit_to_rgb, rdp_16bit_to_rgb};
use ironrdp_graphics::rdp6::BitmapStreamDecoder;
use ironrdp_graphics::rle::{self, RlePixelFormat};
use ironrdp_pdu::geometry::{InclusiveRectangle, Rectangle as _};
use tracing::{debug, trace, warn};

use crate::image::DecodedImage;
use crate::palette::Palette;

// Order control flags ([MS-RDPEGDI] 2.2.2.2)
const TS_STANDARD: u8 = 0x01;
const TS_SECONDARY: u8 = 0x02;
const TS_BOUNDS: u8 = 0x04;
const TS_TYPE_CHANGE: u8 = 0x08;
const TS_DELTA_COORDINATES: u8 = 0x10;
const TS_ZERO_BOUNDS_DELTAS: u8 = 0x20;
const TS_ZERO_FIELD_BYTE_BIT0: u8 = 0x40;
const TS_ZERO_FIELD_BYTE_BIT1: u8 = 0x80;

// Primary drawing order types
const ORDER_DSTBLT: u8 = 0x00;
const ORDER_PATBLT: u8 = 0x01;
const ORDER_SCRBLT: u8 = 0x02;
const ORDER_OPAQUERECT: u8 = 0x0A;
const ORDER_MEMBLT: u8 = 0x0D;
const ORDER_MULTIOPAQUERECT: u8 = 0x12;
const ORDER_FAST_INDEX: u8 = 0x13;
const ORDER_FAST_GLYPH: u8 = 0x18;
const ORDER_GLYPH_INDEX: u8 = 0x1B;

// Secondary drawing order types
const SEC_CACHE_BITMAP_UNCOMPRESSED: u8 = 0x00;
const SEC_CACHE_COLOR_TABLE: u8 = 0x01;
const SEC_CACHE_BITMAP_COMPRESSED: u8 = 0x02;
const SEC_CACHE_GLYPH: u8 = 0x03;
const SEC_CACHE_BITMAP_UNCOMPRESSED_REV2: u8 = 0x04;
const SEC_CACHE_BITMAP_COMPRESSED_REV2: u8 = 0x05;
const SEC_CACHE_BRUSH: u8 = 0x07;
const SEC_CACHE_GLYPH_V2: u8 = 0x09;

// Alternate secondary drawing order types (controlFlags >> 2)
const ALTSEC_SWITCH_SURFACE: u8 = 0x00;
const ALTSEC_CREATE_OFFSCR_BITMAP: u8 = 0x01;
pub(crate) const ALTSEC_WINDOW: u8 = 0x0B;
const ALTSEC_FRAME_MARKER: u8 = 0x0D;

// CacheBitmapRev2 flags (in extraFlags >> 7)
const CBR2_HEIGHT_SAME_AS_WIDTH: u16 = 0x0001;
const CBR2_PERSISTENT_KEY_PRESENT: u16 = 0x0002;
const CBR2_NO_BITMAP_COMPRESSION_HDR: u16 = 0x0008;
const CBR2_DO_NOT_CACHE: u16 = 0x0010;
const BITMAPCACHE_WAITING_LIST_INDEX: u16 = 0x7FFF;

// Strict memory limits so malformed streams cannot exhaust memory.
const MAX_BITMAP_CACHE_BYTES: usize = 32 * 1024 * 1024;
const MAX_GLYPH_CACHE_BYTES: usize = 8 * 1024 * 1024;
const MAX_OFFSCREEN_BYTES: usize = 16 * 1024 * 1024;
const MAX_OFFSCREEN_ENTRIES: usize = 128;
const MAX_SURFACE_DIM: u16 = 8192;

#[derive(Clone, Copy, Default)]
struct ClipBounds {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
}

#[derive(Clone, Default)]
struct CachedBitmap {
    width: u16,
    height: u16,
    rgba: Vec<u8>,
}

#[derive(Clone, Default)]
struct CachedGlyph {
    x: i16,
    y: i16,
    cx: u16,
    cy: u16,
    data: Vec<u8>,
}

struct OffscreenSurface {
    width: u16,
    height: u16,
    rgba: Vec<u8>,
}

#[derive(Default)]
struct DstBltState {
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    rop: u8,
}

#[derive(Default)]
struct PatBltState {
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    rop: u8,
    back_color: [u8; 3],
    fore_color: [u8; 3],
    brush_org_x: i8,
    brush_org_y: i8,
    brush_style: u8,
    brush_hatch: u8,
    brush_extra: [u8; 7],
}

#[derive(Default)]
struct ScrBltState {
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    rop: u8,
    src_x: i16,
    src_y: i16,
}

#[derive(Default)]
struct OpaqueRectState {
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    color: [u8; 3],
}

#[derive(Default)]
struct MultiOpaqueRectState {
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    color: [u8; 3],
    delta_entries: u8,
    coded_deltas: Vec<u8>,
}

#[derive(Default)]
struct MemBltState {
    cache_id: u16,
    left: i16,
    top: i16,
    width: i16,
    height: i16,
    rop: u8,
    src_x: i16,
    src_y: i16,
    cache_index: u16,
}

#[derive(Default)]
struct FastIndexState {
    cache_id: u8,
    f_drawing: u16,
    back_color: [u8; 3],
    fore_color: [u8; 3],
    bk_left: i16,
    bk_top: i16,
    bk_right: i16,
    bk_bottom: i16,
    op_left: i16,
    op_top: i16,
    op_right: i16,
    op_bottom: i16,
    x: i16,
    y: i16,
    data: Vec<u8>,
}

#[derive(Default)]
struct FastGlyphState {
    cache_id: u8,
    f_drawing: u16,
    back_color: [u8; 3],
    fore_color: [u8; 3],
    bk_left: i16,
    bk_top: i16,
    bk_right: i16,
    bk_bottom: i16,
    op_left: i16,
    op_top: i16,
    op_right: i16,
    op_bottom: i16,
    x: i16,
    y: i16,
    data: Vec<u8>,
}

#[derive(Default)]
struct GlyphIndexState {
    cache_id: u8,
    fl_accel: u8,
    ul_char_inc: u8,
    f_op_redundant: u8,
    back_color: [u8; 3],
    fore_color: [u8; 3],
    bk_left: i16,
    bk_top: i16,
    bk_right: i16,
    bk_bottom: i16,
    op_left: i16,
    op_top: i16,
    op_right: i16,
    op_bottom: i16,
    brush_org_x: i8,
    brush_org_y: i8,
    brush_style: u8,
    brush_hatch: u8,
    brush_extra: [u8; 7],
    x: i16,
    y: i16,
    data: Vec<u8>,
}

/// Stateful MS-RDPEGDI drawing order processor and cache manager.
pub(crate) struct GdiOrderProcessor {
    // Persistent primary order decode state
    order_type: u8,
    bounds: ClipBounds,
    dstblt: DstBltState,
    patblt: PatBltState,
    scrblt: ScrBltState,
    opaque_rect: OpaqueRectState,
    multi_opaque_rect: MultiOpaqueRectState,
    memblt: MemBltState,
    fast_index: FastIndexState,
    fast_glyph: FastGlyphState,
    glyph_index: GlyphIndexState,

    // Client caches
    bitmap_cache: BTreeMap<(u8, u16), CachedBitmap>,
    bitmap_cache_bytes: usize,
    color_tables: BTreeMap<u8, Vec<[u8; 3]>>,
    glyph_cache: BTreeMap<(u8, u16), CachedGlyph>,
    glyph_cache_bytes: usize,
    frag_cache: BTreeMap<u8, Vec<u8>>,
    offscreen: BTreeMap<u16, OffscreenSurface>,
    offscreen_bytes: usize,
    active_offscreen: Option<u16>,

    // Reusable decode scratch
    planar_decoder: BitmapStreamDecoder,
    scratch: Vec<u8>,
}

impl Default for GdiOrderProcessor {
    fn default() -> Self {
        Self::new()
    }
}

impl GdiOrderProcessor {
    pub(crate) fn new() -> Self {
        Self {
            // MS-RDPEGDI 2.2.2.2.1.1.2: initial primary order type is PATBLT (0x01).
            order_type: ORDER_PATBLT,
            bounds: ClipBounds::default(),
            dstblt: DstBltState::default(),
            patblt: PatBltState::default(),
            scrblt: ScrBltState::default(),
            opaque_rect: OpaqueRectState::default(),
            multi_opaque_rect: MultiOpaqueRectState::default(),
            memblt: MemBltState::default(),
            fast_index: FastIndexState::default(),
            fast_glyph: FastGlyphState::default(),
            glyph_index: GlyphIndexState::default(),
            bitmap_cache: BTreeMap::new(),
            bitmap_cache_bytes: 0,
            color_tables: BTreeMap::new(),
            glyph_cache: BTreeMap::new(),
            glyph_cache_bytes: 0,
            frag_cache: BTreeMap::new(),
            offscreen: BTreeMap::new(),
            offscreen_bytes: 0,
            active_offscreen: None,
            planar_decoder: BitmapStreamDecoder::default(),
            scratch: Vec::new(),
        }
    }

    pub(crate) fn reset(&mut self) {
        *self = Self::new();
    }

    /// Returns true when the order stream starts with an alternate secondary RAIL windowing order.
    pub(crate) fn is_fast_path_windowing_orders(data: &[u8]) -> bool {
        data.len() >= 3 && (data[2] & TS_STANDARD) == 0 && (data[2] >> 2) == ALTSEC_WINDOW
    }

    pub(crate) fn is_slow_path_windowing_orders(data: &[u8]) -> bool {
        data.len() >= 7 && (data[6] & TS_STANDARD) == 0 && (data[6] >> 2) == ALTSEC_WINDOW
    }

    pub(crate) fn process_fast_path_orders(
        &mut self,
        image: &mut DecodedImage,
        palette: &Palette,
        data: &[u8],
    ) -> Vec<InclusiveRectangle> {
        let mut src = ReadCursor::new(data);
        if src.len() < 2 {
            return Vec::new();
        }
        let number_orders = src.read_u16();
        self.process_order_stream(image, palette, number_orders, &mut src)
    }

    pub(crate) fn process_slow_path_orders(
        &mut self,
        image: &mut DecodedImage,
        palette: &Palette,
        data: &[u8],
    ) -> Vec<InclusiveRectangle> {
        let mut src = ReadCursor::new(data);
        if src.len() < 6 {
            return Vec::new();
        }
        let _pad_a = src.read_u16();
        let number_orders = src.read_u16();
        let _pad_b = src.read_u16();
        self.process_order_stream(image, palette, number_orders, &mut src)
    }

    fn process_order_stream(
        &mut self,
        image: &mut DecodedImage,
        palette: &Palette,
        number_orders: u16,
        src: &mut ReadCursor<'_>,
    ) -> Vec<InclusiveRectangle> {
        let mut damage = Vec::new();
        for _ in 0..number_orders {
            if src.is_empty() {
                break;
            }
            let control_flags = src.read_u8();
            let ok = if (control_flags & (TS_STANDARD | TS_SECONDARY)) == (TS_STANDARD | TS_SECONDARY) {
                self.process_secondary_order(src, palette)
            } else if (control_flags & TS_STANDARD) == 0 {
                self.process_altsec_order(control_flags >> 2, src)
            } else {
                self.process_primary_order(control_flags, src, image, &mut damage)
            };
            if !ok {
                debug!(
                    control_flags,
                    remaining = src.len(),
                    "Stopped parsing GDI order stream on unsupported or truncated order"
                );
                break;
            }
        }
        damage
    }

    // ========================================================================
    // Alternate Secondary Orders
    // ========================================================================

    fn process_altsec_order(&mut self, order_type: u8, src: &mut ReadCursor<'_>) -> bool {
        match order_type {
            ALTSEC_SWITCH_SURFACE => {
                if src.len() < 2 {
                    return false;
                }
                let bitmap_id = src.read_u16();
                if bitmap_id == 0xFFFF {
                    self.active_offscreen = None;
                } else {
                    self.active_offscreen = Some(bitmap_id);
                }
                trace!(bitmap_id, "GDI SwitchSurface");
                true
            }
            ALTSEC_CREATE_OFFSCR_BITMAP => {
                if src.len() < 6 {
                    return false;
                }
                let flags = src.read_u16();
                let bitmap_id = flags & 0x7FFF;
                let has_delete_list = (flags & 0x8000) != 0;
                let cx = src.read_u16();
                let cy = src.read_u16();
                if has_delete_list {
                    if src.len() < 2 {
                        return false;
                    }
                    let count = usize::from(src.read_u16());
                    if src.len() < count * 2 {
                        return false;
                    }
                    for _ in 0..count {
                        let delete_id = src.read_u16();
                        if let Some(removed) = self.offscreen.remove(&delete_id) {
                            self.offscreen_bytes = self.offscreen_bytes.saturating_sub(removed.rgba.len());
                        }
                        if self.active_offscreen == Some(delete_id) {
                            self.active_offscreen = None;
                        }
                    }
                }
                if cx == 0 || cy == 0 || cx > MAX_SURFACE_DIM || cy > MAX_SURFACE_DIM {
                    return true;
                }
                if let Some(old) = self.offscreen.remove(&bitmap_id) {
                    self.offscreen_bytes = self.offscreen_bytes.saturating_sub(old.rgba.len());
                }
                let bytes = usize::from(cx).saturating_mul(usize::from(cy)).saturating_mul(4);
                if self.offscreen.len() >= MAX_OFFSCREEN_ENTRIES
                    || self.offscreen_bytes.saturating_add(bytes) > MAX_OFFSCREEN_BYTES
                {
                    warn!(bitmap_id, cx, cy, "GDI OffscreenBitmapCache budget exceeded");
                    return true;
                }
                let mut rgba = vec![0u8; bytes];
                for px in rgba.as_chunks_mut::<4>().0 {
                    px[3] = 255;
                }
                self.offscreen_bytes += bytes;
                self.offscreen.insert(
                    bitmap_id,
                    OffscreenSurface {
                        width: cx,
                        height: cy,
                        rgba,
                    },
                );
                trace!(bitmap_id, cx, cy, "GDI CreateOffscreenBitmap");
                true
            }
            ALTSEC_FRAME_MARKER => {
                if src.len() < 4 {
                    return false;
                }
                let _action = src.read_u32();
                true
            }
            other => {
                debug!(order_type = other, "Unsupported GDI alternate secondary order");
                false
            }
        }
    }

    // ========================================================================
    // Secondary Orders
    // ========================================================================

    fn process_secondary_order(&mut self, src: &mut ReadCursor<'_>, palette: &Palette) -> bool {
        if src.len() < 5 {
            return false;
        }
        // MS-RDPEGDI 2.2.2.2.1.2.1.1: total order size = orderLength + 13; header = 6 bytes.
        let order_length = src.read_i16();
        let extra_flags = src.read_u16();
        let order_type = src.read_u8();
        let body_len = i32::from(order_length) + 7;
        if body_len < 0 || (body_len as usize) > src.len() {
            return false;
        }
        let body = src.read_slice(body_len as usize);
        let mut cursor = ReadCursor::new(body);

        match order_type {
            SEC_CACHE_BITMAP_UNCOMPRESSED | SEC_CACHE_BITMAP_COMPRESSED => {
                self.handle_cache_bitmap_rev1(
                    &mut cursor,
                    palette,
                    order_type == SEC_CACHE_BITMAP_COMPRESSED,
                );
            }
            SEC_CACHE_BITMAP_UNCOMPRESSED_REV2 | SEC_CACHE_BITMAP_COMPRESSED_REV2 => {
                self.handle_cache_bitmap_rev2(
                    extra_flags,
                    &mut cursor,
                    palette,
                    order_type == SEC_CACHE_BITMAP_COMPRESSED_REV2,
                );
            }
            SEC_CACHE_COLOR_TABLE => {
                self.handle_cache_color_table(&mut cursor);
            }
            SEC_CACHE_GLYPH => {
                self.handle_cache_glyph_rev1(&mut cursor);
            }
            SEC_CACHE_GLYPH_V2 => {
                self.handle_cache_glyph_rev2(extra_flags, &mut cursor);
            }
            SEC_CACHE_BRUSH => {
                trace!("Ignoring GDI CacheBrush (solid brushes only)");
            }
            other => {
                debug!(order_type = other, "Skipping unsupported GDI secondary order");
            }
        }
        true
    }

    fn handle_cache_color_table(&mut self, src: &mut ReadCursor<'_>) {
        if src.len() < 3 {
            return;
        }
        let cache_index = src.read_u8();
        let count = usize::from(src.read_u16()).min(256);
        if src.len() < count * 4 {
            return;
        }
        let mut colors = Vec::with_capacity(count);
        for _ in 0..count {
            let b = src.read_u8();
            let g = src.read_u8();
            let r = src.read_u8();
            let _pad = src.read_u8();
            colors.push([r, g, b]);
        }
        self.color_tables.insert(cache_index, colors);
    }

    fn handle_cache_bitmap_rev1(&mut self, src: &mut ReadCursor<'_>, palette: &Palette, compressed: bool) {
        if src.len() < 9 {
            return;
        }
        let cache_id = src.read_u8();
        let _pad = src.read_u8();
        let width = u16::from(src.read_u8());
        let height = u16::from(src.read_u8());
        let bpp = src.read_u8();
        let bitmap_len = usize::from(src.read_u16());
        let cache_index = src.read_u16();
        if width == 0 || height == 0 || bitmap_len > src.len() {
            return;
        }
        let mut data = src.read_slice(bitmap_len);
        // NO_BITMAP_COMPRESSION_HDR is advertised, so compressed Rev1 streams omit the 8-byte header
        // unless a legacy server includes it; check via decode fallback cleanly.
        if compressed && data.len() >= 8 {
            let main_body_size = u16::from_le_bytes([data[2], data[3]]) as usize;
            let total_size = u16::from_le_bytes([data[6], data[7]]) as usize;
            if main_body_size == data.len() - 8 && total_size >= usize::from(width) * usize::from(height) {
                data = &data[8..];
            }
        }
        if let Some(rgba) = self.decode_bitmap_to_rgba(width, height, bpp, compressed, data, palette) {
            self.store_bitmap_cache(cache_id, cache_index, width, height, rgba);
        }
    }

    fn handle_cache_bitmap_rev2(
        &mut self,
        extra_flags: u16,
        src: &mut ReadCursor<'_>,
        palette: &Palette,
        compressed: bool,
    ) {
        let cache_id = (extra_flags & 0x0007) as u8;
        let bpp_id = ((extra_flags >> 3) & 0x000F) as u8;
        let flags = (extra_flags >> 7) & 0x01FF;
        let bpp = match bpp_id {
            3 => 8u8,
            4 => 16u8,
            5 => 24u8,
            6 => 32u8,
            _ => return,
        };
        if (flags & CBR2_PERSISTENT_KEY_PRESENT) != 0 {
            if src.len() < 8 {
                return;
            }
            let _ = src.read_slice(8);
        }
        let Some(width) = read_2byte_unsigned(src) else {
            return;
        };
        let height = if (flags & CBR2_HEIGHT_SAME_AS_WIDTH) != 0 {
            width
        } else {
            let Some(h) = read_2byte_unsigned(src) else {
                return;
            };
            h
        };
        let Some(bitmap_size) = read_4byte_unsigned(src) else {
            return;
        };
        let Some(mut cache_index) = read_2byte_unsigned(src) else {
            return;
        };
        if (flags & CBR2_DO_NOT_CACHE) != 0 {
            cache_index = BITMAPCACHE_WAITING_LIST_INDEX;
        }
        if width == 0 || height == 0 || width > MAX_SURFACE_DIM || height > MAX_SURFACE_DIM {
            return;
        }
        let bitmap_size = bitmap_size as usize;
        if bitmap_size > src.len() {
            return;
        }
        let mut data = src.read_slice(bitmap_size);
        if compressed && (flags & CBR2_NO_BITMAP_COMPRESSION_HDR) == 0 {
            if data.len() < 8 {
                return;
            }
            data = &data[8..];
        }
        if let Some(rgba) = self.decode_bitmap_to_rgba(width, height, bpp, compressed, data, palette) {
            self.store_bitmap_cache(cache_id, cache_index, width, height, rgba);
        }
    }

    fn decode_bitmap_to_rgba(
        &mut self,
        width: u16,
        height: u16,
        bpp: u8,
        compressed: bool,
        data: &[u8],
        palette: &Palette,
    ) -> Option<Vec<u8>> {
        let w = usize::from(width);
        let h = usize::from(height);
        let pixel_count = w.checked_mul(h)?;
        let out_bytes = pixel_count.checked_mul(4)?;
        if out_bytes > 16 * 1024 * 1024 {
            return None;
        }

        if compressed {
            if bpp == 32 {
                self.scratch.clear();
                self.planar_decoder
                    .decode_bitmap_stream_to_rgb24(data, &mut self.scratch, w, h)
                    .ok()?;
                if self.scratch.len() < pixel_count * 3 {
                    return None;
                }
                // RDP6 planar streams are bottom-up RGB24 -> flip vertically to top-down RGBA32.
                let mut rgba = vec![255u8; out_bytes];
                let src_stride = w * 3;
                for y in 0..h {
                    let src_row = &self.scratch[(h - 1 - y) * src_stride..(h - y) * src_stride];
                    let dst_row = &mut rgba[y * w * 4..(y + 1) * w * 4];
                    for (px, dst) in src_row.chunks_exact(3).zip(dst_row.chunks_exact_mut(4)) {
                        dst[0] = px[0];
                        dst[1] = px[1];
                        dst[2] = px[2];
                        dst[3] = 255;
                    }
                }
                return Some(rgba);
            }
            self.scratch.clear();
            let fmt = rle::decompress(data, &mut self.scratch, w, h, usize::from(bpp)).ok()?;
            return convert_bottom_up_to_rgba(w, h, fmt, &self.scratch, palette.colors());
        }

        // Uncompressed bottom-up bitmap (rows padded to 4-byte boundary or tightly packed).
        let bytes_per_pixel = usize::from(bpp).div_ceil(8);
        let raw_stride = w.checked_mul(bytes_per_pixel)?;
        let padded_stride = (raw_stride + 3) & !3;
        let stride = if data.len() >= padded_stride.saturating_mul(h) {
            padded_stride
        } else if data.len() >= raw_stride.saturating_mul(h) {
            raw_stride
        } else {
            return None;
        };

        let mut rgba = vec![255u8; out_bytes];
        for y in 0..h {
            let src_row = &data[(h - 1 - y) * stride..(h - 1 - y) * stride + raw_stride];
            let dst_row = &mut rgba[y * w * 4..(y + 1) * w * 4];
            match bpp {
                32 => {
                    for (px, dst) in src_row.chunks_exact(4).zip(dst_row.chunks_exact_mut(4)) {
                        dst[0] = px[2];
                        dst[1] = px[1];
                        dst[2] = px[0];
                        dst[3] = 255;
                    }
                }
                24 => {
                    for (px, dst) in src_row.chunks_exact(3).zip(dst_row.chunks_exact_mut(4)) {
                        dst[0] = px[2];
                        dst[1] = px[1];
                        dst[2] = px[0];
                        dst[3] = 255;
                    }
                }
                16 => {
                    for (px, dst) in src_row.chunks_exact(2).zip(dst_row.chunks_exact_mut(4)) {
                        let [r, g, b] = rdp_16bit_to_rgb(u16::from_le_bytes([px[0], px[1]]));
                        dst[0] = r;
                        dst[1] = g;
                        dst[2] = b;
                        dst[3] = 255;
                    }
                }
                15 => {
                    for (px, dst) in src_row.chunks_exact(2).zip(dst_row.chunks_exact_mut(4)) {
                        let [r, g, b] = rdp_15bit_to_rgb(u16::from_le_bytes([px[0], px[1]]));
                        dst[0] = r;
                        dst[1] = g;
                        dst[2] = b;
                        dst[3] = 255;
                    }
                }
                8 => {
                    let colors = palette.colors();
                    for (&idx, dst) in src_row.iter().zip(dst_row.chunks_exact_mut(4)) {
                        let rgb = colors.get(usize::from(idx)).copied().unwrap_or([0, 0, 0]);
                        dst[0] = rgb[0];
                        dst[1] = rgb[1];
                        dst[2] = rgb[2];
                        dst[3] = 255;
                    }
                }
                _ => return None,
            }
        }
        Some(rgba)
    }

    fn store_bitmap_cache(&mut self, cache_id: u8, cache_index: u16, width: u16, height: u16, rgba: Vec<u8>) {
        if let Some(old) = self.bitmap_cache.remove(&(cache_id, cache_index)) {
            self.bitmap_cache_bytes = self.bitmap_cache_bytes.saturating_sub(old.rgba.len());
        }
        let needed = rgba.len();
        if needed > MAX_BITMAP_CACHE_BYTES {
            return;
        }
        while self.bitmap_cache_bytes.saturating_add(needed) > MAX_BITMAP_CACHE_BYTES {
            let Some((&first_key, _)) = self.bitmap_cache.iter().next() else {
                break;
            };
            if let Some(evicted) = self.bitmap_cache.remove(&first_key) {
                self.bitmap_cache_bytes = self.bitmap_cache_bytes.saturating_sub(evicted.rgba.len());
            }
        }
        self.bitmap_cache_bytes += needed;
        self.bitmap_cache
            .insert((cache_id, cache_index), CachedBitmap { width, height, rgba });
    }

    fn handle_cache_glyph_rev1(&mut self, src: &mut ReadCursor<'_>) {
        if src.len() < 2 {
            return;
        }
        let cache_id = src.read_u8();
        let count = src.read_u8();
        for _ in 0..count {
            if src.len() < 10 {
                return;
            }
            let cache_index = src.read_u16();
            let x = src.read_i16();
            let y = src.read_i16();
            let cx = src.read_u16();
            let cy = src.read_u16();
            let raw_bytes = usize::from(cx).div_ceil(8).saturating_mul(usize::from(cy));
            let padded = (raw_bytes + 3) & !3;
            if padded > src.len() {
                return;
            }
            let bytes = src.read_slice(padded);
            self.store_glyph(
                cache_id,
                cache_index,
                CachedGlyph {
                    x,
                    y,
                    cx,
                    cy,
                    data: bytes[..raw_bytes].to_vec(),
                },
            );
        }
    }

    fn handle_cache_glyph_rev2(&mut self, extra_flags: u16, src: &mut ReadCursor<'_>) {
        let cache_id = (extra_flags & 0x000F) as u8;
        let count = (extra_flags >> 8) as u8;
        for _ in 0..count {
            if src.is_empty() {
                return;
            }
            let cache_index = u16::from(src.read_u8());
            let Some(glyph) = read_glyph_data_rev2(src) else {
                return;
            };
            self.store_glyph(cache_id, cache_index, glyph);
        }
    }

    fn store_glyph(&mut self, cache_id: u8, cache_index: u16, glyph: CachedGlyph) {
        if let Some(old) = self.glyph_cache.remove(&(cache_id, cache_index)) {
            self.glyph_cache_bytes = self.glyph_cache_bytes.saturating_sub(old.data.len());
        }
        let needed = glyph.data.len();
        if needed > MAX_GLYPH_CACHE_BYTES {
            return;
        }
        while self.glyph_cache_bytes.saturating_add(needed) > MAX_GLYPH_CACHE_BYTES {
            let Some((&first_key, _)) = self.glyph_cache.iter().next() else {
                break;
            };
            if let Some(evicted) = self.glyph_cache.remove(&first_key) {
                self.glyph_cache_bytes = self.glyph_cache_bytes.saturating_sub(evicted.data.len());
            }
        }
        self.glyph_cache_bytes += needed;
        self.glyph_cache.insert((cache_id, cache_index), glyph);
    }

    // ========================================================================
    // Primary Drawing Orders
    // ========================================================================

    fn process_primary_order(
        &mut self,
        control_flags: u8,
        src: &mut ReadCursor<'_>,
        image: &mut DecodedImage,
        damage: &mut Vec<InclusiveRectangle>,
    ) -> bool {
        if (control_flags & TS_TYPE_CHANGE) != 0 {
            if src.is_empty() {
                return false;
            }
            self.order_type = src.read_u8();
        }
        let Some(total_field_bytes) = field_flag_bytes(self.order_type) else {
            debug!(order_type = self.order_type, "Unsupported GDI primary order");
            return false;
        };
        let zero_bytes = usize::from((control_flags & (TS_ZERO_FIELD_BYTE_BIT0 | TS_ZERO_FIELD_BYTE_BIT1)) >> 6);
        let present_bytes = total_field_bytes.saturating_sub(zero_bytes);
        if src.len() < present_bytes {
            return false;
        }
        let mut field_flags = 0u32;
        for byte_idx in 0..present_bytes {
            field_flags |= u32::from(src.read_u8()) << (byte_idx * 8);
        }

        let clip = if (control_flags & TS_BOUNDS) != 0 {
            if (control_flags & TS_ZERO_BOUNDS_DELTAS) == 0 && !read_bounds(src, &mut self.bounds) {
                return false;
            }
            Some(self.bounds)
        } else {
            None
        };
        let delta = (control_flags & TS_DELTA_COORDINATES) != 0;

        match self.order_type {
            ORDER_DSTBLT => {
                if !decode_dstblt(src, field_flags, delta, &mut self.dstblt) {
                    return false;
                }
                let (x, y, w, h, rop) = (
                    self.dstblt.left,
                    self.dstblt.top,
                    self.dstblt.width,
                    self.dstblt.height,
                    self.dstblt.rop,
                );
                self.with_target(image, damage, |pixels, tw, th| {
                    draw_solid_rop(pixels, tw, th, x, y, w, h, [0, 0, 0], rop, clip)
                });
            }
            ORDER_PATBLT => {
                if !decode_patblt(src, field_flags, delta, &mut self.patblt) {
                    return false;
                }
                let (x, y, w, h, rop, color) = (
                    self.patblt.left,
                    self.patblt.top,
                    self.patblt.width,
                    self.patblt.height,
                    self.patblt.rop,
                    self.patblt.fore_color,
                );
                self.with_target(image, damage, |pixels, tw, th| {
                    draw_solid_rop(pixels, tw, th, x, y, w, h, color, rop, clip)
                });
            }
            ORDER_SCRBLT => {
                if !decode_scrblt(src, field_flags, delta, &mut self.scrblt) {
                    return false;
                }
                let (dx, dy, w, h, sx, sy, rop) = (
                    self.scrblt.left,
                    self.scrblt.top,
                    self.scrblt.width,
                    self.scrblt.height,
                    self.scrblt.src_x,
                    self.scrblt.src_y,
                    self.scrblt.rop,
                );
                self.with_target(image, damage, |pixels, tw, th| {
                    draw_scrblt(pixels, tw, th, dx, dy, w, h, sx, sy, rop, clip)
                });
            }
            ORDER_OPAQUERECT => {
                if !decode_opaque_rect(src, field_flags, delta, &mut self.opaque_rect) {
                    return false;
                }
                let (x, y, w, h, color) = (
                    self.opaque_rect.left,
                    self.opaque_rect.top,
                    self.opaque_rect.width,
                    self.opaque_rect.height,
                    self.opaque_rect.color,
                );
                self.with_target(image, damage, |pixels, tw, th| {
                    draw_solid_rop(pixels, tw, th, x, y, w, h, color, 0xF0, clip)
                });
            }
            ORDER_MULTIOPAQUERECT => {
                if !decode_multi_opaque_rect(src, field_flags, delta, &mut self.multi_opaque_rect) {
                    return false;
                }
                let color = self.multi_opaque_rect.color;
                let rects = decode_delta_rects(
                    self.multi_opaque_rect.delta_entries,
                    &self.multi_opaque_rect.coded_deltas,
                );
                self.with_target(image, damage, |pixels, tw, th| {
                    let mut union: Option<InclusiveRectangle> = None;
                    for (rx, ry, rw, rh) in rects {
                        if let Some(d) = draw_solid_rop(pixels, tw, th, rx, ry, rw, rh, color, 0xF0, clip) {
                            union = Some(match union {
                                Some(u) => u.union(&d),
                                None => d,
                            });
                        }
                    }
                    union
                });
            }
            ORDER_MEMBLT => {
                if !decode_memblt(src, field_flags, delta, &mut self.memblt) {
                    return false;
                }
                let cache_id = (self.memblt.cache_id & 0x00FF) as u8;
                let cache_index = self.memblt.cache_index;
                let (dx, dy, w, h, sx, sy, rop) = (
                    self.memblt.left,
                    self.memblt.top,
                    self.memblt.width,
                    self.memblt.height,
                    self.memblt.src_x,
                    self.memblt.src_y,
                    self.memblt.rop,
                );
                // cacheId == 0xFF selects the OffscreenBitmapCache surface identified by cacheIndex.
                let source = if cache_id == 0xFF {
                    self.offscreen
                        .get(&cache_index)
                        .map(|s| (s.width, s.height, s.rgba.clone()))
                } else {
                    self.bitmap_cache
                        .get(&(cache_id, cache_index))
                        .map(|b| (b.width, b.height, b.rgba.clone()))
                };
                if let Some((sw, sh, srgba)) = source {
                    self.with_target(image, damage, |pixels, tw, th| {
                        draw_memblt(pixels, tw, th, dx, dy, w, h, &srgba, sw, sh, sx, sy, rop, clip)
                    });
                }
            }
            ORDER_FAST_INDEX => {
                if !decode_fast_index(src, field_flags, delta, &mut self.fast_index) {
                    return false;
                }
                let cache_id = self.fast_index.cache_id;
                let ul_char_inc = (self.fast_index.f_drawing & 0x00FF) as u8;
                let fl_accel = (self.fast_index.f_drawing >> 8) as u8;
                let back_color = self.fast_index.back_color;
                let fore_color = self.fast_index.fore_color;
                let bk = (
                    self.fast_index.bk_left,
                    self.fast_index.bk_top,
                    self.fast_index.bk_right,
                    self.fast_index.bk_bottom,
                );
                let op = (
                    self.fast_index.op_left,
                    self.fast_index.op_top,
                    self.fast_index.op_right,
                    self.fast_index.op_bottom,
                );
                let origin = (self.fast_index.x, self.fast_index.y);
                let data = self.fast_index.data.clone();
                self.render_glyph_stream(
                    image,
                    damage,
                    cache_id,
                    fl_accel,
                    ul_char_inc,
                    fore_color,
                    back_color,
                    bk,
                    op,
                    origin,
                    &data,
                    clip,
                );
            }
            ORDER_FAST_GLYPH => {
                if !decode_fast_glyph(src, field_flags, delta, &mut self.fast_glyph) {
                    return false;
                }
                let cache_id = self.fast_glyph.cache_id;
                let fl_accel = (self.fast_glyph.f_drawing >> 8) as u8;
                let back_color = self.fast_glyph.back_color;
                let fore_color = self.fast_glyph.fore_color;
                let bk = (
                    self.fast_glyph.bk_left,
                    self.fast_glyph.bk_top,
                    self.fast_glyph.bk_right,
                    self.fast_glyph.bk_bottom,
                );
                let op = (
                    self.fast_glyph.op_left,
                    self.fast_glyph.op_top,
                    self.fast_glyph.op_right,
                    self.fast_glyph.op_bottom,
                );
                let origin = (self.fast_glyph.x, self.fast_glyph.y);
                let data = self.fast_glyph.data.clone();
                if !data.is_empty() {
                    let glyph_idx = u16::from(data[0]);
                    if data.len() > 1 {
                        let mut gcur = ReadCursor::new(&data[1..]);
                        if let Some(glyph) = read_glyph_data_rev2(&mut gcur) {
                            self.store_glyph(cache_id, glyph_idx, glyph);
                        }
                    }
                    let single = [data[0], 0u8];
                    self.render_glyph_stream(
                        image,
                        damage,
                        cache_id,
                        fl_accel,
                        0,
                        fore_color,
                        back_color,
                        bk,
                        op,
                        origin,
                        &single[..1],
                        clip,
                    );
                }
            }
            ORDER_GLYPH_INDEX => {
                if !decode_glyph_index(src, field_flags, delta, &mut self.glyph_index) {
                    return false;
                }
                let cache_id = self.glyph_index.cache_id;
                let fl_accel = self.glyph_index.fl_accel;
                let ul_char_inc = self.glyph_index.ul_char_inc;
                let back_color = self.glyph_index.back_color;
                let fore_color = self.glyph_index.fore_color;
                let bk = (
                    self.glyph_index.bk_left,
                    self.glyph_index.bk_top,
                    self.glyph_index.bk_right,
                    self.glyph_index.bk_bottom,
                );
                let op = (
                    self.glyph_index.op_left,
                    self.glyph_index.op_top,
                    self.glyph_index.op_right,
                    self.glyph_index.op_bottom,
                );
                let origin = (self.glyph_index.x, self.glyph_index.y);
                let data = self.glyph_index.data.clone();
                self.render_glyph_stream(
                    image,
                    damage,
                    cache_id,
                    fl_accel,
                    ul_char_inc,
                    fore_color,
                    back_color,
                    bk,
                    op,
                    origin,
                    &data,
                    clip,
                );
            }
            _ => return false,
        }

        true
    }

    #[expect(clippy::too_many_arguments)]
    fn render_glyph_stream(
        &mut self,
        image: &mut DecodedImage,
        damage: &mut Vec<InclusiveRectangle>,
        cache_id: u8,
        fl_accel: u8,
        ul_char_inc: u8,
        fore_color: [u8; 3],
        back_color: [u8; 3],
        bk: (i16, i16, i16, i16),
        op: (i16, i16, i16, i16),
        origin: (i16, i16),
        data: &[u8],
        clip: Option<ClipBounds>,
    ) {
        // Resolve fragments first and expand glyph draw commands: (glyph_index, x, y).
        let (mut pen_x, mut pen_y) = (i32::from(origin.0), i32::from(origin.1));
        if pen_x == 0 && pen_y == 0 {
            pen_x = i32::from(bk.0);
            pen_y = i32::from(bk.1);
        }
        let vertical = (fl_accel & 0x04) != 0;
        let mut draws: Vec<(u16, i32, i32)> = Vec::new();
        let mut idx = 0usize;
        while idx < data.len() {
            let op_byte = data[idx];
            idx += 1;
            match op_byte {
                0xFE => {
                    // Use glyph fragment from frag_cache
                    if idx >= data.len() {
                        break;
                    }
                    let frag_idx = data[idx];
                    idx += 1;
                    let delta = if ul_char_inc == 0 {
                        let Some(d) = read_glyph_delta(data, &mut idx) else {
                            break;
                        };
                        d
                    } else {
                        0
                    };
                    if vertical {
                        pen_y += delta;
                    } else {
                        pen_x += delta;
                    }
                    if let Some(frag) = self.frag_cache.get(&frag_idx).cloned() {
                        expand_glyph_entries(&frag, ul_char_inc, vertical, &mut pen_x, &mut pen_y, &mut draws);
                    }
                }
                0xFF => {
                    // Store preceding bytes as fragment in frag_cache
                    if idx + 1 >= data.len() {
                        break;
                    }
                    let frag_idx = data[idx];
                    let frag_len = usize::from(data[idx + 1]);
                    idx += 2;
                    let start = idx.saturating_sub(frag_len + 3);
                    let end = idx.saturating_sub(3);
                    if start <= end && end <= data.len() && frag_len <= 256 {
                        self.frag_cache.insert(frag_idx, data[start..end].to_vec());
                    }
                }
                glyph_idx => {
                    draws.push((u16::from(glyph_idx), pen_x, pen_y));
                    if ul_char_inc != 0 {
                        if vertical {
                            pen_y += i32::from(ul_char_inc);
                        } else {
                            pen_x += i32::from(ul_char_inc);
                        }
                    } else if idx < data.len() {
                        if let Some(d) = read_glyph_delta(data, &mut idx) {
                            if vertical {
                                pen_y += d;
                            } else {
                                pen_x += d;
                            }
                        }
                    }
                }
            }
        }

        // Snapshot glyphs needed so we can mutably borrow target surface.
        let resolved: Vec<(CachedGlyph, i32, i32)> = draws
            .into_iter()
            .filter_map(|(gi, gx, gy)| {
                self.glyph_cache
                    .get(&(cache_id, gi))
                    .cloned()
                    .map(|g| (g, gx, gy))
            })
            .collect();

        // MS-RDPEGDI 2.2.2.2.1.1.2.13: if opRight > opLeft and opBottom > opTop, fill opRect with backColor.
        // Note: on the wire, backColor in GlyphIndex/FastIndex/FastGlyph is the FOREGROUND glyph color
        // and foreColor is the BACKGROUND fill color (famous MS-RDPEGDI inverted naming!).
        // Specifically per MS-RDPEGDI 2.2.2.2.1.1.2.13:
        //   backColor = text (glyph foreground) color
        //   foreColor = opaque rectangle (background) color
        let glyph_color = back_color;
        let bg_color = fore_color;

        self.with_target(image, damage, |pixels, tw, th| {
            let mut union: Option<InclusiveRectangle> = None;
            let op_rect = if op.2 > op.0 && op.3 > op.1 {
                Some(op)
            } else if op.2 == 0 && op.0 == 0 && op.3 == 0 && op.1 == 0 {
                None
            } else {
                None
            };
            if let Some((ol, ot, or_, ob)) = op_rect {
                if let Some(d) = draw_solid_rop(
                    pixels,
                    tw,
                    th,
                    ol,
                    ot,
                    or_.saturating_sub(ol),
                    ob.saturating_sub(ot),
                    bg_color,
                    0xF0,
                    clip,
                ) {
                    union = Some(d);
                }
            }
            for (glyph, gx, gy) in &resolved {
                if let Some(d) = draw_mono_glyph(pixels, tw, th, glyph, *gx, *gy, glyph_color, clip) {
                    union = Some(match union {
                        Some(u) => u.union(&d),
                        None => d,
                    });
                }
            }
            union
        });
    }

    fn with_target<F>(&mut self, image: &mut DecodedImage, damage: &mut Vec<InclusiveRectangle>, draw: F)
    where
        F: FnOnce(&mut [u8], u16, u16) -> Option<InclusiveRectangle>,
    {
        if let Some(offscreen_id) = self.active_offscreen {
            if let Some(surface) = self.offscreen.get_mut(&offscreen_id) {
                let _ = draw(&mut surface.rgba, surface.width, surface.height);
            }
            return;
        }
        if let Ok(Some(Some(rect))) = image.with_rgba32_surface(draw) {
            damage.push(rect);
        }
    }
}

// ============================================================================
// Wire-format helpers
// ============================================================================

fn field_flag_bytes(order_type: u8) -> Option<usize> {
    match order_type {
        ORDER_DSTBLT | ORDER_SCRBLT | ORDER_OPAQUERECT | ORDER_MULTIOPAQUERECT => Some(1),
        ORDER_PATBLT | ORDER_MEMBLT | ORDER_FAST_INDEX | ORDER_FAST_GLYPH => Some(2),
        ORDER_GLYPH_INDEX => Some(3),
        _ => None,
    }
}

fn read_coord(src: &mut ReadCursor<'_>, delta: bool, current: &mut i16) -> bool {
    if delta {
        if src.is_empty() {
            return false;
        }
        *current = current.wrapping_add(i16::from(src.read_u8() as i8));
    } else {
        if src.len() < 2 {
            return false;
        }
        *current = src.read_i16();
    }
    true
}

fn read_color3(src: &mut ReadCursor<'_>) -> Option<[u8; 3]> {
    if src.len() < 3 {
        return None;
    }
    Some([src.read_u8(), src.read_u8(), src.read_u8()])
}

fn read_bounds(src: &mut ReadCursor<'_>, bounds: &mut ClipBounds) -> bool {
    if src.is_empty() {
        return false;
    }
    let flags = src.read_u8();
    let fields: [(&mut i16, u8, u8); 4] = [
        (&mut bounds.left, 0x01, 0x10),
        (&mut bounds.right, 0x02, 0x20),
        (&mut bounds.top, 0x04, 0x40),
        (&mut bounds.bottom, 0x08, 0x80),
    ];
    for (field, abs_bit, delta_bit) in fields {
        if (flags & abs_bit) != 0 {
            if src.len() < 2 {
                return false;
            }
            *field = src.read_i16();
        } else if (flags & delta_bit) != 0 {
            if src.is_empty() {
                return false;
            }
            *field = field.wrapping_add(i16::from(src.read_u8() as i8));
        }
    }
    true
}

fn read_2byte_unsigned(src: &mut ReadCursor<'_>) -> Option<u16> {
    if src.is_empty() {
        return None;
    }
    let b0 = src.read_u8();
    if (b0 & 0x80) != 0 {
        if src.is_empty() {
            return None;
        }
        let b1 = src.read_u8();
        Some((u16::from(b0 & 0x7F) << 8) | u16::from(b1))
    } else {
        Some(u16::from(b0))
    }
}

fn read_2byte_signed(src: &mut ReadCursor<'_>) -> Option<i16> {
    if src.is_empty() {
        return None;
    }
    let b0 = src.read_u8();
    let negative = (b0 & 0x40) != 0;
    let mag = if (b0 & 0x80) != 0 {
        if src.is_empty() {
            return None;
        }
        let b1 = src.read_u8();
        ((i16::from(b0 & 0x3F)) << 8) | i16::from(b1)
    } else {
        i16::from(b0 & 0x3F)
    };
    Some(if negative { -mag } else { mag })
}

fn read_4byte_unsigned(src: &mut ReadCursor<'_>) -> Option<u32> {
    if src.is_empty() {
        return None;
    }
    let b0 = src.read_u8();
    let count = (b0 >> 6) & 0x03;
    let mut val = u32::from(b0 & 0x3F);
    if src.len() < usize::from(count) {
        return None;
    }
    for _ in 0..count {
        val = (val << 8) | u32::from(src.read_u8());
    }
    Some(val)
}

fn read_glyph_data_rev2(src: &mut ReadCursor<'_>) -> Option<CachedGlyph> {
    let x = read_2byte_signed(src)?;
    let y = read_2byte_signed(src)?;
    let cx = read_2byte_unsigned(src)?;
    let cy = read_2byte_unsigned(src)?;
    let bytes = usize::from(cx).div_ceil(8).saturating_mul(usize::from(cy));
    if bytes > src.len() || bytes > 65536 {
        return None;
    }
    let data = src.read_slice(bytes).to_vec();
    Some(CachedGlyph { x, y, cx, cy, data })
}

fn read_glyph_delta(data: &[u8], idx: &mut usize) -> Option<i32> {
    let b = *data.get(*idx)?;
    *idx += 1;
    if b == 0x80 {
        let lo = *data.get(*idx)?;
        let hi = *data.get(*idx + 1)?;
        *idx += 2;
        Some(i32::from(i16::from_le_bytes([lo, hi])))
    } else {
        Some(i32::from(b))
    }
}

fn expand_glyph_entries(
    frag: &[u8],
    ul_char_inc: u8,
    vertical: bool,
    pen_x: &mut i32,
    pen_y: &mut i32,
    draws: &mut Vec<(u16, i32, i32)>,
) {
    let mut i = 0usize;
    while i < frag.len() {
        let gi = frag[i];
        i += 1;
        draws.push((u16::from(gi), *pen_x, *pen_y));
        if ul_char_inc != 0 {
            if vertical {
                *pen_y += i32::from(ul_char_inc);
            } else {
                *pen_x += i32::from(ul_char_inc);
            }
        } else if i < frag.len() {
            if let Some(d) = read_glyph_delta(frag, &mut i) {
                if vertical {
                    *pen_y += d;
                } else {
                    *pen_x += d;
                }
            }
        }
    }
}

fn read_delta_coord(src: &mut ReadCursor<'_>, zero: bool) -> Option<i16> {
    if zero {
        return Some(0);
    }
    if src.is_empty() {
        return None;
    }
    let b0 = src.read_u8();
    if (b0 & 0x80) != 0 {
        if src.is_empty() {
            return None;
        }
        let b1 = src.read_u8();
        let raw = (u16::from(b0 & 0x7F) << 8) | u16::from(b1);
        // Sign-extend 15-bit value
        let signed = if (raw & 0x4000) != 0 {
            (raw | 0x8000) as i16
        } else {
            raw as i16
        };
        Some(signed)
    } else {
        let signed = if (b0 & 0x40) != 0 {
            (b0 | 0x80) as i8
        } else {
            b0 as i8
        };
        Some(i16::from(signed))
    }
}

fn decode_delta_rects(count: u8, bytes: &[u8]) -> Vec<(i16, i16, i16, i16)> {
    let count = usize::from(count);
    let zero_bytes_len = count.div_ceil(2);
    if count == 0 || bytes.len() < zero_bytes_len {
        return Vec::new();
    }
    let zero_bits = &bytes[..zero_bytes_len];
    let mut src = ReadCursor::new(&bytes[zero_bytes_len..]);
    let mut rects = Vec::with_capacity(count);
    let (mut x, mut y, mut w, mut h) = (0i16, 0i16, 0i16, 0i16);
    for i in 0..count {
        let nibble = if i % 2 == 0 {
            zero_bits[i / 2] >> 4
        } else {
            zero_bits[i / 2] & 0x0F
        };
        let Some(dx) = read_delta_coord(&mut src, (nibble & 0x08) != 0) else {
            break;
        };
        let Some(dy) = read_delta_coord(&mut src, (nibble & 0x04) != 0) else {
            break;
        };
        let Some(dw) = read_delta_coord(&mut src, (nibble & 0x02) != 0) else {
            break;
        };
        let Some(dh) = read_delta_coord(&mut src, (nibble & 0x01) != 0) else {
            break;
        };
        x = x.wrapping_add(dx);
        y = y.wrapping_add(dy);
        w = w.wrapping_add(dw);
        h = h.wrapping_add(dh);
        rects.push((x, y, w, h));
    }
    rects
}

// ============================================================================
// Primary Order Decoders
// ============================================================================

fn decode_dstblt(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut DstBltState) -> bool {
    if (f & 0x01) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x02) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x04) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x08) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x10) != 0 {
        if src.is_empty() {
            return false;
        }
        s.rop = src.read_u8();
    }
    true
}

fn decode_patblt(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut PatBltState) -> bool {
    if (f & 0x0001) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x0002) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x0004) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x0008) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x0010) != 0 {
        if src.is_empty() {
            return false;
        }
        s.rop = src.read_u8();
    }
    if (f & 0x0020) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.back_color = c;
    }
    if (f & 0x0040) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.fore_color = c;
    }
    if (f & 0x0080) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_org_x = src.read_u8() as i8;
    }
    if (f & 0x0100) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_org_y = src.read_u8() as i8;
    }
    if (f & 0x0200) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_style = src.read_u8();
    }
    if (f & 0x0400) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_hatch = src.read_u8();
    }
    if (f & 0x0800) != 0 {
        if src.len() < 7 {
            return false;
        }
        s.brush_extra.copy_from_slice(src.read_slice(7));
    }
    true
}

fn decode_scrblt(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut ScrBltState) -> bool {
    if (f & 0x01) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x02) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x04) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x08) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x10) != 0 {
        if src.is_empty() {
            return false;
        }
        s.rop = src.read_u8();
    }
    if (f & 0x20) != 0 && !read_coord(src, delta, &mut s.src_x) {
        return false;
    }
    if (f & 0x40) != 0 && !read_coord(src, delta, &mut s.src_y) {
        return false;
    }
    true
}

fn decode_opaque_rect(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut OpaqueRectState) -> bool {
    if (f & 0x01) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x02) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x04) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x08) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x10) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[0] = src.read_u8();
    }
    if (f & 0x20) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[1] = src.read_u8();
    }
    if (f & 0x40) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[2] = src.read_u8();
    }
    true
}

fn decode_multi_opaque_rect(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut MultiOpaqueRectState) -> bool {
    if (f & 0x01) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x02) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x04) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x08) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x10) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[0] = src.read_u8();
    }
    if (f & 0x20) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[1] = src.read_u8();
    }
    if (f & 0x40) != 0 {
        if src.is_empty() {
            return false;
        }
        s.color[2] = src.read_u8();
    }
    if (f & 0x80) != 0 {
        if src.len() < 3 {
            return false;
        }
        s.delta_entries = src.read_u8();
        let data_len = usize::from(src.read_u16());
        if data_len > src.len() {
            return false;
        }
        s.coded_deltas = src.read_slice(data_len).to_vec();
    }
    true
}

fn decode_memblt(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut MemBltState) -> bool {
    if (f & 0x0001) != 0 {
        if src.len() < 2 {
            return false;
        }
        s.cache_id = src.read_u16();
    }
    if (f & 0x0002) != 0 && !read_coord(src, delta, &mut s.left) {
        return false;
    }
    if (f & 0x0004) != 0 && !read_coord(src, delta, &mut s.top) {
        return false;
    }
    if (f & 0x0008) != 0 && !read_coord(src, delta, &mut s.width) {
        return false;
    }
    if (f & 0x0010) != 0 && !read_coord(src, delta, &mut s.height) {
        return false;
    }
    if (f & 0x0020) != 0 {
        if src.is_empty() {
            return false;
        }
        s.rop = src.read_u8();
    }
    if (f & 0x0040) != 0 && !read_coord(src, delta, &mut s.src_x) {
        return false;
    }
    if (f & 0x0080) != 0 && !read_coord(src, delta, &mut s.src_y) {
        return false;
    }
    if (f & 0x0100) != 0 {
        if src.len() < 2 {
            return false;
        }
        s.cache_index = src.read_u16();
    }
    true
}

fn decode_fast_index(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut FastIndexState) -> bool {
    if (f & 0x0001) != 0 {
        if src.is_empty() {
            return false;
        }
        s.cache_id = src.read_u8();
    }
    if (f & 0x0002) != 0 {
        if src.len() < 2 {
            return false;
        }
        s.f_drawing = src.read_u16();
    }
    if (f & 0x0004) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.back_color = c;
    }
    if (f & 0x0008) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.fore_color = c;
    }
    if (f & 0x0010) != 0 && !read_coord(src, delta, &mut s.bk_left) {
        return false;
    }
    if (f & 0x0020) != 0 && !read_coord(src, delta, &mut s.bk_top) {
        return false;
    }
    if (f & 0x0040) != 0 && !read_coord(src, delta, &mut s.bk_right) {
        return false;
    }
    if (f & 0x0080) != 0 && !read_coord(src, delta, &mut s.bk_bottom) {
        return false;
    }
    if (f & 0x0100) != 0 && !read_coord(src, delta, &mut s.op_left) {
        return false;
    }
    if (f & 0x0200) != 0 && !read_coord(src, delta, &mut s.op_top) {
        return false;
    }
    if (f & 0x0400) != 0 && !read_coord(src, delta, &mut s.op_right) {
        return false;
    }
    if (f & 0x0800) != 0 && !read_coord(src, delta, &mut s.op_bottom) {
        return false;
    }
    if (f & 0x1000) != 0 && !read_coord(src, delta, &mut s.x) {
        return false;
    }
    if (f & 0x2000) != 0 && !read_coord(src, delta, &mut s.y) {
        return false;
    }
    if (f & 0x4000) != 0 {
        if src.is_empty() {
            return false;
        }
        let len = usize::from(src.read_u8());
        if len > src.len() {
            return false;
        }
        s.data = src.read_slice(len).to_vec();
    }
    true
}

fn decode_fast_glyph(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut FastGlyphState) -> bool {
    if (f & 0x0001) != 0 {
        if src.is_empty() {
            return false;
        }
        s.cache_id = src.read_u8();
    }
    if (f & 0x0002) != 0 {
        if src.len() < 2 {
            return false;
        }
        s.f_drawing = src.read_u16();
    }
    if (f & 0x0004) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.back_color = c;
    }
    if (f & 0x0008) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.fore_color = c;
    }
    if (f & 0x0010) != 0 && !read_coord(src, delta, &mut s.bk_left) {
        return false;
    }
    if (f & 0x0020) != 0 && !read_coord(src, delta, &mut s.bk_top) {
        return false;
    }
    if (f & 0x0040) != 0 && !read_coord(src, delta, &mut s.bk_right) {
        return false;
    }
    if (f & 0x0080) != 0 && !read_coord(src, delta, &mut s.bk_bottom) {
        return false;
    }
    if (f & 0x0100) != 0 && !read_coord(src, delta, &mut s.op_left) {
        return false;
    }
    if (f & 0x0200) != 0 && !read_coord(src, delta, &mut s.op_top) {
        return false;
    }
    if (f & 0x0400) != 0 && !read_coord(src, delta, &mut s.op_right) {
        return false;
    }
    if (f & 0x0800) != 0 && !read_coord(src, delta, &mut s.op_bottom) {
        return false;
    }
    if (f & 0x1000) != 0 && !read_coord(src, delta, &mut s.x) {
        return false;
    }
    if (f & 0x2000) != 0 && !read_coord(src, delta, &mut s.y) {
        return false;
    }
    if (f & 0x4000) != 0 {
        if src.is_empty() {
            return false;
        }
        let len = usize::from(src.read_u8());
        if len > src.len() {
            return false;
        }
        s.data = src.read_slice(len).to_vec();
    }
    true
}

fn decode_glyph_index(src: &mut ReadCursor<'_>, f: u32, delta: bool, s: &mut GlyphIndexState) -> bool {
    if (f & 0x00_0001) != 0 {
        if src.is_empty() {
            return false;
        }
        s.cache_id = src.read_u8();
    }
    if (f & 0x00_0002) != 0 {
        if src.is_empty() {
            return false;
        }
        s.fl_accel = src.read_u8();
    }
    if (f & 0x00_0004) != 0 {
        if src.is_empty() {
            return false;
        }
        s.ul_char_inc = src.read_u8();
    }
    if (f & 0x00_0008) != 0 {
        if src.is_empty() {
            return false;
        }
        s.f_op_redundant = src.read_u8();
    }
    if (f & 0x00_0010) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.back_color = c;
    }
    if (f & 0x00_0020) != 0 {
        let Some(c) = read_color3(src) else { return false };
        s.fore_color = c;
    }
    if (f & 0x00_0040) != 0 && !read_coord(src, delta, &mut s.bk_left) {
        return false;
    }
    if (f & 0x00_0080) != 0 && !read_coord(src, delta, &mut s.bk_top) {
        return false;
    }
    if (f & 0x00_0100) != 0 && !read_coord(src, delta, &mut s.bk_right) {
        return false;
    }
    if (f & 0x00_0200) != 0 && !read_coord(src, delta, &mut s.bk_bottom) {
        return false;
    }
    if (f & 0x00_0400) != 0 && !read_coord(src, delta, &mut s.op_left) {
        return false;
    }
    if (f & 0x00_0800) != 0 && !read_coord(src, delta, &mut s.op_top) {
        return false;
    }
    if (f & 0x00_1000) != 0 && !read_coord(src, delta, &mut s.op_right) {
        return false;
    }
    if (f & 0x00_2000) != 0 && !read_coord(src, delta, &mut s.op_bottom) {
        return false;
    }
    if (f & 0x00_4000) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_org_x = src.read_u8() as i8;
    }
    if (f & 0x00_8000) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_org_y = src.read_u8() as i8;
    }
    if (f & 0x01_0000) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_style = src.read_u8();
    }
    if (f & 0x02_0000) != 0 {
        if src.is_empty() {
            return false;
        }
        s.brush_hatch = src.read_u8();
    }
    if (f & 0x04_0000) != 0 {
        if src.len() < 7 {
            return false;
        }
        s.brush_extra.copy_from_slice(src.read_slice(7));
    }
    if (f & 0x08_0000) != 0 && !read_coord(src, delta, &mut s.x) {
        return false;
    }
    if (f & 0x10_0000) != 0 && !read_coord(src, delta, &mut s.y) {
        return false;
    }
    if (f & 0x20_0000) != 0 {
        if src.is_empty() {
            return false;
        }
        let len = usize::from(src.read_u8());
        if len > src.len() {
            return false;
        }
        s.data = src.read_slice(len).to_vec();
    }
    true
}

// ============================================================================
// Rasterization & ROP3 Helpers
// ============================================================================

#[inline]
fn rop3_byte(rop: u8, dst: u8, src: u8, pat: u8) -> u8 {
    match rop {
        0x00 => 0x00,            // BLACKNESS
        0xFF => 0xFF,            // WHITENESS
        0xCC => src,             // SRCCOPY
        0xF0 => pat,             // PATCOPY
        0x55 => !dst,            // DSTINVERT
        0xAA => dst,             // NOP
        0x33 => !src,            // NOTSRCCOPY
        0x0F => !pat,            // NOTPATCOPY
        0x66 => src ^ dst,       // SRCINVERT
        0x5A => pat ^ dst,       // PATINVERT
        0x88 => src & dst,       // SRCAND
        0xEE => src | dst,       // SRCPAINT
        _ => {
            // Exact bitwise truth-table evaluation for all 256 GDI ROP3 codes.
            let mut out = 0u8;
            let p = pat;
            let s = src;
            let d = dst;
            if (rop & 0x01) != 0 {
                out |= !p & !s & !d;
            }
            if (rop & 0x02) != 0 {
                out |= !p & !s & d;
            }
            if (rop & 0x04) != 0 {
                out |= !p & s & !d;
            }
            if (rop & 0x08) != 0 {
                out |= !p & s & d;
            }
            if (rop & 0x10) != 0 {
                out |= p & !s & !d;
            }
            if (rop & 0x20) != 0 {
                out |= p & !s & d;
            }
            if (rop & 0x40) != 0 {
                out |= p & s & !d;
            }
            if (rop & 0x80) != 0 {
                out |= p & s & d;
            }
            out
        }
    }
}

fn clip_rect(
    x: i16,
    y: i16,
    w: i16,
    h: i16,
    target_w: u16,
    target_h: u16,
    clip: Option<ClipBounds>,
) -> Option<(usize, usize, usize, usize)> {
    if w <= 0 || h <= 0 || target_w == 0 || target_h == 0 {
        return None;
    }
    let mut left = i32::from(x);
    let mut top = i32::from(y);
    let mut right = left + i32::from(w);
    let mut bottom = top + i32::from(h);
    if let Some(b) = clip {
        left = left.max(i32::from(b.left));
        top = top.max(i32::from(b.top));
        right = right.min(i32::from(b.right) + 1);
        bottom = bottom.min(i32::from(b.bottom) + 1);
    }
    left = left.max(0);
    top = top.max(0);
    right = right.min(i32::from(target_w));
    bottom = bottom.min(i32::from(target_h));
    if left >= right || top >= bottom {
        return None;
    }
    Some((left as usize, top as usize, right as usize, bottom as usize))
}

#[expect(clippy::too_many_arguments)]
fn draw_solid_rop(
    pixels: &mut [u8],
    tw: u16,
    th: u16,
    x: i16,
    y: i16,
    w: i16,
    h: i16,
    pat: [u8; 3],
    rop: u8,
    clip: Option<ClipBounds>,
) -> Option<InclusiveRectangle> {
    let (left, top, right, bottom) = clip_rect(x, y, w, h, tw, th, clip)?;
    let stride = usize::from(tw) * 4;
    for row in top..bottom {
        let base = row * stride;
        for col in left..right {
            let off = base + col * 4;
            if rop == 0xF0 {
                pixels[off] = pat[0];
                pixels[off + 1] = pat[1];
                pixels[off + 2] = pat[2];
                pixels[off + 3] = 255;
            } else {
                pixels[off] = rop3_byte(rop, pixels[off], 0, pat[0]);
                pixels[off + 1] = rop3_byte(rop, pixels[off + 1], 0, pat[1]);
                pixels[off + 2] = rop3_byte(rop, pixels[off + 2], 0, pat[2]);
                pixels[off + 3] = 255;
            }
        }
    }
    Some(InclusiveRectangle {
        left: left as u16,
        top: top as u16,
        right: (right - 1) as u16,
        bottom: (bottom - 1) as u16,
    })
}

#[expect(clippy::too_many_arguments)]
fn draw_scrblt(
    pixels: &mut [u8],
    tw: u16,
    th: u16,
    dx: i16,
    dy: i16,
    w: i16,
    h: i16,
    sx: i16,
    sy: i16,
    rop: u8,
    clip: Option<ClipBounds>,
) -> Option<InclusiveRectangle> {
    let (left, top, right, bottom) = clip_rect(dx, dy, w, h, tw, th, clip)?;
    let dx0 = i32::from(dx);
    let dy0 = i32::from(dy);
    let sx0 = i32::from(sx);
    let sy0 = i32::from(sy);
    let cw = right - left;
    let ch = bottom - top;
    let stride = usize::from(tw) * 4;
    let tw_i = i32::from(tw);
    let th_i = i32::from(th);

    // Snapshot the source block first so overlapping scroll copies never corrupt pixels.
    let mut snapshot = vec![0u8; cw * ch * 4];
    for row in 0..ch {
        let src_y = sy0 + ((top + row) as i32 - dy0);
        if !(0..th_i).contains(&src_y) {
            continue;
        }
        let s_base = src_y as usize * stride;
        let out_base = row * cw * 4;
        for col in 0..cw {
            let src_x = sx0 + ((left + col) as i32 - dx0);
            if !(0..tw_i).contains(&src_x) {
                continue;
            }
            let so = s_base + src_x as usize * 4;
            let oo = out_base + col * 4;
            snapshot[oo..oo + 4].copy_from_slice(&pixels[so..so + 4]);
        }
    }

    for row in 0..ch {
        let dst_base = (top + row) * stride + left * 4;
        let snap_base = row * cw * 4;
        if rop == 0xCC {
            pixels[dst_base..dst_base + cw * 4].copy_from_slice(&snapshot[snap_base..snap_base + cw * 4]);
            for px in pixels[dst_base..dst_base + cw * 4].as_chunks_mut::<4>().0 {
                px[3] = 255;
            }
        } else {
            for col in 0..cw {
                let d_off = dst_base + col * 4;
                let s_off = snap_base + col * 4;
                pixels[d_off] = rop3_byte(rop, pixels[d_off], snapshot[s_off], 0);
                pixels[d_off + 1] = rop3_byte(rop, pixels[d_off + 1], snapshot[s_off + 1], 0);
                pixels[d_off + 2] = rop3_byte(rop, pixels[d_off + 2], snapshot[s_off + 2], 0);
                pixels[d_off + 3] = 255;
            }
        }
    }

    Some(InclusiveRectangle {
        left: left as u16,
        top: top as u16,
        right: (right - 1) as u16,
        bottom: (bottom - 1) as u16,
    })
}

#[expect(clippy::too_many_arguments)]
fn draw_memblt(
    pixels: &mut [u8],
    tw: u16,
    th: u16,
    dx: i16,
    dy: i16,
    w: i16,
    h: i16,
    src_rgba: &[u8],
    sw: u16,
    sh: u16,
    sx: i16,
    sy: i16,
    rop: u8,
    clip: Option<ClipBounds>,
) -> Option<InclusiveRectangle> {
    let (left, top, right, bottom) = clip_rect(dx, dy, w, h, tw, th, clip)?;
    let dx0 = i32::from(dx);
    let dy0 = i32::from(dy);
    let sx0 = i32::from(sx);
    let sy0 = i32::from(sy);
    let dst_stride = usize::from(tw) * 4;
    let src_stride = usize::from(sw) * 4;
    let sw_i = i32::from(sw);
    let sh_i = i32::from(sh);
    for row in top..bottom {
        let src_y = sy0 + (row as i32 - dy0);
        if !(0..sh_i).contains(&src_y) {
            continue;
        }
        let s_row = src_y as usize * src_stride;
        let d_row = row * dst_stride;
        for col in left..right {
            let src_x = sx0 + (col as i32 - dx0);
            if !(0..sw_i).contains(&src_x) {
                continue;
            }
            let so = s_row + src_x as usize * 4;
            let doff = d_row + col * 4;
            if rop == 0xCC {
                pixels[doff] = src_rgba[so];
                pixels[doff + 1] = src_rgba[so + 1];
                pixels[doff + 2] = src_rgba[so + 2];
                pixels[doff + 3] = 255;
            } else {
                pixels[doff] = rop3_byte(rop, pixels[doff], src_rgba[so], 0);
                pixels[doff + 1] = rop3_byte(rop, pixels[doff + 1], src_rgba[so + 1], 0);
                pixels[doff + 2] = rop3_byte(rop, pixels[doff + 2], src_rgba[so + 2], 0);
                pixels[doff + 3] = 255;
            }
        }
    }
    Some(InclusiveRectangle {
        left: left as u16,
        top: top as u16,
        right: (right - 1) as u16,
        bottom: (bottom - 1) as u16,
    })
}

#[expect(clippy::too_many_arguments)]
fn draw_mono_glyph(
    pixels: &mut [u8],
    tw: u16,
    th: u16,
    glyph: &CachedGlyph,
    pen_x: i32,
    pen_y: i32,
    color: [u8; 3],
    clip: Option<ClipBounds>,
) -> Option<InclusiveRectangle> {
    if glyph.cx == 0 || glyph.cy == 0 {
        return None;
    }
    let gx0 = pen_x + i32::from(glyph.x);
    let gy0 = pen_y + i32::from(glyph.y);
    let (left, top, right, bottom) = clip_rect(
        gx0.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16,
        gy0.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16,
        glyph.cx.min(i16::MAX as u16) as i16,
        glyph.cy.min(i16::MAX as u16) as i16,
        tw,
        th,
        clip,
    )?;
    let row_bytes = usize::from(glyph.cx).div_ceil(8);
    let dst_stride = usize::from(tw) * 4;
    let mut painted = false;
    for row in top..bottom {
        let gy = (row as i32 - gy0) as usize;
        let Some(src_row) = glyph.data.get(gy * row_bytes..(gy + 1) * row_bytes) else {
            continue;
        };
        let d_base = row * dst_stride;
        for col in left..right {
            let gx = (col as i32 - gx0) as usize;
            if (src_row[gx >> 3] & (0x80 >> (gx & 7))) != 0 {
                let off = d_base + col * 4;
                pixels[off] = color[0];
                pixels[off + 1] = color[1];
                pixels[off + 2] = color[2];
                pixels[off + 3] = 255;
                painted = true;
            }
        }
    }
    painted.then_some(InclusiveRectangle {
        left: left as u16,
        top: top as u16,
        right: (right - 1) as u16,
        bottom: (bottom - 1) as u16,
    })
}

fn convert_bottom_up_to_rgba(
    w: usize,
    h: usize,
    fmt: RlePixelFormat,
    data: &[u8],
    palette: &[[u8; 3]],
) -> Option<Vec<u8>> {
    let mut rgba = vec![255u8; w.checked_mul(h)?.checked_mul(4)?];
    match fmt {
        RlePixelFormat::Rgb24 => {
            let stride = w * 3;
            if data.len() < stride * h {
                return None;
            }
            for y in 0..h {
                let srow = &data[(h - 1 - y) * stride..(h - y) * stride];
                let drow = &mut rgba[y * w * 4..(y + 1) * w * 4];
                for (px, dst) in srow.chunks_exact(3).zip(drow.chunks_exact_mut(4)) {
                    dst[0] = px[2];
                    dst[1] = px[1];
                    dst[2] = px[0];
                    dst[3] = 255;
                }
            }
        }
        RlePixelFormat::Rgb16 => {
            let stride = w * 2;
            if data.len() < stride * h {
                return None;
            }
            for y in 0..h {
                let srow = &data[(h - 1 - y) * stride..(h - y) * stride];
                let drow = &mut rgba[y * w * 4..(y + 1) * w * 4];
                for (px, dst) in srow.chunks_exact(2).zip(drow.chunks_exact_mut(4)) {
                    let [r, g, b] = rdp_16bit_to_rgb(u16::from_le_bytes([px[0], px[1]]));
                    dst[0] = r;
                    dst[1] = g;
                    dst[2] = b;
                    dst[3] = 255;
                }
            }
        }
        RlePixelFormat::Rgb15 => {
            let stride = w * 2;
            if data.len() < stride * h {
                return None;
            }
            for y in 0..h {
                let srow = &data[(h - 1 - y) * stride..(h - y) * stride];
                let drow = &mut rgba[y * w * 4..(y + 1) * w * 4];
                for (px, dst) in srow.chunks_exact(2).zip(drow.chunks_exact_mut(4)) {
                    let [r, g, b] = rdp_15bit_to_rgb(u16::from_le_bytes([px[0], px[1]]));
                    dst[0] = r;
                    dst[1] = g;
                    dst[2] = b;
                    dst[3] = 255;
                }
            }
        }
        RlePixelFormat::Rgb8 => {
            if data.len() < w * h {
                return None;
            }
            for y in 0..h {
                let srow = &data[(h - 1 - y) * w..(h - y) * w];
                let drow = &mut rgba[y * w * 4..(y + 1) * w * 4];
                for (&idx, dst) in srow.iter().zip(drow.chunks_exact_mut(4)) {
                    let rgb = palette.get(usize::from(idx)).copied().unwrap_or([0, 0, 0]);
                    dst[0] = rgb[0];
                    dst[1] = rgb[1];
                    dst[2] = rgb[2];
                    dst[3] = 255;
                }
            }
        }
    }
    Some(rgba)
}
