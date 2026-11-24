import 'package:flutter/foundation.dart' show ObserverList;
import 'package:pagashell/domain/window/app_window.dart';

class FakeAppWindowCloseRequest implements AppWindowCloseRequest {
  bool cancelled = false;

  @override
  void cancel() {
    cancelled = true;
  }
}

/// 桌面窗口内存替身，供组件测试记录窗口调用并触发关闭与全屏事件。
class FakeAppWindow implements AppWindow {
  final _listeners = ObserverList<AppWindowListener>();

  final calls = <String>[];
  final fullscreenRequests = <bool>[];
  bool maximized = false;
  bool fullscreen = false;
  bool visible = true;
  bool emitFullscreenEvents = true;
  bool failEnterFullScreen = false;
  bool failExitFullScreen = false;

  @override
  void addListener(AppWindowListener listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(AppWindowListener listener) {
    _listeners.remove(listener);
  }

  bool requestClose() {
    final request = FakeAppWindowCloseRequest();
    for (final listener in List<AppWindowListener>.from(_listeners)) {
      if (_listeners.contains(listener)) {
        listener.onWindowCloseRequested(request);
      }
    }
    return !request.cancelled;
  }

  void emitFullScreen(bool entered) {
    fullscreen = entered;
    for (final listener in List<AppWindowListener>.from(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      if (entered) {
        listener.onWindowEnterFullScreen();
      } else {
        listener.onWindowLeaveFullScreen();
      }
    }
  }

  void emitMinimized(bool minimized) {
    for (final listener in _listeners.toList()) {
      if (!_listeners.contains(listener)) continue;
      if (minimized) {
        listener.onWindowMinimized();
      } else {
        listener.onWindowRestored();
      }
    }
  }

  @override
  Future<bool> isFullScreen() async {
    calls.add('isFullScreen');
    return fullscreen;
  }

  @override
  Future<void> setFullScreen(bool fullScreen) async {
    calls.add('setFullScreen');
    fullscreenRequests.add(fullScreen);
    if (fullScreen ? failEnterFullScreen : failExitFullScreen) {
      throw StateError('test-window-error');
    }
    fullscreen = fullScreen;
    if (emitFullscreenEvents) emitFullScreen(fullScreen);
  }

  @override
  Future<bool> isMaximized() async {
    calls.add('isMaximized');
    return maximized;
  }

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
    maximized = false;
  }

  @override
  Future<void> minimize() async {
    calls.add('minimize');
  }

  @override
  Future<bool> isVisible() async {
    calls.add('isVisible');
    return visible;
  }

  @override
  Future<void> show() async {
    calls.add('show');
    visible = true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    visible = false;
  }

  @override
  Future<void> startDragging() async {
    calls.add('startDragging');
  }

  @override
  void showSystemMenu(double x, double y) {
    calls.add('showSystemMenu');
  }

  @override
  Future<void> close() async {
    calls.add('close');
  }

  @override
  Future<void> destroy() async {
    calls.add('destroy');
  }
}
