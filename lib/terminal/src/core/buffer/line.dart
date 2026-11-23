import 'dart:typed_data';

import 'package:pagashell/domain/terminal/terminal_frame.dart';

import '../../utils/circular_buffer.dart';
import '../cell.dart';
import 'cell_offset.dart';

/// One native row, retaining its selection anchors while its ID remains alive.
class BufferLine with IndexedItem {
  BufferLine(int length, {this.id = 0})
    : _length = length,
      _data = Uint32List(length * 4);

  /// 直接接管新帧分配的只读单元格数据，避免先创建空缓冲再立刻丢弃。
  BufferLine.fromFrame(TerminalLine update, int columns)
    : id = update.id,
      _length = columns,
      _data = update.cells,
      _clusters = update.clusters,
      isWrapped = update.wrapped,
      _version = 1;

  final int id;
  int _length;
  Uint32List _data;
  Map<int, String> _clusters = const {};
  bool isWrapped = false;
  final _anchors = <CellAnchor>[];

  int get length => _length;
  Uint32List get data => _data;

  /// 内容版本，每次 [update] 递增；绘制层据此判断行缓存是否失效。
  int get version => _version;
  int _version = 0;
  int getForeground(int index) => _data[index * 4];
  int getBackground(int index) => _data[index * 4 + 1];
  int getAttributes(int index) => _data[index * 4 + 2];
  int getContent(int index) => _data[index * 4 + 3];
  int getCodePoint(int index) => getContent(index) & CellContent.codepointMask;
  int getWidth(int index) => getContent(index) >> CellContent.widthShift;

  void update(TerminalLine update, int columns) {
    _length = columns;
    // 帧数据只读且每帧新分配，直接持有，不再复制一份。
    _data = update.cells;
    _clusters = update.clusters;
    isWrapped = update.wrapped;
    _cachedText = null;
    _version++;
  }

  void getCellData(int index, CellData cell) {
    cell.foreground = getForeground(index);
    cell.background = getBackground(index);
    cell.flags = getAttributes(index);
    cell.content = getContent(index);
    cell.text = _clusters[index];
  }

  String? _cachedText;

  String getText([int? from, int? to]) {
    final start = (from ?? 0).clamp(0, length);
    final end = (to ?? length).clamp(0, length);
    if (start == 0 && end == length && _cachedText != null) return _cachedText!;
    final text = StringBuffer();
    final clusters = _clusters;
    if (clusters.isEmpty) {
      for (var i = start; i < end; i++) {
        final content = _data[i * 4 + 3];
        final codepoint = content & CellContent.codepointMask;
        if (codepoint != 0 && i + (content >> CellContent.widthShift) <= end) {
          text.writeCharCode(codepoint);
        }
      }
    } else {
      for (var i = start; i < end; i++) {
        final content = _data[i * 4 + 3];
        final codepoint = content & CellContent.codepointMask;
        if (codepoint != 0 && i + (content >> CellContent.widthShift) <= end) {
          final cluster = clusters[i];
          if (cluster != null) {
            text.write(cluster);
          } else {
            text.writeCharCode(codepoint);
          }
        }
      }
    }
    final result = text.toString();
    if (start == 0 && end == length) _cachedText = result;
    return result;
  }

  /// Maps a UTF-16 match boundary back to the terminal cell grid.
  int columnForTextOffset(int offset, {bool exclusive = false}) {
    var units = 0;
    for (var index = 0; index < length; index++) {
      final codepoint = getCodePoint(index);
      final width = getWidth(index);
      if (codepoint == 0 || index + width > length) continue;
      final end =
          units + (_clusters[index]?.length ?? (codepoint > 0xffff ? 2 : 1));
      if (offset < end || (exclusive && offset == end)) {
        return exclusive ? index + width.clamp(1, length - index) : index;
      }
      units = end;
    }
    return length;
  }

  CellAnchor createAnchor(int offset) {
    final anchor = CellAnchor(offset, owner: this);
    _anchors.add(anchor);
    return anchor;
  }

  void dispose() {
    if (_anchors.isEmpty) return;
    for (final anchor in List<CellAnchor>.of(_anchors)) {
      anchor.dispose();
    }
  }

  @override
  String toString() => getText();
}

class CellAnchor {
  CellAnchor(int offset, {this._owner}) : _offset = offset;

  int _offset;
  BufferLine? _owner;
  int get x => _offset;
  int get y {
    assert(attached);
    return _owner!.index;
  }

  CellOffset get offset {
    assert(attached);
    return CellOffset(_offset, _owner!.index);
  }

  BufferLine? get line => _owner;
  bool get attached => _owner?.attached ?? false;

  void reparent(BufferLine owner, int offset) {
    _owner?._anchors.remove(this);
    _owner = owner;
    _owner!._anchors.add(this);
    _offset = offset;
  }

  void reposition(int offset) => _offset = offset;
  void dispose() {
    _owner?._anchors.remove(this);
    _owner = null;
  }

  @override
  String toString() =>
      attached ? 'CellAnchor($x, $y)' : 'CellAnchor($x, detached)';
}
