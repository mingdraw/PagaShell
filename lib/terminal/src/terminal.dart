import 'package:pagashell/domain/terminal/terminal_frame.dart';

import 'base/observable.dart';
import 'core/buffer/buffer.dart';
import 'core/buffer/cell_offset.dart';
import 'core/buffer/line.dart';
import 'core/cursor.dart';
import 'core/input/handler.dart';
import 'core/input/keys.dart';
import 'core/mouse/button.dart';
import 'core/mouse/button_state.dart';
import 'core/mouse/handler.dart';
import 'core/mouse/mode.dart';
import 'core/platform.dart';
import 'core/state.dart';
import 'utils/circular_buffer.dart';

/// Display and input facade. Output parsing, scrollback and reflow belong to
/// the Rust terminal module; this class only applies its ordered screen frames.
class Terminal with Observable implements TerminalState {
  Terminal({
    this.maxLines = 10000,
    this.onOutput,
    this.onResize,
    this.onBell,
    this.onTitleChange,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.wordSeparators,
  });

  final int maxLines;
  final TerminalTargetPlatform platform;
  final Set<int>? wordSeparators;
  void Function(String data)? onOutput;
  void Function(int columns, int rows, int pixelWidth, int pixelHeight)?
  onResize;
  void Function()? onBell;
  void Function(String title)? onTitleChange;
  TerminalInputHandler? inputHandler;
  TerminalMouseHandler? mouseHandler;

  int _columns = 80;
  int _rows = 24;
  int _requestedColumns = 80;
  int _requestedRows = 24;
  int _modes = (1 << 0) | (1 << 7);
  bool _cursorBlink = false;
  bool _alternate = false;
  bool _disposed = false;
  final _cursor = CursorStyle();
  late final mainBuffer = Buffer(this, isAltBuffer: false);
  late final altBuffer = Buffer(this, isAltBuffer: true);

  @override
  int get viewWidth => _columns;
  @override
  int get viewHeight => _rows;

  /// Latest requested grid size; the displayed size waits for a native frame.
  ({int columns, int rows}) get requestedSize =>
      (columns: _requestedColumns, rows: _requestedRows);
  @override
  CursorStyle get cursor => _cursor;
  Buffer get buffer => _alternate ? altBuffer : mainBuffer;
  bool get isUsingAltBuffer => _alternate;
  IndexAwareCircularBuffer<BufferLine> get lines => buffer.lines;

  bool _mode(int bit) => _modes & (1 << bit) != 0;
  @override
  bool get cursorVisibleMode => _mode(0);
  @override
  bool get cursorKeysMode => _mode(1);
  @override
  bool get appKeypadMode => _mode(2);
  @override
  bool get bracketedPasteMode => _mode(4);
  @override
  bool get autoWrapMode => _mode(7);
  @override
  bool get lineFeedMode => _mode(8);
  @override
  bool get originMode => _mode(9);
  @override
  bool get insertMode => _mode(10);
  @override
  bool get reportFocusMode => _mode(11);
  @override
  bool get reverseDisplayMode => false;
  @override
  bool get altBufferMouseScrollMode => _mode(15);
  @override
  bool get cursorBlinkMode => _cursorBlink;
  @override
  MouseMode get mouseMode => _mode(6)
      ? MouseMode.upDownScrollMove
      : _mode(13)
      ? MouseMode.upDownScrollDrag
      : _mode(3)
      ? MouseMode.upDownScroll
      : MouseMode.none;
  @override
  MouseReportMode get mouseReportMode => _mode(5)
      ? MouseReportMode.sgr
      : _mode(14)
      ? MouseReportMode.utf
      : MouseReportMode.normal;

  bool get isDisposed => _disposed;

  void applyFrame(TerminalFrame frame) {
    if (_disposed) return;
    _columns = frame.columns;
    _rows = frame.rows;
    _alternate = frame.alternate;
    buffer.applyFrame(frame);
    _modes = frame.modes;
    _cursorBlink = frame.cursorBlink;
    if (frame.title != null) onTitleChange?.call(frame.title!);
    if (frame.bell) onBell?.call();
    notifyListeners();
  }

  /// Request a native resize; wait for its frame rather than reflowing in Dart.
  void resize(int columns, int rows, [int? pixelWidth, int? pixelHeight]) {
    if (_disposed) return;
    columns = columns.clamp(2, 4096);
    rows = rows.clamp(1, 1024);
    if (columns == _requestedColumns && rows == _requestedRows) return;
    _requestedColumns = columns;
    _requestedRows = rows;
    onResize?.call(columns, rows, pixelWidth ?? 0, pixelHeight ?? 0);
  }

  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final output = inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        shift: shift,
        alt: alt,
        ctrl: ctrl,
        state: this,
        altBuffer: isUsingAltBuffer,
        platform: platform,
      ),
    );
    if (output == null) return false;
    onOutput?.call(output);
    return true;
  }

  void textInput(String text) => onOutput?.call(text);

  void paste(String text) =>
      textInput(bracketedPasteMode ? '\x1b[200~$text\x1b[201~' : text);

  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position,
  ) {
    final output = mouseHandler?.call(
      TerminalMouseEvent(
        button: button,
        buttonState: buttonState,
        position: position,
        state: this,
        platform: platform,
      ),
    );
    if (output == null) return false;
    onOutput?.call(output);
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onOutput = null;
    onResize = null;
    onBell = null;
    onTitleChange = null;
    mainBuffer.release();
    altBuffer.release();
    listeners.clear();
  }
}
