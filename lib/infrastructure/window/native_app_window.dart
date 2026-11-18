import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show ObserverList;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:window_manager/window_manager.dart';

import '../../domain/window/app_window.dart';

/// 基于 `window_manager` 0.7+ 原生接口实现的桌面窗口控制器。
class NativeAppWindow implements AppWindow {
  final _listeners = ObserverList<AppWindowListener>();

  Window? _cachedWindow;
  ListenerId? _listenerId;
  bool _isFullScreen = false;
  bool _isDestroying = false;

  Window? get _window =>
      _cachedWindow ??= _tryNative<Window?>(WindowManager.instance.getCurrent);

  T? _tryNative<T>(T Function() body) {
    try {
      return body();
    } on ArgumentError {
      return null;
    }
  }

  void _ensureWired() {
    if (_listenerId != null) return;
    final window = _window;
    if (window == null) return;
    _isFullScreen = window.isFullScreen;
    _listenerId = _tryNative(() => window.addListener(_onNativeEvent));
  }

  void _unwire() {
    final id = _listenerId;
    if (id == null) return;
    _cachedWindow?.removeListener(id);
    _listenerId = null;
  }

  void _onNativeEvent(WindowEvent event) {
    switch (event) {
      case WindowCloseRequestedEvent(:final request):
        final destroying = _isDestroying;
        _isDestroying = false;
        if (destroying) break;
        final closeRequest = _NativeCloseRequest(request);
        for (final listener in List<AppWindowListener>.from(_listeners)) {
          if (_listeners.contains(listener)) {
            listener.onWindowCloseRequested(closeRequest);
          }
        }
      case WindowEnteredFullScreenEvent():
        _setFullScreenState(true);
      case WindowExitedFullScreenEvent():
        _setFullScreenState(false);
      case WindowFocusedEvent():
      case WindowBlurredEvent():
      case WindowMinimizedEvent():
      case WindowMaximizedEvent():
      case WindowRestoredEvent():
      case WindowMovedEvent():
      case WindowResizedEvent():
      case WindowCreatedEvent():
      case WindowClosedEvent():
      case WindowPropertyChangedEvent():
      case WindowOcclusionChangedEvent():
      case WindowDockedEvent():
      case WindowUndockedEvent():
        break;
    }
  }

  void _setFullScreenState(bool fullScreen) {
    if (fullScreen == _isFullScreen) return;
    _isFullScreen = fullScreen;
    for (final listener in List<AppWindowListener>.from(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      if (fullScreen) {
        listener.onWindowEnterFullScreen();
      } else {
        listener.onWindowLeaveFullScreen();
      }
    }
  }

  @override
  void addListener(AppWindowListener listener) {
    _listeners.add(listener);
    _ensureWired();
  }

  @override
  void removeListener(AppWindowListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) _unwire();
  }

  @override
  Future<bool> isFullScreen() async => _window?.isFullScreen ?? false;

  @override
  Future<void> setFullScreen(bool fullScreen) async {
    final window = _window;
    if (window == null) return;
    window.isFullScreen = fullScreen;
  }

  @override
  Future<bool> isMaximized() async => _window?.isMaximized ?? false;

  @override
  Future<void> maximize() async {
    _window?.maximize();
  }

  @override
  Future<void> unmaximize() async {
    final window = _window;
    if (window == null) return;
    if (window.isMaximizedVertically) window.setMaximizedVertically(false);
    window.unmaximize();
  }

  @override
  Future<void> minimize() async {
    _window?.minimize();
  }

  @override
  Future<void> startDragging() async {
    _window?.startDragging();
  }

  @override
  void showSystemMenu(double x, double y) {
    final window = _window;
    if (window == null || !Window.isSystemMenuSupported()) return;
    window.showSystemMenu(Offset(x, y).toNative());
  }

  @override
  Future<void> close() async {
    _ensureWired();
    final window = _window;
    final closed =
        window != null &&
        (_tryNative(() {
              if (!Window.isCloseSupported()) return false;
              return window.close();
            }) ??
            false);
    if (!closed) {
      for (final listener in List<AppWindowListener>.from(_listeners)) {
        if (_listeners.contains(listener)) {
          listener.onWindowCloseRequested(_NoopCloseRequest());
        }
      }
    }
  }

  @override
  Future<void> destroy() async {
    _isDestroying = true;
    final window = _window;
    final closed =
        window != null &&
        (_tryNative(() {
              if (!Window.isCloseSupported()) return false;
              return window.close();
            }) ??
            false);
    if (!closed) {
      _isDestroying = false;
      await SystemNavigator.pop();
    }
  }
}

final class _NativeCloseRequest implements AppWindowCloseRequest {
  _NativeCloseRequest(this._request);

  final EventRequest _request;

  @override
  void cancel() {
    _request.cancel();
  }
}

final class _NoopCloseRequest implements AppWindowCloseRequest {
  @override
  void cancel() {}
}
