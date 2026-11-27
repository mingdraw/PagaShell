use super::*;
use std::sync::Mutex;

fn compress(compressor: &mut flate2::Compress, data: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(1024);
    compressor
        .compress_vec(data, &mut output, flate2::FlushCompress::Sync)
        .unwrap();
    let mut packet = (output.len() as u32).to_be_bytes().to_vec();
    packet.extend(output);
    packet
}

#[tokio::test]
async fn malformed_palette_index_and_runs_return_errors() {
    // 1x1 tiles: packed index 3 into a three-color palette; overlong plain/indexed
    // runs; index 2 into a two-color palette; illegal subencoding; truncated pixel.
    for data in [
        vec![3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xc0],
        vec![128, 1, 2, 3, 1],
        vec![130, 1, 2, 3, 4, 5, 6, 128, 1],
        vec![130, 1, 2, 3, 4, 5, 6, 2],
        vec![129, 1, 2, 3],
        vec![0, 1],
    ] {
        let mut compressor = flate2::Compress::new(flate2::Compression::fast(), true);
        let packet = compress(&mut compressor, &data);
        let mut input = packet.as_slice();
        let result = Decoder::new()
            .decode(
                &PixelFormat::rgba(),
                &Rect {
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1,
                },
                &mut input,
                &|_| async { Ok(()) },
            )
            .await;
        assert!(result.is_err(), "malformed input accepted: {data:?}");
    }
}

#[tokio::test]
async fn valid_modes_and_persistent_compression_preserve_pixels() {
    let mut compressor = flate2::Compress::new(flate2::Compression::fast(), true);
    let mut decoder = Decoder::new();
    // Raw, solid, packed-palette, plain RLE and palette RLE for a two-pixel tile.
    for (data, expected) in [
        (vec![0, 1, 2, 3, 4, 5, 6], vec![1, 2, 3, 255, 4, 5, 6, 255]),
        (vec![1, 1, 2, 3], vec![1, 2, 3, 255, 1, 2, 3, 255]),
        (
            vec![2, 1, 2, 3, 4, 5, 6, 0x40],
            vec![1, 2, 3, 255, 4, 5, 6, 255],
        ),
        (vec![128, 1, 2, 3, 1], vec![1, 2, 3, 255, 1, 2, 3, 255]),
        (
            vec![130, 1, 2, 3, 4, 5, 6, 128, 1],
            vec![1, 2, 3, 255, 1, 2, 3, 255],
        ),
    ] {
        let packet = compress(&mut compressor, &data);
        let mut input = packet.as_slice();
        let output = Mutex::new(Vec::new());
        decoder
            .decode(
                &PixelFormat::rgba(),
                &Rect {
                    x: 0,
                    y: 0,
                    width: 2,
                    height: 1,
                },
                &mut input,
                &|event| {
                    output.lock().unwrap().push(event);
                    async { Ok(()) }
                },
            )
            .await
            .unwrap();
        let VncEvent::RawImage(_, pixels) = output.into_inner().unwrap().remove(0) else {
            panic!("expected pixels");
        };
        assert_eq!(pixels, expected);
    }
}

#[tokio::test]
async fn multi_tile_zrle_rect_coalesces_into_single_raw_image_with_exact_layout() {
    let mut compressor = flate2::Compress::new(flate2::Compression::fast(), true);
    let mut decoder = Decoder::new();
    // 100x70 spans 2x2 tiles: (64x64), (36x64), (64x6), (36x6), each solid-filled.
    let tile_colors = [[10u8, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]];
    let mut raw_zrle = Vec::new();
    for color in tile_colors {
        raw_zrle.push(1); // solid fill
        raw_zrle.extend_from_slice(&color);
    }
    let packet = compress(&mut compressor, &raw_zrle);
    let mut input = packet.as_slice();
    let output = Mutex::new(Vec::new());
    decoder
        .decode(
            &PixelFormat::rgba(),
            &Rect {
                x: 8,
                y: 4,
                width: 100,
                height: 70,
            },
            &mut input,
            &|event| {
                output.lock().unwrap().push(event);
                async { Ok(()) }
            },
        )
        .await
        .unwrap();
    let events = output.into_inner().unwrap();
    assert_eq!(events.len(), 1);
    let VncEvent::RawImage(rect, pixels) = &events[0] else {
        panic!("expected coalesced RawImage");
    };
    assert_eq!((rect.x, rect.y, rect.width, rect.height), (8, 4, 100, 70));
    assert_eq!(pixels.len(), 100 * 70 * 4);
    let at = |x: usize, y: usize| &pixels[(y * 100 + x) * 4..(y * 100 + x) * 4 + 4];
    assert_eq!(at(0, 0), &[10, 20, 30, 255]);
    assert_eq!(at(63, 63), &[10, 20, 30, 255]);
    assert_eq!(at(64, 0), &[40, 50, 60, 255]);
    assert_eq!(at(99, 63), &[40, 50, 60, 255]);
    assert_eq!(at(0, 64), &[70, 80, 90, 255]);
    assert_eq!(at(63, 69), &[70, 80, 90, 255]);
    assert_eq!(at(64, 64), &[100, 110, 120, 255]);
    assert_eq!(at(99, 69), &[100, 110, 120, 255]);
}
