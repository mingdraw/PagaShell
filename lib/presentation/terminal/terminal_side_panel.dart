import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

enum TerminalSidePanelKind { status, processes, docker }

/// 终端共用一个可调宽的侧面板；收起和切换内容时保留子组件状态。
class TerminalSidePanel extends StatefulWidget {
  const TerminalSidePanel({
    required this.availableWidth,
    required this.availableHeight,
    required this.terminal,
    required this.toolbarBuilder,
    required this.panelBuilder,
    super.key,
  });

  final double availableWidth;
  final double availableHeight;
  final Widget terminal;
  final Widget Function(
    BuildContext context,
    TerminalSidePanelKind? visible,
    bool canExpand,
    ValueChanged<TerminalSidePanelKind> toggle,
  )
  toolbarBuilder;
  final Widget Function(
    BuildContext context,
    TerminalSidePanelKind selected,
    bool visible,
  )
  panelBuilder;

  @override
  State<TerminalSidePanel> createState() => _TerminalSidePanelState();
}

class _TerminalSidePanelState extends State<TerminalSidePanel>
    with SingleTickerProviderStateMixin {
  final _terminalPane = shadcn.FlexibleResizablePaneController(1);
  final _sidePane = shadcn.AbsoluteResizablePaneController(0);
  late final AnimationController _expansion;
  TerminalSidePanelKind _selected = TerminalSidePanelKind.status;
  bool _expanded = false;
  double _target = 0;
  double _panelWidth = AppTheme.serverStatusDefaultWidth;
  double? _preferredWidth;

  bool get _canExpand =>
      widget.availableWidth >= 520 && widget.availableHeight >= 160;
  bool get _visible => _expanded && _canExpand;
  double get _fraction => Curves.easeInOutCubic.transform(_expansion.value);
  double get _maxWidth => math.min(
    AppTheme.serverStatusMaxWidth,
    math.max(0, widget.availableWidth - AppTheme.terminalPaneMinWidth - 1),
  );

  void _syncWidth() {
    final maximum = _maxWidth;
    final minimum = math.min(AppTheme.serverStatusMinWidth, maximum);
    final preferred =
        _preferredWidth ??
        math.min(
          AppTheme.serverStatusDefaultWidth,
          widget.availableWidth * .42,
        );
    _panelWidth = preferred.clamp(minimum, maximum);
    _sidePane.size = _panelWidth * _fraction;
  }

  void _animateWidth() {
    _sidePane.size = _panelWidth * _fraction;
    setState(() {});
  }

  void _syncAnimation() {
    final target = _visible ? 1.0 : 0.0;
    if (!_canExpand || MediaQuery.disableAnimationsOf(context)) {
      _target = target;
      _expansion.value = target;
    } else if (_target != target) {
      _target = target;
      _expansion.animateTo(target);
    }
  }

  void _toggle(TerminalSidePanelKind kind) {
    setState(() {
      _expanded = _selected != kind || !_expanded;
      _selected = kind;
    });
    _syncAnimation();
  }

  @override
  void initState() {
    super.initState();
    _expansion = AnimationController(
      vsync: this,
      duration: AppTheme.sidebarTransitionDuration,
    )..addListener(_animateWidth);
    _syncWidth();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(TerminalSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.availableWidth != widget.availableWidth) _syncWidth();
    _syncAnimation();
  }

  @override
  void dispose() {
    _expansion.dispose();
    _terminalPane.dispose();
    _sidePane.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      widget.toolbarBuilder(
        context,
        _visible ? _selected : null,
        _canExpand,
        _toggle,
      ),
      Expanded(
        child: shadcn.ResizablePanel.horizontal(
          key: const ValueKey('terminal-side-panel-resizable'),
          dividerBuilder: (_) => SizedBox(
            width: _fraction,
            child: const ColoredBox(color: AppTheme.terminalBorder),
          ),
          draggerThickness: _visible && _expansion.isCompleted ? 8 : 0,
          draggerBuilder: (_) => _visible && _expansion.isCompleted
              ? const shadcn.HorizontalResizableDragger(
                  key: ValueKey('terminal-side-panel-dragger'),
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
                AppTheme.terminalPaneMinWidth,
                widget.availableWidth,
              ),
              child: widget.terminal,
            ),
            shadcn.ResizablePane.controlled(
              controller: _sidePane,
              minSize: _expansion.isCompleted
                  ? AppTheme.serverStatusMinWidth
                  : 0,
              maxSize: _maxWidth,
              onSizeChangeEnd: (width) {
                _preferredWidth = width;
                _panelWidth = width;
              },
              child: Offstage(
                offstage: _expansion.value == 0,
                child: IgnorePointer(
                  key: const ValueKey('terminal-side-panel-viewport'),
                  ignoring: !_visible || _expansion.isAnimating,
                  child: ExcludeFocus(
                    excluding: !_visible,
                    child: ExcludeSemantics(
                      excluding: !_visible,
                      child: ClipRect(
                        child: LayoutBuilder(
                          builder: (_, constraints) {
                            // 过渡期间固定内容宽度，裁剪代替把卡片挤压至零。
                            final width = _expansion.isAnimating || !_visible
                                ? math.max(
                                    AppTheme.serverStatusMinWidth,
                                    _panelWidth,
                                  )
                                : constraints.maxWidth;
                            return OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: width,
                              maxWidth: width,
                              child: widget.panelBuilder(
                                context,
                                _selected,
                                _visible,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
