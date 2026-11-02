import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// 展开时逐步显示子项，收起动画结束后移除子项及其拖放目标。
class AppTreeExpansion extends StatefulWidget {
  const AppTreeExpansion({
    required this.expanded,
    required this.children,
    super.key,
  });

  final bool expanded;
  final List<Widget> children;

  @override
  State<AppTreeExpansion> createState() => _AppTreeExpansionState();
}

class _AppTreeExpansionState extends State<AppTreeExpansion> {
  late List<Widget> _children = widget.expanded ? widget.children : const [];

  @override
  void didUpdateWidget(covariant AppTreeExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 收起期间保留上一帧内容，让内容随高度一起收起。
    if (widget.expanded) _children = widget.children;
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _children = widget.expanded ? widget.children : const [];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _children,
      );
    }
    final factor = widget.expanded ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: factor, end: factor),
      duration: AppTheme.sidebarTransitionDuration,
      curve: Curves.easeInOutCubic,
      onEnd: () {
        if (!widget.expanded && _children.isNotEmpty) {
          setState(() => _children = const []);
        }
      },
      builder: (context, value, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: value,
          child: child,
        ),
      ),
      child: IgnorePointer(
        ignoring: !widget.expanded,
        child: ExcludeFocus(
          excluding: !widget.expanded,
          child: ExcludeSemantics(
            excluding: !widget.expanded,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _children,
            ),
          ),
        ),
      ),
    );
  }
}

class AppTreeChevron extends StatelessWidget {
  const AppTreeChevron({required this.expanded, super.key});

  final bool expanded;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? 0.25 : 0,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppTheme.sidebarTransitionDuration,
    curve: Curves.easeInOutCubic,
    child: Icon(
      shadcn.LucideIcons.chevronRight,
      size: 16,
      color: shadcn.Theme.of(context).colorScheme.mutedForeground,
    ),
  );
}
