use ironrdp::pdu::geometry::InclusiveRectangle;
use ironrdp::session::image::DecodedImage;
use tokio::sync::oneshot;

use crate::api::desktop::{DesktopCursor, DesktopFrame, DesktopTile};

pub(crate) const TILE_SIZE: u16 = 128;
// Sample neighboring framebuffer pixels in a one-pixel gutter. Bilinear
// filtering must never bleed from an unrelated tile packed next to this one.
const ATLAS_CELL_SIZE: u16 = TILE_SIZE + 2;

pub(crate) struct FrameRequest {
    pub after: u32,
    pub reply: oneshot::Sender<DesktopFrame>,
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

    pub fn cursor(&mut self, cursor: DesktopCursor) {
        self.cursor = Some(cursor);
        self.cursor_dirty = true;
    }

    pub fn ready(&self, after: u32) -> bool {
        self.dirty.contains(&true) || self.cursor_dirty || after != self.sequence
    }

    pub fn snapshot(&mut self, image: &DecodedImage, after: u32) -> DesktopFrame {
        // EGFX ResetGraphics can change dimensions without DeactivateAll.
        let resized = self.width != image.width() || self.height != image.height();
        if resized {
            let mut next = Self::new(image.width(), image.height());
            next.sequence = self.sequence;
            next.cursor = self.cursor.take();
            *self = next;
        }
        // A cancelled poll may have consumed an atlas. Recover every tile when
        // the caller's base differs, including the current cursor shape.
        let full = resized || after != self.sequence;
        let dirty: Vec<_> = self
            .dirty
            .iter()
            .enumerate()
            .filter_map(|(index, &dirty)| (full || dirty).then_some(index))
            .collect();
        let mut tiles = Vec::with_capacity(dirty.len());
        let complete = dirty.len() == self.dirty.len();
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
        let (bitmap_width, bitmap_height) = if complete {
            (self.width, self.height)
        } else if dirty.is_empty() {
            (0, 0)
        } else {
            (
                atlas_columns as u16 * ATLAS_CELL_SIZE,
                dirty.len().div_ceil(atlas_columns) as u16 * ATLAS_CELL_SIZE,
            )
        };
        let mut rgba = if complete {
            let mut rgba = image.data().to_vec();
            for pixel in rgba.chunks_exact_mut(4) {
                pixel[3] = 255;
            }
            rgba
        } else {
            vec![0; usize::from(bitmap_width) * usize::from(bitmap_height) * 4]
        };
        let input_stride = usize::from(image.width()) * 4;
        let output_stride = usize::from(bitmap_width) * 4;
        for (slot, index) in dirty.into_iter().enumerate() {
            let x = (index % self.columns) as u16 * TILE_SIZE;
            let y = (index / self.columns) as u16 * TILE_SIZE;
            let width = TILE_SIZE.min(self.width - x);
            let height = TILE_SIZE.min(self.height - y);
            let source_x = if complete {
                x
            } else {
                (slot % atlas_columns) as u16 * ATLAS_CELL_SIZE + 1
            };
            let source_y = if complete {
                y
            } else {
                (slot / atlas_columns) as u16 * ATLAS_CELL_SIZE + 1
            };
            let row_bytes = usize::from(width) * 4;
            for row in 0..if complete { 0 } else { height + 2 } {
                let image_row = (u32::from(y) + u32::from(row))
                    .saturating_sub(1)
                    .min(u32::from(self.height) - 1) as u16;
                let input = usize::from(image_row) * input_stride + usize::from(x) * 4;
                let output =
                    usize::from(source_y + row - 1) * output_stride + usize::from(source_x - 1) * 4;
                let target = &mut rgba[output..output + row_bytes + 8];
                let left =
                    usize::from(image_row) * input_stride + usize::from(x.saturating_sub(1)) * 4;
                let right = usize::from(image_row) * input_stride
                    + usize::from((x + width).min(self.width - 1)) * 4;
                target[..4].copy_from_slice(&image.data()[left..left + 4]);
                target[4..row_bytes + 4].copy_from_slice(&image.data()[input..input + row_bytes]);
                target[row_bytes + 4..].copy_from_slice(&image.data()[right..right + 4]);
                // Normalize only copied rows while they are still cache-hot.
                for pixel in target.chunks_exact_mut(4) {
                    pixel[3] = 255;
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
        let cursor = if full || self.cursor_dirty {
            self.cursor.clone()
        } else {
            None
        };
        self.cursor_dirty = false;
        self.sequence = self.sequence.wrapping_add(1).max(1);
        DesktopFrame {
            sequence: self.sequence,
            width: image.width(),
            height: image.height(),
            bitmap_width,
            bitmap_height,
            rgba,
            tiles,
            cursor,
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
        assert_eq!(first.tiles.len(), 70);
        assert_eq!(first.rgba.len(), 1280 * 800 * 4);
        encoder.damage(damage(10, 20, 19, 29));
        encoder.damage(damage(1200, 740, 1210, 750));
        let update = encoder.snapshot(&image, first.sequence);
        assert_eq!(update.tiles.len(), 2);
        assert_eq!(update.rgba.len(), 2 * 130 * 130 * 4);
        assert!(!encoder.ready(update.sequence));
        let recovered = encoder.snapshot(&image, first.sequence);
        assert_eq!(recovered.tiles.len(), first.tiles.len());
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
        encoder.damage(damage(127, 127, 259, 129));
        encoder.damage(damage(128, 128, 259, 129));
        let frame = encoder.snapshot(&image, first.sequence);
        assert_eq!(frame.tiles.len(), 6);
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
                    .chunks_exact(4)
                    .all(|p| p[3] == 255));
            }
        }
    }

    #[test]
    fn egfx_resize_sends_all_tiles_even_when_the_sequence_matches() {
        let mut encoder = FrameEncoder::new(128, 128);
        let first = encoder.snapshot(&DecodedImage::new(PixelFormat::RgbA32, 128, 128), 0);
        let frame = encoder.snapshot(
            &DecodedImage::new(PixelFormat::RgbA32, 257, 129),
            first.sequence,
        );
        assert_eq!((frame.width, frame.height), (257, 129));
        assert_eq!(frame.tiles.len(), 6);
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
