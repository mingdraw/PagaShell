import 'package:flutter/widgets.dart';

/// 协调窄窗口中两侧栏的可用空间。
class AgentSidebarScope extends InheritedWidget {
  const AgentSidebarScope({
    required this.sidebarHiddenForSpace,
    required this.showSidebar,
    this.onQuoteTerminalSelection,
    required super.child,
    super.key,
  });

  final bool sidebarHiddenForSpace;
  final Future<void> Function() showSidebar;
  final ValueChanged<String>? onQuoteTerminalSelection;

  static AgentSidebarScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentSidebarScope>();

  @override
  bool updateShouldNotify(AgentSidebarScope oldWidget) =>
      oldWidget.sidebarHiddenForSpace != sidebarHiddenForSpace ||
      oldWidget.onQuoteTerminalSelection != onQuoteTerminalSelection;
}
