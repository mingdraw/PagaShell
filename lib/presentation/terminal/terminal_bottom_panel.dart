import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// 终端底部可调高的抽屉容器；收起与调整高度时保留上方终端状态与滚动位置。
class TerminalBottomPanel extends StatefulWidget {
  const TerminalBottomPanel({
    required this.availableHeight,
    required this.expanded,
    required this.terminal,
    required this.panelBuilder,
    super.key,
  });

  final double availableHeight;
  final bool expanded;
  final Widget terminal;
  final Widget Function(BuildContext context, bool visible) panelBuilder;

  static bool canExpandForHeight(double availableHeight) =>
      availableHeight >= AppTheme.terminalQuickCommandsExpandMinHeight;

  @override
  State<TerminalBottomPanel> createState() => _TerminalBottomPanelState();
}

class _TerminalBottomPanelState extends State<TerminalBottomPanel>
    with SingleTickerProviderStateMixin {
  final _terminalPane = shadcn.FlexibleResizablePaneController(1);
  final _bottomPane = shadcn.AbsoluteResizablePaneController(0);
  late final AnimationController _expansion;
  bool _panelMounted = false;
  bool _syncingLifecycle = false;
  double _target = 0;
  double _panelHeight = AppTheme.terminalQuickCommandsDefaultHeight;
  double? _preferredHeight;

  bool get _canExpand =>
      TerminalBottomPanel.canExpandForHeight(widget.availableHeight);
  bool get _visible => widget.expanded && _canExpand;
  double get _fraction => Curves.easeInOutCubic.transform(_expansion.value);
  double get _maxHeight => math.min(
    AppTheme.terminalQuickCommandsMaxHeight,
    math.max(0, widget.availableHeight - AppTheme.terminalPaneMinHeight - 1),
  );

  void _syncHeight() {
    final maximum = _maxHeight;
    final minimum = math.min(AppTheme.terminalQuickCommandsMinHeight, maximum);
    final preferred =
        _preferredHeight ??
        math.min(
          AppTheme.terminalQuickCommandsDefaultHeight,
          widget.availableHeight * .36,
        );
    _panelHeight = preferred.clamp(minimum, maximum);
    _bottomPane.size = _panelHeight * _fraction;
  }

  void _animateHeight() {
    _bottomPane.size = _panelHeight * _fraction;
    if (!_syncingLifecycle) setState(() {});
  }

  void _syncAnimation({bool fromLifecycle = false}) {
    if (_visible) _panelMounted = true;
    final target = _visible ? 1.0 : 0.0;
    _syncingLifecycle = fromLifecycle;
    try {
      if (!_canExpand || MediaQuery.disableAnimationsOf(context)) {
        _target = target;
        _expansion.value = target;
        _bottomPane.size = _panelHeight * _fraction;
      } else if (_target != target) {
        _target = target;
        _expansion.animateTo(target);
      }
    } finally {
      _syncingLifecycle = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _expansion = AnimationController(
      vsync: this,
      duration: AppTheme.sidebarTransitionDuration,
    )..addListener(_animateHeight);
    _syncHeight();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation(fromLifecycle: true);
  }

  @override
  void didUpdateWidget(TerminalBottomPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.availableHeight != widget.availableHeight) _syncHeight();
    _syncAnimation(fromLifecycle: true);
  }

  @override
  void dispose() {
    _expansion.dispose();
    _terminalPane.dispose();
    _bottomPane.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => shadcn.ResizablePanel.vertical(
    key: const ValueKey('terminal-bottom-panel-resizable'),
    dividerBuilder: (_) => SizedBox(
      height: _fraction,
      child: const ColoredBox(color: AppTheme.terminalBorder),
    ),
    draggerThickness: _visible && _expansion.isCompleted ? 8 : 0,
    draggerBuilder: (_) => _visible && _expansion.isCompleted
        ? const shadcn.VerticalResizableDragger(
            key: ValueKey('terminal-bottom-panel-dragger'),
            theme: shadcn.ResizableDraggerTheme(
              color: AppTheme.terminalSelectedBorder,
              iconColor: AppTheme.terminalForeground,
            ),
          )
        : const SizedBox.shrink(),
    children: [
      shadcn.ResizablePane.controlled(
        controller: _terminalPane,
        minSize: math.min(
          AppTheme.terminalPaneMinHeight,
          widget.availableHeight,
        ),
        child: widget.terminal,
      ),
      shadcn.ResizablePane.controlled(
        controller: _bottomPane,
        minSize: _expansion.isCompleted
            ? math.min(AppTheme.terminalQuickCommandsMinHeight, _maxHeight)
            : 0,
        maxSize: _maxHeight,
        onSizeChangeEnd: (height) {
          _preferredHeight = height;
          _panelHeight = height;
        },
        child: Offstage(
          offstage: _expansion.value == 0,
          child: TickerMode(
            enabled: _expansion.value > 0,
            child: IgnorePointer(
              key: const ValueKey('terminal-bottom-panel-viewport'),
              ignoring: !_visible || _expansion.isAnimating,
              child: ExcludeFocus(
                excluding: !_visible,
                child: ExcludeSemantics(
                  excluding: !_visible,
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (_, constraints) {
                        // 过渡期间固定内容高度，裁剪代替把列表挤压至零。
                        final height = _expansion.isAnimating || !_visible
                            ? math.max(
                                AppTheme.terminalQuickCommandsMinHeight,
                                _panelHeight,
                              )
                            : constraints.maxHeight;
                        return OverflowBox(
                          alignment: Alignment.topCenter,
                          minHeight: height,
                          maxHeight: height,
                          child: _panelMounted
                              ? widget.panelBuilder(context, _visible)
                              : const SizedBox.shrink(),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
