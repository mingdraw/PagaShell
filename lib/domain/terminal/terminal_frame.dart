import 'dart:typed_data';

/// Session capability supplying ordered screen deltas from the Rust core.
abstract interface class TerminalScreenSource {
  Stream<TerminalFrame> startTerminalShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
  });

  /// Release the next native frame only after the current frame is applied.
  Future<void> acknowledgeTerminalFrame(int frameId);
}

/// Apply every frame in order to the active main or alternate buffer.
///
/// Update [lines], remove [trimFront] rows from the old order, retain its first
/// [keepRows] rows, then append [appendRows]. IDs live for one native core only.
class TerminalFrame {
  const TerminalFrame({
    required this.columns,
    required this.rows,
    required this.alternate,
    required this.cursorX,
    required this.cursorY,
    required this.modes,
    required this.cursorBlink,
    required this.trimFront,
    required this.keepRows,
    required this.appendRows,
    required this.lines,
    this.title,
    this.bell = false,
    this.frameId = 0,
  });

  /// Native transport sequence. Synthetic test frames use zero.
  final int frameId;
  final int columns;
  final int rows;
  final bool alternate;
  final int cursorX;
  final int cursorY;

  /// TermMode bits from the pinned official alacritty_terminal 0.26.0.
  final int modes;
  final bool cursorBlink;
  final int trimFront;
  final int keepRows;
  final List<int> appendRows;
  final List<TerminalLine> lines;
  final String? title;
  final bool bell;
}

class TerminalLine {
  const TerminalLine({
    required this.id,
    required this.wrapped,
    required this.cells,
    this.clusters = const {},
  });

  final int id;
  final bool wrapped;

  /// Foreground, background, attributes and packed codepoint/width per column.
  final Uint32List cells;
  final Map<int, String> clusters;
}
