import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_surface.dart';

Uint8List solid(int width, int height, List<int> color) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes.setRange(i, i + 4, color);
  }
  return bytes;
}

Future<Uint8List> readPixels(RdpSurface surface) async {
  final recorder = ui.PictureRecorder();
  surface.paint(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(surface.width, surface.height);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('打包图集更新不相邻分块和右下边缘，其余像素保持不变', (tester) async {
    await tester.runAsync(() async {
      final surface = RdpSurface();
      addTearDown(surface.dispose);
      await surface.apply(
        RdpFrame(
          width: 257,
          height: 129,
          rgba: solid(257, 129, [255, 255, 255, 255]),
        ),
      );
      final atlas = solid(256, 128, [255, 0, 0, 255]);
      for (var row = 0; row < 128; row++) {
        atlas.setRange(
          (row * 256 + 128) * 4,
          (row * 256 + 256) * 4,
          solid(128, 1, [0, 0, 255, 255]),
        );
      }
      await surface.apply(
        RdpFrame(
          width: 257,
          height: 129,
          patchWidth: 256,
          patchHeight: 128,
          rgba: atlas,
          tiles: const [
            RdpTile(
              x: 0,
              y: 0,
              width: 128,
              height: 128,
              sourceX: 0,
              sourceY: 0,
            ),
            RdpTile(
              x: 256,
              y: 128,
              width: 1,
              height: 1,
              sourceX: 128,
              sourceY: 0,
            ),
          ],
        ),
      );
      final pixels = await readPixels(surface);
      for (var y = 0; y < 129; y++) {
        for (var x = 0; x < 257; x++) {
          final expected = x < 128 && y < 128
              ? [255, 0, 0, 255]
              : x == 256 && y == 128
              ? [0, 0, 255, 255]
              : [255, 255, 255, 255];
          expect(
            pixels.sublist((y * 257 + x) * 4, (y * 257 + x + 1) * 4),
            expected,
          );
        }
      }
      expect(surface.compactions, 0);
    });
  });

  testWidgets('跨分块的部分矩形按顺序覆盖，没有接缝或丢失未更新像素', (tester) async {
    await tester.runAsync(() async {
      final surface = RdpSurface();
      addTearDown(surface.dispose);
      await surface.apply(
        RdpFrame(
          width: 256,
          height: 128,
          rgba: solid(256, 128, [255, 255, 255, 255]),
        ),
      );
      await surface.apply(
        RdpFrame(
          width: 256,
          height: 128,
          x: 127,
          y: 0,
          patchWidth: 2,
          patchHeight: 128,
          rgba: solid(2, 128, [255, 0, 0, 255]),
        ),
      );
      final pixels = await readPixels(surface);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 256; x++) {
          expect(
            pixels.sublist((y * 256 + x) * 4, (y * 256 + x + 1) * 4),
            x == 127 || x == 128 ? [255, 0, 0, 255] : [255, 255, 255, 255],
          );
        }
      }
    });
  });

  testWidgets('图集碎片有界压实并保留每个分块的最新内容', (tester) async {
    await tester.runAsync(() async {
      final surface = RdpSurface();
      addTearDown(surface.dispose);
      await surface.apply(
        RdpFrame(
          width: 512,
          height: 256,
          rgba: solid(512, 256, [255, 255, 255, 255]),
        ),
      );
      for (var i = 0; i < 16; i++) {
        final index = i % 8;
        await surface.apply(
          RdpFrame(
            width: 512,
            height: 256,
            patchWidth: 512,
            patchHeight: 256,
            rgba: solid(512, 256, [i, 0, 0, 255]),
            tiles: [
              RdpTile(
                x: index % 4 * 128,
                y: index ~/ 4 * 128,
                width: 128,
                height: 128,
                sourceX: 0,
                sourceY: 0,
              ),
            ],
          ),
        );
        expect(surface.retainedPixels, lessThanOrEqualTo(512 * 256 * 3));
      }
      expect(surface.compactions, greaterThan(0));
      final pixels = await readPixels(surface);
      for (var i = 0; i < 8; i++) {
        final at = (i ~/ 4 * 128 * 512 + i % 4 * 128) * 4;
        expect(pixels.sublist(at, at + 4), [i + 8, 0, 0, 255]);
      }
    });
  });

  testWidgets('无效图集不能覆盖有效基底，分辨率变化必须提供完整画面', (tester) async {
    await tester.runAsync(() async {
      final surface = RdpSurface();
      addTearDown(surface.dispose);
      await surface.apply(
        RdpFrame(width: 4, height: 3, rgba: solid(4, 3, [255, 255, 255, 255])),
      );
      final generation = surface.generation;
      await expectLater(
        surface.apply(
          RdpFrame(
            width: 4,
            height: 3,
            patchWidth: 1,
            patchHeight: 1,
            rgba: solid(1, 1, [0, 0, 0, 255]),
            tiles: const [
              RdpTile(x: 0, y: 0, width: 4, height: 3, sourceX: 0, sourceY: 0),
            ],
          ),
        ),
        throwsA(isA<SshEngineException>()),
      );
      await expectLater(
        surface.apply(
          RdpFrame(
            width: 256,
            height: 128,
            patchWidth: 128,
            patchHeight: 128,
            rgba: solid(128, 128, [0, 0, 0, 255]),
          ),
        ),
        throwsA(isA<SshEngineException>()),
      );
      expect(surface.generation, generation);
      expect((surface.width, surface.height), (4, 3));
      expect(await readPixels(surface), solid(4, 3, [255, 255, 255, 255]));
    });
  });

  testWidgets('解码期间销毁会释放迟到图像，不再通知监听器', (tester) async {
    await tester.runAsync(() async {
      final surface = RdpSurface();
      var notifications = 0;
      surface.addListener(() => notifications++);
      final pending = surface.apply(
        RdpFrame(
          width: 512,
          height: 256,
          rgba: solid(512, 256, [255, 255, 255, 255]),
        ),
      );
      surface.dispose();
      await pending;
      expect(notifications, 0);
      expect(surface.retainedPixels, 0);
    });
  });
}
