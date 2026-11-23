import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// Provides the window's visibility independently of the selected tab.
class WorkspaceVisibility extends InheritedWidget {
  const WorkspaceVisibility({
    required this.notifier,
    required super.child,
    super.key,
  });

  final ValueListenable<bool> notifier;

  @override
  bool updateShouldNotify(WorkspaceVisibility oldWidget) =>
      notifier != oldWidget.notifier;
}

/// Stops polling immediately, even if Flutter cannot build a hidden window.
mixin WorkspaceVisibilityObserver<W extends StatefulWidget> on State<W> {
  ValueListenable<bool>? _visibility;
  bool _visibilityReady = false;

  bool get workspaceVisible => _visibilityReady && (_visibility?.value ?? true);

  void onWorkspaceVisibilityChanged();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visibility = context
        .dependOnInheritedWidgetOfExactType<WorkspaceVisibility>()
        ?.notifier;
    if (_visibilityReady && identical(visibility, _visibility)) return;
    _visibility?.removeListener(onWorkspaceVisibilityChanged);
    _visibility = visibility;
    _visibility?.addListener(onWorkspaceVisibilityChanged);
    _visibilityReady = true;
    onWorkspaceVisibilityChanged();
  }

  @override
  void dispose() {
    _visibility?.removeListener(onWorkspaceVisibilityChanged);
    super.dispose();
  }
}
