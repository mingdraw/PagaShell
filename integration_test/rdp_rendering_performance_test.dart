import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_surface.dart';

// Local synthetic decode + composition + offscreen GPU rendering comparison.
// It excludes RDP/network/Windows codec cost and is not a screen FPS benchmark.
class _PreviousCompositor {
  ui.Image? image;

  Future<void> apply(RdpFrame frame) async {
    final patch = await decodeRdpPixels(
      frame.rgba,
      frame.patchWidth,
      frame.patchHeight,
    );
    final previous = image;
    if (frame.patchWidth == frame.width && frame.patchHeight == frame.height) {
      image = patch;
    } else {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(previous!, Offset.zero, ui.Paint());
      canvas.drawImage(
        patch,
        Offset(frame.x.toDouble(), frame.y.toDouble()),
        ui.Paint()..blendMode = ui.BlendMode.src,
      );
      final picture = recorder.endRecording();
      try {
        image = await picture.toImage(frame.width, frame.height);
      } finally {
        picture.dispose();
        patch.dispose();
      }
    }
    previous?.dispose();
  }

  final _paint = ui.Paint()..filterQuality = ui.FilterQuality.low;

  void paint(ui.Canvas canvas) => canvas.drawImage(image!, Offset.zero, _paint);
  void dispose() => image?.dispose();
}

Uint8List _pixels(int width, int height, int value) {
  final result = Uint8List(width * height * 4);
  for (var i = 0; i < result.length; i += 4) {
    result[i] = value;
    result[i + 1] = (i ~/ 4) % 256;
    result[i + 2] = 255 - value;
    result[i + 3] = 255;
  }
  return result;
}

// Prepare the same post-update pixels in the native 128-pixel tile format,
// including its one-pixel gutters. Fixture preparation is outside timing.
RdpFrame _nativeAtlas(
  RdpFrame patch,
  Uint8List initial, {
  List<(int, int)>? dirty,
}) {
  final full = Uint8List.fromList(initial);
  for (var row = 0; row < patch.patchHeight; row++) {
    final from = row * patch.patchWidth * 4;
    final to = ((patch.y + row) * 1280 + patch.x) * 4;
    full.setRange(to, to + patch.patchWidth * 4, patch.rgba, from);
  }
  final coordinates =
      dirty ??
      [
        for (var y = patch.y; y < patch.y + patch.patchHeight; y += 128)
          for (var x = patch.x; x < patch.x + patch.patchWidth; x += 128)
            (x, y),
      ];
  final complete = coordinates.length == 70;
  if (complete) {
    return RdpFrame(width: 1280, height: 800, rgba: full);
  }
  final candidates =
      [
        for (
          var columns = 1;
          columns <= coordinates.length && columns <= 32;
          columns++
        )
          if ((coordinates.length + columns - 1) ~/ columns <= columns * 4 &&
              columns <= ((coordinates.length + columns - 1) ~/ columns) * 4)
            columns,
      ]..sort((a, b) {
        final rowsA = (coordinates.length + a - 1) ~/ a;
        final rowsB = (coordinates.length + b - 1) ~/ b;
        final space = (a * rowsA).compareTo(b * rowsB);
        if (space != 0) return space;
        final shape = (a - rowsA).abs().compareTo((b - rowsB).abs());
        return shape != 0 ? shape : b.compareTo(a);
      });
  final columns = candidates.first;
  final bitmapWidth = columns * 130;
  final bitmapHeight = ((coordinates.length + columns - 1) ~/ columns) * 130;
  final pixels = Uint8List(bitmapWidth * bitmapHeight * 4);
  final tiles = <RdpTile>[];
  for (var i = 0; i < coordinates.length; i++) {
    final (x, y) = coordinates[i];
    final width = (1280 - x).clamp(0, 128);
    final height = (800 - y).clamp(0, 128);
    final sourceX = (i % columns) * 130 + 1;
    final sourceY = (i ~/ columns) * 130 + 1;
    for (var row = -1; row <= height; row++) {
      for (var col = -1; col <= width; col++) {
        final from =
            ((y + row).clamp(0, 799) * 1280 + (x + col).clamp(0, 1279)) * 4;
        final to = ((sourceY + row) * bitmapWidth + sourceX + col) * 4;
        pixels.setRange(to, to + 4, full, from);
      }
    }
    tiles.add(
      RdpTile(
        x: x,
        y: y,
        width: width,
        height: height,
        sourceX: sourceX,
        sourceY: sourceY,
      ),
    );
  }
  return RdpFrame(
    width: 1280,
    height: 800,
    rgba: pixels,
    patchWidth: bitmapWidth,
    patchHeight: bitmapHeight,
    tiles: tiles,
  );
}

Uint8List _sparsePixels(Uint8List initial, int value) {
  final pixels = Uint8List(1201 * 731 * 4);
  for (var row = 0; row < 731; row++) {
    pixels.setRange(
      row * 1201 * 4,
      (row + 1) * 1201 * 4,
      initial,
      ((row + 20) * 1280 + 10) * 4,
    );
  }
  for (final (left, top, width, height) in [
    (10, 20, 10, 10),
    (1200, 740, 11, 11),
  ]) {
    for (var y = top; y < top + height; y++) {
      for (var x = left; x < left + width; x++) {
        final index = ((y - 20) * 1201 + x - 10) * 4;
        pixels[index] = value;
        pixels[index + 2] = 255 - value;
      }
    }
  }
  return pixels;
}

Future<void> _render(void Function(ui.Canvas) paint, double scale) async {
  final recorder = ui.PictureRecorder();
  paint(ui.Canvas(recorder)..scale(scale));
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      (1280 * scale).round(),
      (800 * scale).round(),
    );
    image.dispose();
  } finally {
    picture.dispose();
  }
}

Map<String, int> _timings(List<int> micros) {
  micros.sort();
  return {
    'total_us': micros.fold(0, (total, sample) => total + sample),
    'p50_us': micros[(micros.length * 0.50).ceil() - 1],
    'p95_us': micros[(micros.length * 0.95).ceil() - 1],
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('RDP renderer comparison on the native Flutter engine', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('RDP local rendering benchmark')),
      ),
    );
    final reports = <Map<String, Object>>[];
    await tester.runAsync(() async {
      final initial = RdpFrame(
        width: 1280,
        height: 800,
        rgba: _pixels(1280, 800, 0),
      );
      for (final scenario in [
        (128, 128, 'localized', 1.0),
        (1024, 512, 'scrolling', 1.0),
        (1280, 800, 'full', 1.0),
        (1201, 731, 'sparse', 1.0),
        (1024, 512, 'scaled_scrolling', 0.375),
        (128, 128, 'rotating_tiles', 1.0),
      ]) {
        final (width, height, name, scale) = scenario;
        final rotating = name == 'rotating_tiles';
        final frames = [
          for (var index = 0; index < (rotating ? 20 : 2); index++)
            () {
              final value = index.isEven ? 64 : 192;
              final previous = RdpFrame(
                width: 1280,
                height: 800,
                x: switch (name) {
                  'rotating_tiles' => index % 10 * 128,
                  'sparse' => 10,
                  'full' => 0,
                  _ => 128,
                },
                y: switch (name) {
                  'rotating_tiles' => index ~/ 10 * 128,
                  'sparse' => 20,
                  _ => 0,
                },
                patchWidth: width,
                patchHeight: height,
                rgba: name == 'sparse'
                    ? _sparsePixels(initial.rgba, value)
                    : _pixels(width, height, value),
              );
              return (
                previous: previous,
                atlas: _nativeAtlas(
                  previous,
                  initial.rgba,
                  dirty: name == 'sparse' ? [(0, 0), (1152, 640)] : null,
                ),
              );
            }(),
        ];
        final previous = _PreviousCompositor();
        final surface = RdpSurface();
        try {
          await previous.apply(initial);
          await surface.apply(initial);
          // Warm both paths, then alternate measurement order across rounds.
          for (var i = 0; i < 4; i++) {
            await previous.apply(frames[i % frames.length].previous);
            await _render(previous.paint, scale);
            await surface.apply(frames[i % frames.length].atlas);
            await _render(surface.paint, scale);
          }
          const rounds = 4;
          const updatesPerRound = 20;
          final previousUs = <int>[];
          final atlasUs = <int>[];
          final compactingUs = <int>[];
          final started = DateTime.now().toUtc();
          for (var round = 0; round < rounds; round++) {
            for (final useAtlas
                in round.isEven ? [false, true] : [true, false]) {
              for (var i = 0; i < updatesPerRound; i++) {
                final compactionsBefore = surface.compactions;
                final update = frames[i % frames.length];
                final clock = Stopwatch()..start();
                if (useAtlas) {
                  await surface.apply(update.atlas);
                  await _render(surface.paint, scale);
                  atlasUs.add(clock.elapsedMicroseconds);
                  if (surface.compactions != compactionsBefore) {
                    compactingUs.add(atlasUs.last);
                  }
                } else {
                  await previous.apply(update.previous);
                  await _render(previous.paint, scale);
                  previousUs.add(clock.elapsedMicroseconds);
                }
              }
            }
          }
          reports.add({
            'scenario': name,
            'scale': scale,
            'updates_per_path': rounds * updatesPerRound,
            'started_utc': started.toIso8601String(),
            'finished_utc': DateTime.now().toUtc().toIso8601String(),
            'previous': _timings(previousUs),
            'atlas': _timings(atlasUs),
            'atlas_compacting': compactingUs.isEmpty
                ? {}
                : _timings(compactingUs),
            'previous_bytes_per_update': frames[0].previous.rgba.length,
            'atlas_bytes_per_update': frames[0].atlas.rgba.length,
            'compactions': surface.compactions,
            'retained_pixels': surface.retainedPixels,
          });
          if (rotating) expect(compactingUs, isNotEmpty);
        } finally {
          previous.dispose();
          surface.dispose();
        }
      }
    });
    binding.reportData = {'rdp_rendering': reports};
    debugPrint('RDP_RENDERING_BENCHMARK ${jsonEncode(reports)}');
    expect(reports, hasLength(6));
  });
}
