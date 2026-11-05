import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pagashell/terminal/paga_terminal.dart';

export 'package:pagashell/terminal/paga_terminal.dart';

/// Synthetic ASCII screen frames for application/layout tests, without an ANSI
/// parser or native build. Escape sequences, Unicode and native reflow semantics
/// must be tested using Rust-generated fixtures instead.
class TerminalFrameFixture {
  TerminalFrameFixture({
    this._columns = 80,
    this._rows = 24,
    this.scrollback = 10000,
  }) {
    _lines = List.generate(_rows, (_) => _newLine());
  }

  final int scrollback;
  int _columns;
  int _rows;
  int _column = 0;
  int _cursorLine = 0;
  int _nextId = 1;
  int _modes = (1 << 0) | (1 << 7);
  bool _alternate = false;
  late List<_FixtureLine> _lines;

  _FixtureLine _newLine() => _FixtureLine(_nextId++, _emptyCells(_columns));

  static Uint32List _emptyCells(int columns) {
    final cells = Uint32List(columns * 4);
    for (var column = 0; column < columns; column++) {
      cells[column * 4 + 3] = 1 << 22;
    }
    return cells;
  }

  /// Append plain fixture text. Colors are packed frame values, not ANSI input.
  TerminalFrame writeText(
    String text, {
    int foreground = 0,
    int background = 0,
  }) {
    final characters = text.codeUnits;
    if (characters.any((c) => c != 10 && c != 13 && (c < 32 || c > 126))) {
      throw ArgumentError(
        'Use a Rust-generated fixture for ANSI or Unicode output',
      );
    }
    for (final character in characters) {
      if (character == 13) {
        _column = 0;
      } else if (character == 10) {
        _nextLine();
      } else {
        if (_column == _columns) {
          _column = 0;
          _nextLine(wrapped: true);
        }
        final offset = _column++ * 4;
        final cells = _lines[_cursorLine].cells;
        cells[offset] = foreground;
        cells[offset + 1] = background;
        cells[offset + 3] = character | (1 << 22);
      }
    }
    return snapshot();
  }

  void _nextLine({bool wrapped = false}) {
    _cursorLine++;
    if (_cursorLine == _lines.length) _lines.add(_newLine());
    _lines[_cursorLine].wrapped = wrapped;
    _trimHistory();
  }

  void _trimHistory() {
    final excess = _lines.length - (_rows + (_alternate ? 0 : scrollback));
    if (excess > 0) {
      _lines.removeRange(0, excess);
      _cursorLine -= excess;
    }
  }

  /// Adapt synthetic rows to a test viewport; this does not emulate ANSI reflow.
  void resize(int columns, int rows) {
    final history = _lines.length - _rows;
    for (final line in _lines) {
      final cells = _emptyCells(columns);
      cells.setRange(0, math.min(cells.length, line.cells.length), line.cells);
      line.cells = cells;
    }
    if (rows < _rows) {
      final length = math.max(_cursorLine + 1, history + rows);
      if (length < _lines.length) _lines.removeRange(length, _lines.length);
    }
    _columns = columns;
    _rows = rows;
    while (_lines.length < rows) {
      _lines.add(_newLine());
    }
    _column = math.min(_column, columns);
    _trimHistory();
  }

  TerminalFrame showAlternateScreen() {
    if (!_alternate) {
      _alternate = true;
      _lines = List.generate(_rows, (_) => _newLine());
      _column = 0;
      _cursorLine = 0;
    }
    return snapshot();
  }

  TerminalFrame setBracketedPaste(bool enabled) {
    _modes = enabled ? _modes | (1 << 4) : _modes & ~(1 << 4);
    return snapshot();
  }

  TerminalFrame snapshot() => TerminalFrame(
    columns: _columns,
    rows: _rows,
    alternate: _alternate,
    cursorX: _column.clamp(0, _columns - 1),
    cursorY: (_cursorLine - (_lines.length - _rows)).clamp(0, _rows - 1),
    modes: _modes,
    cursorBlink: false,
    trimFront: 0,
    keepRows: 0,
    appendRows: [for (final line in _lines) line.id],
    lines: [
      for (final line in _lines)
        TerminalLine(
          id: line.id,
          wrapped: line.wrapped,
          cells: Uint32List.fromList(line.cells),
        ),
    ],
  );

  Stream<TerminalFrame> decode(Stream<String> stream) => stream.map(writeText);
}

class _FixtureLine {
  _FixtureLine(this.id, this.cells);

  final int id;
  Uint32List cells;
  bool wrapped = false;
}

final _fixtures = Expando<TerminalFrameFixture>();

extension TerminalFixtureOutput on Terminal {
  TerminalFrameFixture get _fixture {
    var fixture = _fixtures[this];
    if (fixture == null) {
      fixture = TerminalFrameFixture(
        columns: requestedSize.columns,
        rows: requestedSize.rows,
        scrollback: maxLines,
      );
      _fixtures[this] = fixture;
      final previous = onResize;
      final source = fixture;
      onResize = (columns, rows, width, height) {
        previous?.call(columns, rows, width, height);
        source.resize(columns, rows);
        // Native frames arrive asynchronously; do not mutate the render object
        // while its layout is requesting a new PTY size.
        scheduleMicrotask(() => applyFrame(source.snapshot()));
      };
    }
    return fixture;
  }

  void writeText(String text, {int foreground = 0, int background = 0}) =>
      applyFrame(
        _fixture.writeText(
          text,
          foreground: foreground,
          background: background,
        ),
      );

  void showAlternateScreen() => applyFrame(_fixture.showAlternateScreen());

  void setBracketedPaste(bool enabled) =>
      applyFrame(_fixture.setBracketedPaste(enabled));
}
