/// 可同步取消的原生窗口关闭请求。
abstract interface class AppWindowCloseRequest {
  void cancel();
}

/// 桌面窗口状态与生命周期事件监听。
mixin AppWindowListener {
  void onWindowCloseRequested(AppWindowCloseRequest request) {}
  void onWindowEnterFullScreen() {}
  void onWindowLeaveFullScreen() {}
  void onWindowBlur() {}
}

/// 桌面主窗口操作抽象，便于生产环境对接原生实现并在测试中注入替身。
abstract interface class AppWindow {
  void addListener(AppWindowListener listener);
  void removeListener(AppWindowListener listener);

  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool fullScreen);

  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> minimize();

  Future<void> startDragging();
  void showSystemMenu(double x, double y);

  Future<void> close();
  Future<void> destroy();
}
