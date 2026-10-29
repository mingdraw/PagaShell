import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/ssh_engine.dart';

const _tileSize = 128;
const _invalidFrame = SshEngineException('远程桌面画面无效');

Future<ui.Image> decodeRdpPixels(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

class _Atlas {
  _Atlas(this.image);
  final ui.Image image;
  int get pixels => image.width * image.height;
}

class _Tile {
  _Tile(this.atlas, this.source, this.destination);
  final _Atlas atlas;
  final Rect source;
  final Rect destination;
}

class _AtlasBatch {
  _AtlasBatch(this.atlas, List<_Tile> tiles)
    : transforms = Float32List(tiles.length * 4),
      sources = Float32List(tiles.length * 4) {
    for (var i = 0; i < tiles.length; i++) {
      final tile = tiles[i];
      final offset = i * 4;
      // RSTransform: identity rotation/scale, translation to the output tile.
      transforms[offset] = 1;
      transforms[offset + 2] = tile.destination.left;
      transforms[offset + 3] = tile.destination.top;
      sources[offset] = tile.source.left;
      sources[offset + 1] = tile.source.top;
      sources[offset + 2] = tile.source.right;
      sources[offset + 3] = tile.source.bottom;
    }
  }
  final _Atlas atlas;
  final Float32List transforms;
  final Float32List sources;
}

/// One upload per native atlas, then GPU source-rectangle draws. Updates must be
/// applied serially. Unchanged tiles keep their image; no per-update full-screen
/// Picture.toImage is needed. Retained atlas storage is bounded by compaction.
class RdpSurface extends ChangeNotifier {
  int width = 0;
  int height = 0;
  int generation = 0;
  int compactions = 0;
  List<_Tile?> _tiles = [];
  final Set<_Atlas> _atlases = {};
  List<_AtlasBatch> _batches = [];
  bool _disposed = false;

  int get retainedPixels =>
      _atlases.fold(0, (sum, atlas) => sum + atlas.pixels);
  bool get hasImage => width > 0;

  Future<void> apply(RdpFrame frame) async {
    if (_disposed) return;
    if (frame.width < 1 ||
        frame.height < 1 ||
        frame.width * frame.height > 16777216 ||
        frame.patchWidth < 0 ||
        frame.patchHeight < 0 ||
        frame.rgba.length != frame.patchWidth * frame.patchHeight * 4) {
      throw _invalidFrame;
    }
    if (frame.rgba.isEmpty) {
      if (frame.tiles.isNotEmpty) throw _invalidFrame;
      return;
    }
    final regions = frame.tiles.isEmpty
        ? [
            RdpTile(
              x: frame.x,
              y: frame.y,
              width: frame.patchWidth,
              height: frame.patchHeight,
              sourceX: 0,
              sourceY: 0,
            ),
          ]
        : frame.tiles;
    for (final region in regions) {
      if (region.x < 0 ||
          region.y < 0 ||
          region.width < 1 ||
          region.height < 1 ||
          region.x + region.width > frame.width ||
          region.y + region.height > frame.height ||
          region.sourceX < 0 ||
          region.sourceY < 0 ||
          region.sourceX + region.width > frame.patchWidth ||
          region.sourceY + region.height > frame.patchHeight) {
        throw _invalidFrame;
      }
    }
    final created = <_Atlas>{};
    var transferred = false;
    try {
      final atlas = _Atlas(
        await decodeRdpPixels(frame.rgba, frame.patchWidth, frame.patchHeight),
      );
      created.add(atlas);
      if (_disposed) return;
      final resized = width != frame.width || height != frame.height;
      final columns = (frame.width + _tileSize - 1) ~/ _tileSize;
      final rows = (frame.height + _tileSize - 1) ~/ _tileSize;
      final next = resized
          ? List<_Tile?>.filled(columns * rows, null)
          : List<_Tile?>.of(_tiles);
      for (final region in regions) {
        final target = Rect.fromLTWH(
          region.x.toDouble(),
          region.y.toDouble(),
          region.width.toDouble(),
          region.height.toDouble(),
        );
        for (
          var y = region.y ~/ _tileSize;
          y <= (region.y + region.height - 1) ~/ _tileSize;
          y++
        ) {
          for (
            var x = region.x ~/ _tileSize;
            x <= (region.x + region.width - 1) ~/ _tileSize;
            x++
          ) {
            final index = y * columns + x;
            final destination = Rect.fromLTWH(
              (x * _tileSize).toDouble(),
              (y * _tileSize).toDouble(),
              math.min(_tileSize, frame.width - x * _tileSize).toDouble(),
              math.min(_tileSize, frame.height - y * _tileSize).toDouble(),
            );
            final overlap = destination.intersect(target);
            final source = overlap.shift(
              Offset(
                (region.sourceX - region.x).toDouble(),
                (region.sourceY - region.y).toDouble(),
              ),
            );
            if (overlap == destination) {
              // Native atlas entries always cover a complete tile, including
              // the clipped right/bottom edges. This path does no rasterization.
              next[index] = _Tile(atlas, source, destination);
            } else {
              // Single-rectangle providers can also submit sub-tile updates.
              // Only that tile is flattened; native atlas frames skip this path.
              final previous = next[index];
              if (previous == null) throw _invalidFrame;
              final recorder = ui.PictureRecorder();
              final canvas = ui.Canvas(recorder);
              canvas.drawImageRect(
                previous.atlas.image,
                previous.source,
                Rect.fromLTWH(0, 0, destination.width, destination.height),
                ui.Paint(),
              );
              canvas.drawImageRect(
                atlas.image,
                source,
                overlap.shift(-destination.topLeft),
                ui.Paint()..blendMode = ui.BlendMode.src,
              );
              final picture = recorder.endRecording();
              late final ui.Image image;
              try {
                image = await picture.toImage(
                  destination.width.toInt(),
                  destination.height.toInt(),
                );
              } finally {
                picture.dispose();
              }
              final merged = _Atlas(image);
              created.add(merged);
              if (_disposed) return;
              next[index] = _Tile(
                merged,
                Rect.fromLTWH(0, 0, destination.width, destination.height),
                destination,
              );
            }
          }
        }
      }
      // Resizes and the first frame must establish every tile before publishing.
      if (next.any((tile) => tile == null)) throw _invalidFrame;
      width = frame.width;
      height = frame.height;
      _tiles = next;
      _atlases.addAll(created);
      transferred = true;
      _releaseUnused();
      _rebuildBatches();
      if (retainedPixels > width * height * 3) await _compact();
      if (!_disposed) {
        generation++;
        notifyListeners();
      }
    } finally {
      if (!transferred) {
        for (final atlas in created) {
          atlas.image.dispose();
        }
      }
    }
  }

  void _releaseUnused() {
    final used = {
      for (final tile in _tiles)
        if (tile != null) tile.atlas,
    };
    for (final atlas in _atlases.difference(used)) {
      atlas.image.dispose();
    }
    _atlases.removeWhere((atlas) => !used.contains(atlas));
  }

  void _rebuildBatches() {
    final groups = <_Atlas, List<_Tile>>{};
    for (final tile in _tiles) {
      if (tile != null) (groups[tile.atlas] ??= []).add(tile);
    }
    _batches = [
      for (final entry in groups.entries) _AtlasBatch(entry.key, entry.value),
    ];
  }

  Future<void> _compact() async {
    // A mostly-replaced large atlas can be pinned by one unchanged tile. Bound
    // that fragmentation instead of retaining every historical GPU allocation.
    final recorder = ui.PictureRecorder();
    paint(ui.Canvas(recorder));
    final picture = recorder.endRecording();
    late final ui.Image image;
    try {
      image = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
    if (_disposed) {
      image.dispose();
      return;
    }
    final atlas = _Atlas(image);
    _tiles = [
      for (final tile in _tiles)
        _Tile(atlas, tile!.destination, tile.destination),
    ];
    _atlases.add(atlas);
    _releaseUnused();
    _rebuildBatches();
    compactions++;
  }

  void paint(ui.Canvas canvas) {
    final paint = ui.Paint()
      ..filterQuality = FilterQuality.low
      ..isAntiAlias = false;
    if (_atlases.length == 1) {
      final image = _atlases.single.image;
      if (image.width == width &&
          image.height == height &&
          _tiles.every(
            (tile) => tile != null && tile.source == tile.destination,
          )) {
        canvas.drawImage(image, Offset.zero, paint);
        return;
      }
    }
    // Submit one sprite batch per retained atlas instead of crossing into the
    // engine separately for every 128-pixel tile.
    for (final batch in _batches) {
      canvas.drawRawAtlas(
        batch.atlas.image,
        batch.transforms,
        batch.sources,
        null,
        null,
        null,
        paint,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tiles = [];
    _batches = [];
    for (final atlas in _atlases) {
      atlas.image.dispose();
    }
    _atlases.clear();
    super.dispose();
  }
}

class RdpSurfacePainter extends CustomPainter {
  RdpSurfacePainter(this.surface) : super(repaint: surface);
  final RdpSurface surface;

  @override
  void paint(Canvas canvas, Size size) => surface.paint(canvas);
  @override
  bool shouldRepaint(RdpSurfacePainter oldDelegate) =>
      oldDelegate.surface != surface;
}
