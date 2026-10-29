import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';

/// 将拖选起点固定在缓冲区文本上，滚动视口时继续延伸选区。
class AppTerminalView extends StatefulWidget {
  const AppTerminalView(
    this.terminal, {
    required this.focusNode,
    required this.active,
    super.key,
  });

  final Terminal terminal;
  final FocusNode focusNode;
  final bool active;

  @override
  State<AppTerminalView> createState() => _AppTerminalViewState();
}

class _AppTerminalViewState extends State<AppTerminalView> {
  final _viewKey = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();
  late final _DragSelectionController _selection;
  int? _pointer;
  Offset? _pointerPosition;
  Timer? _autoScroll;
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    _selection = _DragSelectionController(
      extentAtPointer: _extentAtPointer,
      onDragged: _updateAutoScroll,
    );
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(AppTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active || !identical(widget.terminal, oldWidget.terminal)) {
      _finishDrag();
    }
    if (!identical(widget.terminal, oldWidget.terminal)) {
      _selection.clearSelection();
    }
  }

  @override
  void dispose() {
    _finishDrag();
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
    _pointerPosition = event.position;
    _updateAutoScroll();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
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

  double get _scrollStep {
    if (!_canSelect || !_selection.dragging || _pointerPosition == null) {
      return 0;
    }
    final render = _viewKey.currentState!.renderTerminal;
    final y = render.globalToLocal(_pointerPosition!).dy;
    final edge = math.min(
      AppTheme.terminalSelectionEdgeExtent,
      render.size.height / 2,
    );
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
        AppTheme.terminalSelectionScrollInterval,
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
  Widget build(BuildContext context) => ColoredBox(
    color: AppTheme.terminalBackground,
    child: Padding(
      padding: const EdgeInsets.all(4),
      // xterm 在非整行回滚时会绘制越过视口的行，需在宿主裁剪。
      child: ClipRect(
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: TerminalView(
            widget.terminal,
            key: _viewKey,
            controller: _selection,
            scrollController: _scroll,
            focusNode: widget.focusNode,
            autofocus: widget.active,
            backgroundOpacity: 0,
            padding: const EdgeInsets.all(4),
            // Nerd Font 覆盖 shell 主题图标，后备字体覆盖 CJK 和 emoji。
            textStyle: const TerminalStyle(
              fontSize: 13,
              fontFamily: 'FiraCode Nerd Font Mono',
              fontFamilyFallback: [
                'MesloLGS NF',
                'Menlo',
                'PingFang SC',
                'Microsoft YaHei',
                'Noto Sans Mono CJK SC',
                'Noto Color Emoji',
                'monospace',
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
