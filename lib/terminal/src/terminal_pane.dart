import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../paga_terminal.dart';

/// 将拖选起点固定在缓冲区文本上，滚动视口时继续延伸选区。
class TerminalPane extends StatefulWidget {
  const TerminalPane(
    this.terminal, {
    required this.focusNode,
    required this.active,
    this.backgroundColor = const Color(0xff000000),
    this.textStyle = const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
    this.selectionEdgeExtent = 24,
    this.selectionScrollInterval = const Duration(milliseconds: 40),
    this.onPaste,
    this.onSecondaryTapUp,
    this.onOpenLink,
    this.onKeyEvent,
    this.onUserInput,
    this.onScrollPositionChanged,
    this.showScrollbar = false,
    super.key,
  });

  final Terminal terminal;
  final FocusNode focusNode;
  final bool active;
  final Color backgroundColor;
  final TerminalStyle textStyle;
  final double selectionEdgeExtent;
  final Duration selectionScrollInterval;
  final Future<bool> Function(String text)? onPaste;
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;
  final ValueChanged<Uri>? onOpenLink;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<void Function(Terminal)>? onUserInput;
  final ValueChanged<bool>? onScrollPositionChanged;
  final bool showScrollbar;

  @override
  State<TerminalPane> createState() => TerminalPaneState();
}

class TerminalPaneState extends State<TerminalPane> {
  final _viewKey = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();
  late final _DragSelectionController _selection;
  int? _pointer;
  Offset? _pointerPosition;
  Timer? _autoScroll;
  bool _updateScheduled = false;
  bool _reportScheduled = false;
  final _searchMarks = <TerminalHighlight>[];
  Offset? _hoverAt;
  ({Uri url, TerminalTextMatch range})? _hoveredLink;
  TerminalHighlight? _linkMark;

  bool get atBottom =>
      !_scroll.hasClients ||
      !_scroll.position.hasContentDimensions ||
      _scroll.position.maxScrollExtent - _scroll.position.pixels <= 1;

  void scrollToBottom() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void revealMatch(TerminalTextMatch match, {double topInset = 0}) {
    if (!match.attached || !_scroll.hasClients) return;
    final render = _viewKey.currentState?.renderTerminal;
    if (render == null) return;
    final position = _scroll.position;
    final inset = math.min(topInset, position.viewportDimension / 2);
    final top = match.first.index * render.lineHeight;
    final bottom = (match.last.index + 1) * render.lineHeight;
    if (top >= position.pixels + inset &&
        bottom <= position.pixels + position.viewportDimension) {
      return;
    }
    _scroll.jumpTo(
      (top - math.max(inset, render.lineHeight * 2)).clamp(
        0.0,
        position.maxScrollExtent,
      ),
    );
  }

  void paintSearchMatches(
    List<TerminalTextMatch> matches,
    int selected, {
    required Color matchColor,
    required Color selectedColor,
  }) {
    for (final mark in _searchMarks) {
      mark.dispose();
    }
    _searchMarks.clear();
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      if (!match.attached) continue;
      _searchMarks.add(
        _selection.highlight(
          p1: match.first.createAnchor(match.start),
          p2: match.last.createAnchor(match.end),
          color: i == selected ? selectedColor : matchColor,
        ),
      );
    }
  }

  bool get hasSelection => _selection.selection != null;

  String? get selectedText {
    final selection = _selection.selection;
    if (selection == null) return null;
    return widget.terminal.buffer.getText(selection);
  }

  void clearSelection() => _selection.clearSelection();

  void selectAll() {
    final terminal = widget.terminal;
    _selection.setSelection(
      terminal.buffer.createAnchor(
        0,
        terminal.buffer.height - terminal.viewHeight,
      ),
      terminal.buffer.createAnchor(
        terminal.viewWidth,
        terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
  }

  @override
  void initState() {
    super.initState();
    _selection = _DragSelectionController(
      extentAtPointer: _extentAtPointer,
      onDragged: _updateAutoScroll,
    );
    _scroll.addListener(_onScroll);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active || !identical(widget.terminal, oldWidget.terminal)) {
      _finishDrag();
      _hoverAt = null;
      _hoveredLink = null;
      _linkMark?.dispose();
      _linkMark = null;
    }
    if (!identical(widget.terminal, oldWidget.terminal)) {
      _selection.clearSelection();
      paintSearchMatches(
        const [],
        -1,
        matchColor: const Color(0x00000000),
        selectedColor: const Color(0x00000000),
      );
    }
  }

  @override
  void dispose() {
    _finishDrag();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _selection.clearSelection();
    _selection.dispose();
    super.dispose();
  }

  bool get _canSelect =>
      widget.active &&
      !widget.terminal.isUsingAltBuffer &&
      _viewKey.currentState != null;

  void _onPointerDown(PointerDownEvent event) {
    if (!_canSelect ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    final render = _viewKey.currentState!.renderTerminal;
    final local = render.globalToLocal(event.position);
    if (!(Offset.zero & render.size).contains(local)) return;
    if (_linkAt(event.position) case final link?) {
      _finishDrag();
      _pointer = event.pointer;
      _pointerPosition = event.position;
      _linkPress = link.url;
      return;
    }
    _finishDrag();
    _pointer = event.pointer;
    _pointerPosition = event.position;
    _selection.beginPointer(
      widget.terminal.buffer.createAnchorFromOffset(
        render.getCellOffset(local),
      ),
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (!_canSelect || event.buttons & kPrimaryMouseButton == 0) {
      _finishDrag();
      return;
    }
    if (_linkPress != null) {
      if ((event.position - _pointerPosition!).distance > 4) _finishDrag();
      return;
    }
    _pointerPosition = event.position;
    _updateAutoScroll();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final link = _linkPress;
    if (link != null &&
        _linkAt(event.position)?.url == link &&
        (event.position - _pointerPosition!).distance <= 4) {
      widget.onOpenLink?.call(link);
    }
    if (_canSelect) _selection.updateDragSelection();
    _finishDrag();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _finishDrag();
  }

  void _finishDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _pointer = null;
    _pointerPosition = null;
    _linkPress = null;
    _selection.endPointer();
  }

  CellAnchor _extentAtPointer(CellOffset start) {
    final render = _viewKey.currentState!.renderTerminal;
    final local = render.globalToLocal(_pointerPosition!);
    // 鼠标可以拖出视口；只选到当前可见边缘，再由自动滚动延伸。
    final clamped = Offset(
      local.dx.clamp(0, math.max(0, render.size.width - 1)).toDouble(),
      local.dy.clamp(0, math.max(0, render.size.height - 1)).toDouble(),
    );
    var end = render.getCellOffset(clamped);
    if (end.x >= start.x) end = CellOffset(end.x + 1, end.y);
    return widget.terminal.buffer.createAnchorFromOffset(end);
  }

  void _onScroll() {
    _scheduleScrollReport();
    if (!_selection.dragging || _updateScheduled) return;
    _updateScheduled = true;
    // 滚动和终端输出都可能触发布局，布局完成后再按新视口延伸。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted || !_selection.dragging) return;
      if (!_canSelect) {
        _finishDrag();
        return;
      }
      _selection.updateDragSelection();
    });
  }

  void _scheduleScrollReport() {
    if (_reportScheduled ||
        (widget.onScrollPositionChanged == null && _hoverAt == null)) {
      return;
    }
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!mounted) return;
      widget.onScrollPositionChanged?.call(atBottom);
      _updateHoveredLink();
    });
  }

  Uri? _linkPress;

  ({Uri url, TerminalTextMatch range})? _linkAt(Offset point) {
    if (widget.onOpenLink == null ||
        !_canSelect ||
        widget.terminal.mouseMode != MouseMode.none ||
        widget.terminal.buffer.height == 0) {
      return null;
    }
    final keyboard = HardwareKeyboard.instance;
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    if (!(isMac ? keyboard.isMetaPressed : keyboard.isControlPressed)) {
      return null;
    }
    final render = _viewKey.currentState!.renderTerminal;
    final local = render.globalToLocal(point);
    if (!(Offset.zero & render.size).contains(local)) return null;
    return terminalLinkAt(widget.terminal.buffer, render.getCellOffset(local));
  }

  bool _onKey(KeyEvent event) {
    if (_hoverAt != null) _updateHoveredLink();
    return false;
  }

  void _updateHoveredLink() {
    final hovered = _hoverAt == null ? null : _linkAt(_hoverAt!);
    final previous = _hoveredLink;
    if (previous == null && hovered == null) return;
    if (previous != null &&
        hovered != null &&
        previous.url == hovered.url &&
        identical(previous.range.first, hovered.range.first) &&
        identical(previous.range.last, hovered.range.last) &&
        previous.range.start == hovered.range.start &&
        previous.range.end == hovered.range.end) {
      return;
    }
    _linkMark?.dispose();
    _linkMark = hovered == null
        ? null
        : _selection.highlight(
            p1: hovered.range.first.createAnchor(hovered.range.start),
            p2: hovered.range.last.createAnchor(hovered.range.end),
            color: const Color(0xff93c5fd),
            underline: true,
          );
    setState(() => _hoveredLink = hovered);
  }

  double get _scrollStep {
    if (!_canSelect || !_selection.dragging || _pointerPosition == null) {
      return 0;
    }
    final render = _viewKey.currentState!.renderTerminal;
    final y = render.globalToLocal(_pointerPosition!).dy;
    final edge = math.min(widget.selectionEdgeExtent, render.size.height / 2);
    if (edge <= 0) return 0;
    final distance = y < edge
        ? y - edge
        : y > render.size.height - edge
        ? y - (render.size.height - edge)
        : 0.0;
    if (distance == 0) return 0;
    return distance.sign *
        (distance.abs() / edge).clamp(.5, 3) *
        render.lineHeight;
  }

  void _updateAutoScroll() {
    if (_scrollStep == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
    } else {
      _autoScroll ??= Timer.periodic(
        widget.selectionScrollInterval,
        (_) => _scrollAtEdge(),
      );
    }
  }

  void _scrollAtEdge() {
    final step = _scrollStep;
    if (step == 0 || !_scroll.hasClients) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final position = _scroll.position;
    final next = (position.pixels + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _scroll.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    Widget view = TerminalView(
      widget.terminal,
      key: _viewKey,
      controller: _selection,
      scrollController: _scroll,
      focusNode: widget.focusNode,
      autofocus: widget.active,
      backgroundOpacity: 0,
      padding: const EdgeInsets.all(4),
      textStyle: widget.textStyle,
      onPaste: widget.onPaste,
      onKeyEvent: widget.onKeyEvent,
      onUserInput: widget.onUserInput,
      onSecondaryTapUp: widget.onSecondaryTapUp,
    );
    if (widget.showScrollbar) {
      view = RawScrollbar(
        controller: _scroll,
        thumbVisibility: true,
        thumbColor: const Color(0x778f8f99),
        thickness: 4,
        radius: const Radius.circular(3),
        child: view,
      );
    }
    if (widget.onOpenLink != null) {
      view = MouseRegion(
        cursor: _hoveredLink == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onHover: (event) {
          _hoverAt = event.position;
          _updateHoveredLink();
        },
        onExit: (_) {
          _hoverAt = null;
          _updateHoveredLink();
        },
        child: view,
      );
    }
    return ColoredBox(
      color: widget.backgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(4),
        // xterm 在非整行回滚时会绘制越过视口的行，需在宿主裁剪。
        child: ClipRect(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _scheduleScrollReport();
                return false;
              },
              child: view,
            ),
          ),
        ),
      ),
    );
  }
}

class _DragSelectionController extends TerminalController {
  _DragSelectionController({
    required this.extentAtPointer,
    required this.onDragged,
  });

  final CellAnchor Function(CellOffset start) extentAtPointer;
  final VoidCallback onDragged;
  CellAnchor? _start;
  bool _dragging = false;

  bool get dragging => _dragging && _start?.attached == true;

  void beginPointer(CellAnchor start) {
    endPointer();
    _start = start;
  }

  void endPointer() {
    _start?.dispose();
    _start = null;
    _dragging = false;
  }

  @override
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    if (_start?.attached != true || mode != null) {
      super.setSelection(base, extent, mode: mode);
      return;
    }
    // xterm 拖选按旧屏幕坐标重算 base；保留独立文本锚点抵消滚动偏移。
    base.dispose();
    extent.dispose();
    _dragging = true;
    updateDragSelection();
    onDragged();
  }

  void updateDragSelection() {
    if (!dragging) return;
    final start = _start!;
    super.setSelection(
      start.line!.createAnchor(start.x),
      extentAtPointer(start.offset),
    );
  }
}
