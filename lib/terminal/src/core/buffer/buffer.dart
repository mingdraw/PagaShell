import 'package:pagashell/domain/terminal/terminal_frame.dart';

import '../../terminal.dart';
import '../../utils/circular_buffer.dart';
import 'cell_offset.dart';
import 'line.dart';
import 'range.dart';
import 'range_line.dart';

/// Incremental read model. Row lifetime/order is supplied by the Rust core.
class Buffer {
  Buffer(this.terminal, {required this.isAltBuffer}) {
    for (var i = 0; i < terminal.viewHeight; i++) {
      lines.push(BufferLine(terminal.viewWidth));
    }
  }

  final Terminal terminal;
  final bool isAltBuffer;
  late final lines = IndexAwareCircularBuffer<BufferLine>(
    terminal.maxLines + 1024,
  );
  final Map<int, BufferLine> _byId = {};
  int _cursorColumn = 0;
  int _cursorRow = 0;

  int get viewWidth => terminal.viewWidth;
  int get viewHeight => terminal.viewHeight;
  int get height => lines.length;
  int get cursorX => _cursorColumn.clamp(0, viewWidth - 1);
  int get cursorY => _cursorRow.clamp(0, viewHeight - 1);
  int get scrollBack => height - viewHeight;
  int get absoluteCursorY => cursorY + scrollBack;

  void applyFrame(TerminalFrame frame) {
    for (final update in frame.lines) {
      final line = _byId.putIfAbsent(
        update.id,
        () => BufferLine(frame.columns, id: update.id),
      );
      line.update(update, frame.columns);
    }
    // 只更新行内容的帧（最常见）不改变行序，不分配 removed 列表。
    if (frame.trimFront > 0 ||
        lines.length > frame.keepRows ||
        frame.appendRows.isNotEmpty) {
      final removed = <BufferLine>[
        for (var i = 0; i < frame.trimFront; i++) lines[i],
      ];
      lines.trimStart(frame.trimFront);
      while (lines.length > frame.keepRows) {
        removed.add(lines.pop());
      }
      for (final id in frame.appendRows) {
        lines.push(_byId[id]!);
      }
      for (final line in removed) {
        if (!line.attached) {
          line.dispose();
          _byId.remove(line.id);
        }
      }
    }
    _cursorColumn = frame.cursorX;
    _cursorRow = frame.cursorY;
  }

  CellAnchor createAnchor(int x, int y) => lines[y].createAnchor(x);
  CellAnchor createAnchorFromOffset(CellOffset offset) =>
      createAnchor(offset.x, offset.y);
  CellAnchor createAnchorFromCursor() => createAnchor(cursorX, absoluteCursorY);

  static final defaultWordSeparators = <int>{
    0,
    32,
    46,
    58,
    45,
    92,
    34,
    42,
    43,
    47,
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    if (position.y < 0 || position.y >= lines.length) return null;
    final separators = terminal.wordSeparators ?? defaultWordSeparators;
    final line = lines[position.y];
    var start = position.x.clamp(0, line.length);
    var end = start;
    while (start > 0 && !separators.contains(line.getCodePoint(start - 1))) {
      start--;
    }
    while (end < line.length && !separators.contains(line.getCodePoint(end))) {
      end++;
    }
    if (start == end) return null;
    return BufferRangeLine(
      CellOffset(start, position.y),
      CellOffset(end, position.y),
    );
  }

  String getText([BufferRange? range]) {
    if (height == 0) return '';
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth, height - 1),
    );
    final normalized = range.normalized;
    final builder = StringBuffer();
    for (final segment in normalized.toSegments()) {
      if (segment.line < 0 || segment.line >= height) continue;
      final line = lines[segment.line];
      if (segment.line != normalized.begin.y &&
          segment.line != 0 &&
          !line.isWrapped) {
        builder.write('\n');
      }
      builder.write(line.getText(segment.start, segment.end));
    }
    return builder.toString();
  }

  void release() {
    lines.forEach((line) => line.dispose());
    lines.clear();
    _byId.clear();
  }
}
