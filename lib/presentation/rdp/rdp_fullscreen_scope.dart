import 'package:flutter/widgets.dart';

/// The shell owns the OS window; the desktop keeps its connection and surface.
class RdpFullscreenScope extends InheritedWidget {
  const RdpFullscreenScope({
    required this.sessionId,
    required this.busy,
    required this.enter,
    required this.exit,
    required super.child,
    super.key,
  });
  final String? sessionId;
  final bool busy;
  final Future<void> Function(String sessionId) enter;
  final Future<void> Function() exit;
  bool get fullscreen => sessionId != null;

  static RdpFullscreenScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RdpFullscreenScope>();

  @override
  bool updateShouldNotify(RdpFullscreenScope oldWidget) =>
      sessionId != oldWidget.sessionId || busy != oldWidget.busy;
}
