use ironrdp::pdu::geometry::InclusiveRectangle;
use ironrdp::session::image::DecodedImage;
use ironrdp_egfx::gpu::GpuPresentedFrame;
use tokio::sync::oneshot;

use crate::api::desktop::{DesktopCursor, DesktopFrame, DesktopTile};

pub(crate) const TILE_SIZE: u16 = 128;
// Sample neighboring framebuffer pixels in a one-pixel gutter. Bilinear
// filtering must never bleed from an unrelated tile packed next to this one.
const ATLAS_CELL_SIZE: u16 = TILE_SIZE + 2;

// Desktop pixels are opaque, even when a codec uses the fourth byte as padding.
fn opaque([r, g, b, _]: [u8; 4]) -> [u8; 4] {
    [r, g, b, 255]
}

pub(crate) struct FrameDelivery {
    pub frame: DesktopFrame,
    pub gpu: Option<Box<dyn GpuPresentedFrame>>,
}

pub(crate) struct FrameRequest {
    pub after: u32,
    pub reply: oneshot::Sender<FrameDelivery>,
}

/// Keep exact dirty tiles until the consumer requests an update. A single atlas
/// upload replaces only these tiles on the GPU, without flattening the desktop.
pub(crate) struct FrameEncoder {
    sequence: u32,
    width: u16,
    height: u16,
    columns: usize,
    dirty: Vec<bool>,
    cursor: Option<DesktopCursor>,
    cursor_dirty: bool,
}

impl FrameEncoder {
    pub fn new(width: u16, height: u16) -> Self {
        let columns = usize::from(width.div_ceil(TILE_SIZE));
        let rows = usize::from(height.div_ceil(TILE_SIZE));
        Self {
            sequence: 0,
            width,
            height,
            columns,
            dirty: vec![true; columns * rows],
            cursor: None,
            cursor_dirty: false,
        }
    }

    pub fn damage(&mut self, rect: InclusiveRectangle) {
        if rect.left >= self.width
            || rect.top >= self.height
            || rect.right < rect.left
            || rect.bottom < rect.top
        {
            return;
        }
        let right = rect.right.min(self.width - 1) / TILE_SIZE;
        let bottom = rect.bottom.min(self.height - 1) / TILE_SIZE;
        for y in rect.top / TILE_SIZE..=bottom {
            for x in rect.left / TILE_SIZE..=right {
                self.dirty[usize::from(y) * self.columns + usize::from(x)] = true;
            }
        }
    }

    pub fn damage_region(&mut self, x: u16, y: u16, width: u16, height: u16) {
        if width != 0 && height != 0 {
            self.damage(InclusiveRectangle {
                left: x,
                top: y,
                right: x.saturating_add(width - 1),
                bottom: y.saturating_add(height - 1),
            });
        }
    }

    pub fn cursor(&mut self, cursor: DesktopCursor) {
        self.cursor = Some(cursor);
        self.cursor_dirty = true;
    }

    pub fn ready(&self, after: u32) -> bool {
        self.dirty.contains(&true) || self.cursor_dirty || after != self.sequence
    }

    /// The previous framebuffer is no longer a valid base, even at the same size.
    pub fn invalidate(&mut self, width: u16, height: u16) {
        self.resize(width, height);
        self.dirty.fill(true);
        self.cursor_dirty = self.cursor.is_some();
    }

    pub fn snapshot(&mut self, image: &DecodedImage, after: u32) -> DesktopFrame {
        self.snapshot_pixels(
            image.width(),
            image.height(),
            image.data(),
            after,
            image.is_opaque_rgba(),
        )
    }

    pub fn snapshot_gpu(&mut self, width: u16, height: u16, after: u32) -> DesktopFrame {
        let resized = self.resize(width, height);
        let full = resized || after != self.sequence;
        let cursor = if full || self.cursor_dirty {
            self.cursor.clone()
        } else {
            None
        };
        self.cursor_dirty = false;
        self.dirty.fill(false);
        self.sequence = self.sequence.wrapping_add(1).max(1);
        DesktopFrame {
            sequence: self.sequence,
            width,
            height,
            bitmap_width: 0,
            bitmap_height: 0,
            rgba: Vec::new(),
            tiles: Vec::new(),
            cursor,
            texture_id: None,
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) -> bool {
        // EGFX ResetGraphics can change dimensions without DeactivateAll.
        let resized = self.width != width || self.height != height;
        if resized {
            let mut next = Self::new(width, height);
            next.sequence = self.sequence;
            next.cursor = self.cursor.take();
            next.cursor_dirty = next.cursor.is_some();
            *self = next;
        }
        resized
    }

    pub fn snapshot_rgba(
        &mut self,
        width: u16,
        height: u16,
        pixels: &[u8],
        after: u32,
    ) -> DesktopFrame {
        self.snapshot_pixels(width, height, pixels, after, false)
    }

    fn snapshot_pixels(
        &mut self,
        width: u16,
        height: u16,
        pixels: &[u8],
        after: u32,
        known_opaque: bool,
    ) -> DesktopFrame {
        let resized = self.resize(width, height);
        // A cancelled poll may have consumed an atlas. Recover every tile when
        // the caller's base differs, including the current cursor shape.
        let full = resized || after != self.sequence;
        let cursor = if full || self.cursor_dirty {
            self.cursor.clone()
        } else {
            None
        };
        self.cursor_dirty = false;
        self.sequence = self.sequence.wrapping_add(1).max(1);

        if full || self.dirty.iter().all(|&dirty| dirty) {
            self.dirty.fill(false);
            let rgba = if known_opaque {
                pixels.to_vec()
            } else {
                pixels
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .copied()
                    .map(opaque)
                    .collect::<Vec<_>>()
                    .into_flattened()
            };
            // A contiguous desktop needs neither tile metadata nor an atlas.
            return DesktopFrame {
                sequence: self.sequence,
                width,
                height,
                bitmap_width: width,
                bitmap_height: height,
                rgba,
                tiles: Vec::new(),
                cursor,
                texture_id: None,
            };
        }

        let dirty: Vec<_> = self
            .dirty
            .iter()
            .enumerate()
            .filter_map(|(index, &dirty)| dirty.then_some(index))
            .collect();
        let mut tiles = Vec::with_capacity(dirty.len());
        // Choose a compact grid rather than inheriting desktop columns. For
        // example, 32 tiles use 8x4 cells instead of 10x4 with 8 empty cells.
        // Bound the aspect ratio as well so prime tile counts do not create
        // extremely tall textures just to save a few padding cells.
        let atlas_columns = (1..=dirty.len().min(32))
            .filter(|&columns| {
                let rows = dirty.len().div_ceil(columns);
                rows <= columns * 4
                    && columns <= rows * 4
                    && rows <= usize::from(u16::MAX / ATLAS_CELL_SIZE)
            })
            .min_by_key(|&columns| {
                let rows = dirty.len().div_ceil(columns);
                (
                    columns * rows,
                    columns.abs_diff(rows),
                    std::cmp::Reverse(columns),
                )
            })
            .unwrap_or(1);
        let (bitmap_width, bitmap_height) = if dirty.is_empty() {
            (0, 0)
        } else {
            (
                atlas_columns as u16 * ATLAS_CELL_SIZE,
                dirty.len().div_ceil(atlas_columns) as u16 * ATLAS_CELL_SIZE,
            )
        };
        let mut rgba = vec![0; usize::from(bitmap_width) * usize::from(bitmap_height) * 4];
        let input_stride = usize::from(self.width) * 4;
        let output_stride = usize::from(bitmap_width) * 4;
        for (slot, index) in dirty.into_iter().enumerate() {
            let x = (index % self.columns) as u16 * TILE_SIZE;
            let y = (index / self.columns) as u16 * TILE_SIZE;
            let width = TILE_SIZE.min(self.width - x);
            let height = TILE_SIZE.min(self.height - y);
            let source_x = (slot % atlas_columns) as u16 * ATLAS_CELL_SIZE + 1;
            let source_y = (slot / atlas_columns) as u16 * ATLAS_CELL_SIZE + 1;
            let col = usize::from(x);
            let cols = usize::from(width);
            for row in 0..height + 2 {
                let image_row = (u32::from(y) + u32::from(row))
                    .saturating_sub(1)
                    .min(u32::from(self.height) - 1) as u16;
                let input = usize::from(image_row) * input_stride;
                let output =
                    usize::from(source_y + row - 1) * output_stride + usize::from(source_x - 1) * 4;
                let source = pixels[input..input + input_stride].as_chunks::<4>().0;
                let target = rgba[output..output + (cols + 2) * 4].as_chunks_mut::<4>().0;
                let left = source[col.saturating_sub(1)];
                let right = source[(col + cols).min(source.len() - 1)];
                let row = &source[col..col + cols];
                if known_opaque {
                    target[0] = left;
                    target[cols + 1] = right;
                    target[1..cols + 1].copy_from_slice(row);
                } else {
                    target[0] = opaque(left);
                    target[cols + 1] = opaque(right);
                    for (to, &from) in target[1..cols + 1].iter_mut().zip(row) {
                        *to = opaque(from);
                    }
                }
            }
            tiles.push(DesktopTile {
                x,
                y,
                width,
                height,
                source_x,
                source_y,
            });
        }
        self.dirty.fill(false);
        DesktopFrame {
            sequence: self.sequence,
            width: self.width,
            height: self.height,
            bitmap_width,
            bitmap_height,
            rgba,
            tiles,
            cursor,
            texture_id: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::graphics::image_processing::PixelFormat;

    fn damage(left: u16, top: u16, right: u16, bottom: u16) -> InclusiveRectangle {
        InclusiveRectangle {
            left,
            top,
            right,
            bottom,
        }
    }

    #[test]
    fn sparse_updates_do_not_copy_the_area_between_them_and_recover_missed_atlas() {
        let image = DecodedImage::new(PixelFormat::RgbA32, 1280, 800);
        let mut encoder = FrameEncoder::new(1280, 800);
        let first = encoder.snapshot(&image, 0);
        assert!(first.tiles.is_empty());
        assert_eq!(first.rgba.len(), 1280 * 800 * 4);
        encoder.damage(damage(10, 20, 19, 29));
        encoder.damage(damage(1200, 740, 1210, 750));
        let update = encoder.snapshot(&image, first.sequence);
        assert_eq!(update.tiles.len(), 2);
        assert_eq!(update.rgba.len(), 2 * 130 * 130 * 4);
        assert!(!encoder.ready(update.sequence));
        let recovered = encoder.snapshot(&image, first.sequence);
        assert!(recovered.tiles.is_empty());
        assert_eq!(
            (recovered.bitmap_width, recovered.bitmap_height),
            (1280, 800)
        );
        assert_eq!(recovered.rgba.len(), first.rgba.len());
    }

    #[test]
    fn scrolling_tiles_do_not_allocate_empty_atlas_cells() {
        let image = DecodedImage::new(PixelFormat::RgbA32, 1280, 800);
        let mut encoder = FrameEncoder::new(1280, 800);
        let first = encoder.snapshot(&image, 0);
        encoder.damage(damage(128, 0, 1151, 511));
        let frame = encoder.snapshot(&image, first.sequence);
        assert_eq!(frame.tiles.len(), 32);
        assert_eq!(frame.rgba.len(), 32 * 130 * 130 * 4);
    }

    #[test]
    fn overlapping_damage_and_tile_edges_are_not_duplicated() {
        let image = DecodedImage::new(PixelFormat::RgbA32, 260, 130);
        let mut encoder = FrameEncoder::new(260, 130);
        let first = encoder.snapshot(&image, 0);
        encoder.damage(damage(128, 127, 259, 129));
        encoder.damage(damage(128, 128, 259, 129));
        let frame = encoder.snapshot(&image, first.sequence);
        assert_eq!(frame.tiles.len(), 4);
        let edge = frame
            .tiles
            .iter()
            .find(|tile| tile.x == 256 && tile.y == 128)
            .unwrap();
        assert_eq!((edge.width, edge.height), (4, 2));
        for tile in frame.tiles {
            for row in 0..tile.height {
                let start = (usize::from(tile.source_y + row) * usize::from(frame.bitmap_width)
                    + usize::from(tile.source_x))
                    * 4;
                assert!(frame.rgba[start..start + usize::from(tile.width) * 4]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .all(|p| p[3] == 255));
            }
        }
    }

    #[test]
    fn egfx_resize_sends_a_contiguous_frame_even_when_the_sequence_matches() {
        let mut encoder = FrameEncoder::new(128, 128);
        let first = encoder.snapshot(&DecodedImage::new(PixelFormat::RgbA32, 128, 128), 0);
        let frame = encoder.snapshot(
            &DecodedImage::new(PixelFormat::RgbA32, 257, 129),
            first.sequence,
        );
        assert_eq!((frame.width, frame.height), (257, 129));
        assert!(frame.tiles.is_empty());
        assert_eq!((frame.bitmap_width, frame.bitmap_height), (257, 129));
        assert_eq!(frame.rgba.len(), 257 * 129 * 4);
    }

    #[test]
    fn same_size_reset_replaces_the_base_without_reusing_sequence_numbers() {
        let mut encoder = FrameEncoder::new(256, 256);
        let image = DecodedImage::new(PixelFormat::RgbA32, 256, 256);
        let first = encoder.snapshot(&image, 0);
        encoder.invalidate(256, 256);
        encoder.damage(damage(0, 0, 127, 127));
        let next = encoder.snapshot(&image, first.sequence);
        assert!(next.tiles.is_empty());
        assert_eq!(next.rgba.len(), 256 * 256 * 4);
        assert_eq!(next.sequence, first.sequence + 1);
    }

    #[test]
    fn cursor_changes_do_not_copy_the_desktop() {
        let image = DecodedImage::new(PixelFormat::RgbA32, 1280, 800);
        let mut encoder = FrameEncoder::new(1280, 800);
        let first = encoder.snapshot(&image, 0);
        encoder.cursor(DesktopCursor {
            kind: 1,
            width: 0,
            height: 0,
            hotspot_x: 0,
            hotspot_y: 0,
            rgba: vec![],
        });
        let cursor = encoder.snapshot(&image, first.sequence);
        assert!(cursor.rgba.is_empty());
        assert!(cursor.tiles.is_empty());
        assert_eq!(cursor.cursor.unwrap().kind, 1);
        assert!(!encoder.ready(cursor.sequence));
    }
}
