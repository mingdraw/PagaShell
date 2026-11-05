import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pagashell/terminal/src/core/buffer/cell_offset.dart';
import 'package:pagashell/terminal/src/core/buffer/line.dart';
import 'package:pagashell/terminal/src/core/buffer/range.dart';
import 'package:pagashell/terminal/src/core/buffer/segment.dart';
import 'package:pagashell/terminal/src/core/mouse/button.dart';
import 'package:pagashell/terminal/src/core/mouse/button_state.dart';
import 'package:pagashell/terminal/src/terminal.dart';
import 'package:pagashell/terminal/src/ui/controller.dart';
import 'package:pagashell/terminal/src/ui/cursor_type.dart';
import 'package:pagashell/terminal/src/ui/painter.dart';
import 'package:pagashell/terminal/src/ui/selection_mode.dart';
import 'package:pagashell/terminal/src/ui/terminal_size.dart';
import 'package:pagashell/terminal/src/ui/terminal_text_style.dart';
import 'package:pagashell/terminal/src/ui/terminal_theme.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required this._terminal,
    required this._controller,
    required this._offset,
    required this._padding,
    required this._autoResize,
    this._resizeSuspended = false,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required this._focusNode,
    required this._cursorType,
    required this._alwaysShowCursor,
    this._onEditableRect,
    this._composingText,
  }) : _painter = TerminalPainter(
         theme: theme,
         textStyle: textStyle,
         textScaler: textScaler,
       );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    // 新终端尚未收到过尺寸，跳过节流立即同步。
    _hasResized = false;
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  /// 后台标签（[TickerMode] 关闭）暂缓向 PTY 同步尺寸，回到前台时补发。
  ///
  /// 宽度变化会让 Rust 内核重排并重传整份回滚；侧边栏动画、拖拽调宽时
  /// 所有常驻终端每帧都会重新布局，逐帧同步的代价随标签数线性增长。
  bool _resizeSuspended;
  set resizeSuspended(bool value) {
    if (value == _resizeSuspended) return;
    _resizeSuspended = value;
    if (!value && _resizePending) _resizeTerminalIfNeeded();
  }

  /// 两次向 PTY 同步尺寸的最小间隔；首次立即同步，间隔内的变化合并为一次。
  static const resizeInterval = Duration(milliseconds: 150);
  Timer? _resizeCooldown;
  bool _resizePending = false;
  bool _hasResized = false;

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  /// 按行录制的绘制结果，只保留上一次绘制时可见的行。行内容
  /// （[BufferLine.version]）或绘制配置（[TerminalPainter.generation]）
  /// 未变时直接重放，滚动、光标移动和局部输出不再逐格重绘整个视口。
  Map<BufferLine, _LinePicture> _linePictures = Map.identity();
  int _linePicturesGeneration = 0;

  /// 当前缓存的行数，供测试观察。
  @visibleForTesting
  int get cachedLinePictureCount => _linePictures.length;

  /// 累计录制的行数，供测试确认未变化的行被复用。
  @visibleForTesting
  int linePictureRecordCount = 0;

  Picture _linePicture(BufferLine line, Map<BufferLine, _LinePicture> next) {
    final cached = _linePictures.remove(line);
    if (cached != null && cached.version == line.version) {
      next[line] = cached;
      return cached.picture;
    }
    cached?.picture.dispose();
    final recorder = PictureRecorder();
    _painter.paintLine(Canvas(recorder), Offset.zero, line);
    final picture = recorder.endRecording();
    linePictureRecordCount++;
    next[line] = _LinePicture(line.version, picture);
    return picture;
  }

  void _disposeLinePictures() {
    for (final entry in _linePictures.values) {
      entry.picture.dispose();
    }
    _linePictures = Map.identity();
  }

  @override
  void dispose() {
    _resizeCooldown?.cancel();
    _disposeLinePictures();
    _painter.dispose();
    super.dispose();
  }

  var _stickToBottom = true;

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    markNeedsLayout();
    _scheduleEditableRect();
  }

  void _onFocusChange() {
    markNeedsPaint();
  }

  /// 上次布局时的行数。布局只依赖行数（滚动范围、贴底）与尺寸，
  /// 行数不变的帧只需重绘。
  int _layoutLineCount = -1;

  void _onTerminalChange() {
    if (_terminal.buffer.lines.length != _layoutLineCount) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
    _scheduleEditableRect();
  }

  // 选区与高亮只影响绘制。
  void _onControllerUpdate() {
    markNeedsPaint();
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
    if (_resizePending) _resizeTerminalIfNeeded();
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
    // 未发出的尺寸保留在 _resizePending，重新挂载（如全屏切换）时补发。
    _resizeCooldown?.cancel();
    _resizeCooldown = null;
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    _layoutLineCount = _terminal.buffer.lines.length;

    _updateViewportSize();

    _updateScrollOffset();

    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
    _scheduleEditableRect();
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(x + _padding.left, y + _padding.top - _scrollOffset);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx - _padding.left;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  bool _editableRectScheduled = false;

  /// 输入法区域在帧结束后计算：此时布局已更新，同一帧内多次终端更新
  /// 只换算一次坐标；与上次相同的区域由 CustomTextEdit 去重。
  void _scheduleEditableRect() {
    if (_editableRectScheduled || _onEditableRect == null) return;
    _editableRectScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _editableRectScheduled = false;
      if (attached && hasSize) _notifyEditableRect();
    });
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (!_autoResize || _viewportSize == null) return;
    if (_hasResized &&
        (_resizeSuspended || _resizeCooldown != null || !attached)) {
      _resizePending = true;
      return;
    }
    _applyResize();
  }

  void _applyResize() {
    final viewportSize = _viewportSize;
    if (viewportSize == null) return;
    _resizePending = false;
    _hasResized = true;
    _terminal.resize(
      viewportSize.width,
      viewportSize.height,
      _painter.cellSize.width.round(),
      _painter.cellSize.height.round(),
    );
    _resizeCooldown?.cancel();
    _resizeCooldown = Timer(resizeInterval, _onResizeCooldown);
  }

  void _onResizeCooldown() {
    _resizeCooldown = null;
    if (_resizePending && !_resizeSuspended && attached && _autoResize) {
      _applyResize();
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    return _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    return max(_terminalHeight - _viewportHeight, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    if (_linePicturesGeneration != _painter.generation) {
      _disposeLinePictures();
      _linePicturesGeneration = _painter.generation;
    }
    final visible = Map<BufferLine, _LinePicture>.identity();
    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      final picture = _linePicture(lines[i], visible);
      final y = (i * charHeight + _lineOffset).truncateToDouble();
      canvas
        ..save()
        ..translate(offset.dx, offset.dy + y)
        ..drawPicture(picture)
        ..restore();
    }
    // 移出视口或已淘汰的行立即释放。
    _disposeLinePictures();
    _linePictures = visible;

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      }

      if (_shouldShowCursor) {
        _painter.paintCursor(
          canvas,
          offset + cursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    if (_controller.selection != null) {
      _paintSelection(
        canvas,
        _controller.selection!,
        effectFirstLine,
        effectLastLine,
      );
    }
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(style.getTextStyle(textScaler: _painter.textScaler));
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
    paragraph.dispose();
  }

  void _paintSelection(
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;

    final startOffset = Offset(
      start * _painter.cellSize.width,
      segment.line * _painter.cellSize.height + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}

class _LinePicture {
  const _LinePicture(this.version, this.picture);

  final int version;
  final Picture picture;
}
