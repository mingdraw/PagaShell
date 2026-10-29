import 'package:flutter/widgets.dart';

/// 协调左右侧栏的可用空间；窗口按钮由外层固定在窗口右上角。
class AgentSidebarScope extends InheritedWidget {
  const AgentSidebarScope({
    required this.visible,
    required this.sidebarHiddenForSpace,
    required this.showSidebar,
    required super.child,
    super.key,
  });

  final bool visible;
  final bool sidebarHiddenForSpace;
  final Future<void> Function() showSidebar;

  static AgentSidebarScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentSidebarScope>();

  @override
  bool updateShouldNotify(AgentSidebarScope oldWidget) =>
      oldWidget.visible != visible ||
      oldWidget.sidebarHiddenForSpace != sidebarHiddenForSpace;
}
