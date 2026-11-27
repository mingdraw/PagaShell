use crate::{PixelFormat, Rect, VncError, VncEvent};
use std::future::Future;
use tokio::io::{AsyncRead, AsyncReadExt};
use tracing::error;

use super::zlib::ZlibReader;

#[inline]
fn read_run_length(reader: &mut ZlibReader, remaining: usize) -> Result<usize, VncError> {
    let mut run_length_part;
    let mut run_length = 1;
    loop {
        run_length_part = reader.read_u8()?;
        run_length += run_length_part as usize;
        if run_length > remaining {
            return Err(VncError::InvalidImageData);
        }
        if 255 != run_length_part {
            break;
        }
    }
    Ok(run_length)
}

#[inline]
fn read_true_color(
    reader: &mut ZlibReader,
    pad: bool,
    compressed_bpp: usize,
) -> Result<[u8; 4], VncError> {
    let mut buf = [255; 4];
    reader.read_bytes(&mut buf[pad as usize..pad as usize + compressed_bpp])?;
    Ok(buf)
}

#[inline]
fn copy_indexed(
    palette: &[u8],
    pixels: &mut Vec<u8>,
    bpp: usize,
    index: u8,
) -> Result<(), VncError> {
    let start = index as usize * bpp;
    let pixel = palette
        .get(start..start + bpp)
        .ok_or(VncError::InvalidImageData)?;
    pixels.extend_from_slice(pixel);
    Ok(())
}

pub struct Decoder {
    decompressor: Option<flate2::Decompress>,
    zlib_data: Vec<u8>,
    zlib_buf: Vec<u8>,
    palette: Vec<u8>,
    tile_pixels: Vec<u8>,
}

impl Decoder {
    pub fn new() -> Self {
        Self {
            decompressor: Some(flate2::Decompress::new(true)),
            zlib_data: Vec::new(),
            zlib_buf: Vec::new(),
            palette: Vec::with_capacity(128 * 4),
            tile_pixels: Vec::with_capacity(64 * 64 * 4),
        }
    }

    pub async fn decode<S, F, Fut>(
        &mut self,
        format: &PixelFormat,
        rect: &Rect,
        input: &mut S,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        S: AsyncRead + Unpin,
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        crate::limits::dimensions(rect.width, rect.height)?;
        format.validate()?;
        let data_len = input.read_u32().await? as usize;
        if data_len > crate::limits::MAX_COMPRESSED {
            return Err(VncError::InvalidImageData);
        }
        self.zlib_data.resize(data_len, 0);
        input.read_exact(&mut self.zlib_data).await?;
        let decompressor = self.decompressor.take().ok_or(VncError::InvalidImageData)?;
        let zlib_buf = std::mem::take(&mut self.zlib_buf);
        let mut reader = ZlibReader::with_buffer(decompressor, &self.zlib_data, zlib_buf);

        let bpp = format.bits_per_pixel as usize / 8;
        let pixel_mask = if format.true_color_flag != 0 {
            ((format.red_max as u32) << format.red_shift)
                | ((format.green_max as u32) << format.green_shift)
                | ((format.blue_max as u32) << format.blue_shift)
        } else {
            0
        };

        let (compressed_bpp, alpha_at_first) =
            if format.bits_per_pixel == 32 && format.true_color_flag > 0 && format.depth <= 24 {
                if pixel_mask & 0x000000ff == 0 {
                    // rgb at the most significant bits
                    // if format.big_endian_flag is set
                    // then decompressed data is expected to be [rgb.0, rgb.1, rgb.2, alpha]
                    // otherwise the decompressed data should be [alpha, rgb.0, rgb.1, rgb.2]
                    (3, format.big_endian_flag == 0)
                } else if pixel_mask & 0xff000000 == 0 {
                    // rgb at the least significant bits
                    // if format.big_endian_flag is set
                    // then decompressed data is expected to be [alpha, rgb.0, rgb.1, rgb.2]
                    // otherwise the decompressed data should be [rgb.0, rgb.1, rgb.2, alpha]
                    (3, format.big_endian_flag > 0)
                } else {
                    (4, false)
                }
            } else {
                (bpp, false)
            };

        let rect_w = usize::from(rect.width);
        let rect_h = usize::from(rect.height);
        let rect_stride = rect_w * bpp;
        let mut rect_pixels = vec![0u8; rect_stride * rect_h];

        let mut y = 0u16;
        while y < rect.height {
            let height = (rect.height - y).min(64);
            let mut x = 0u16;
            while x < rect.width {
                let width = (rect.width - x).min(64);
                let pixel_count = usize::from(height) * usize::from(width);

                let control = reader.read_u8()?;
                let is_rle = control & 0x80 > 0;
                let palette_size = control & 0x7f;
                self.palette.clear();

                for _ in 0..palette_size {
                    let px = read_true_color(&mut reader, alpha_at_first, compressed_bpp)?;
                    self.palette.extend_from_slice(&px[..bpp]);
                }

                self.tile_pixels.clear();
                self.tile_pixels.reserve(pixel_count * bpp);
                match (is_rle, palette_size) {
                    (false, 0) => {
                        // True Color pixels
                        for _ in 0..pixel_count {
                            let px = read_true_color(&mut reader, alpha_at_first, compressed_bpp)?;
                            self.tile_pixels.extend_from_slice(&px[..bpp]);
                        }
                    }
                    (false, 1) => {
                        // Color fill
                        let color = self.palette.get(..bpp).ok_or(VncError::InvalidImageData)?;
                        for _ in 0..pixel_count {
                            self.tile_pixels.extend_from_slice(color);
                        }
                    }
                    (false, 2..=16) => {
                        // Indexed pixels
                        let bits_per_index = match palette_size {
                            2 => 1,
                            3..=4 => 2,
                            5..=16 => 4,
                            _ => unreachable!(),
                        };
                        let mut encoded = reader.read_u8()?;
                        let mask = (1 << bits_per_index) - 1;

                        for row in 0..height {
                            let mut shift = 8 - bits_per_index;
                            for _ in 0..width {
                                if shift < 0 {
                                    shift = 8 - bits_per_index;
                                    encoded = reader.read_u8()?;
                                }
                                let idx = (encoded >> shift) & mask;

                                copy_indexed(&self.palette, &mut self.tile_pixels, bpp, idx)?;
                                shift -= bits_per_index;
                            }
                            if shift < 8 - bits_per_index && row < height - 1 {
                                encoded = reader.read_u8()?;
                            }
                        }
                    }
                    (true, 0) => {
                        // True Color RLE
                        let mut count = 0;
                        while count < pixel_count {
                            let px = read_true_color(&mut reader, alpha_at_first, compressed_bpp)?;
                            let run_length = read_run_length(&mut reader, pixel_count - count)?;
                            for _ in 0..run_length {
                                self.tile_pixels.extend_from_slice(&px[..bpp]);
                            }
                            count += run_length;
                        }
                    }
                    (true, 2..=127) => {
                        // Indexed RLE
                        let mut count = 0;
                        while count < pixel_count {
                            let control = reader.read_u8()?;
                            let longer_than_one = control & 0x80 > 0;
                            let index = control & 0x7f;
                            let run_length = if longer_than_one {
                                read_run_length(&mut reader, pixel_count - count)?
                            } else {
                                1
                            };
                            let start = usize::from(index) * bpp;
                            let color = self
                                .palette
                                .get(start..start + bpp)
                                .ok_or(VncError::InvalidImageData)?;
                            for _ in 0..run_length {
                                self.tile_pixels.extend_from_slice(color);
                            }
                            count += run_length;
                        }
                    }
                    (rle, pal) => {
                        error!("ZRLE subencoding error {:?}", (rle, pal));
                        return Err(VncError::InvalidImageData);
                    }
                }

                let tile_stride = usize::from(width) * bpp;
                let dst_x_off = usize::from(x) * bpp;
                for row in 0..usize::from(height) {
                    let src_start = row * tile_stride;
                    let dst_start = (usize::from(y) + row) * rect_stride + dst_x_off;
                    rect_pixels[dst_start..dst_start + tile_stride]
                        .copy_from_slice(&self.tile_pixels[src_start..src_start + tile_stride]);
                }
                x += width;
            }
            y += height;
        }

        let (decompressor, zlib_buf) = reader.into_parts()?;
        self.decompressor = Some(decompressor);
        self.zlib_buf = zlib_buf;
        output_func(VncEvent::RawImage(*rect, rect_pixels)).await?;

        Ok(())
    }
}

#[cfg(test)]
mod tests;
