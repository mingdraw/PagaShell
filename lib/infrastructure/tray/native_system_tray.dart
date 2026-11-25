import 'package:flutter/services.dart';

import '../../domain/tray/system_tray.dart';

/// 基于平台原生通道（macOS NSStatusItem / Windows NotifyIcon / Linux SNI）的托盘实现。
class NativeSystemTray implements SystemTray {
  NativeSystemTray({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pagashell/tray');

  final MethodChannel _channel;
  void Function()? _onIconActivated;
  void Function(String itemId)? _onMenuItemSelected;
  bool _handlerWired = false;
  bool _initialized = false;
  bool _disposed = false;
  bool? _backgroundMode;
  SystemTrayState? _lastState;

  void _ensureHandler() {
    if (_handlerWired) return;
    _handlerWired = true;
    _channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      switch (call.method) {
        case 'onIconActivated':
          _onIconActivated?.call();
        case 'onMenuItemSelected':
          final args = call.arguments;
          final id = args is Map ? args['id'] : null;
          if (id is String && id.isNotEmpty) {
            _onMenuItemSelected?.call(id);
          }
      }
    });
  }

  @override
  void setEventHandler({
    void Function()? onIconActivated,
    void Function(String itemId)? onMenuItemSelected,
  }) {
    _onIconActivated = onIconActivated;
    _onMenuItemSelected = onMenuItemSelected;
    if (!_disposed) _ensureHandler();
  }

  @override
  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod<void>('initialize');
      _initialized = true;
    } on MissingPluginException {
      // 无托盘宿主实现（如测试或受限环境）时静默降级。
    } on PlatformException {
      // 系统托盘不可用时不阻塞应用启动。
    }
  }

  @override
  Future<void> update(SystemTrayState state) async {
    if (_disposed) return;
    if (_lastState == state) return;
    if (!_initialized) await initialize();
    if (_disposed || !_initialized) return;
    _lastState = state;
    try {
      await _channel.invokeMethod<void>('update', {
        'tooltip': state.tooltip,
        'hasActiveServices': state.hasActiveServices,
        'items': [for (final item in state.items) item.toMap()],
      });
    } on MissingPluginException {
      // 忽略缺失通道。
    } on PlatformException {
      _lastState = null;
    }
  }

  @override
  Future<void> setBackgroundMode(bool active) async {
    if (_disposed || _backgroundMode == active) return;
    _backgroundMode = active;
    try {
      await _channel.invokeMethod<void>('setBackgroundMode', {
        'active': active,
      });
    } on MissingPluginException {
      // 忽略缺失通道。
    } on PlatformException {
      // 忽略平台不支持。
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onIconActivated = null;
    _onMenuItemSelected = null;
    if (_handlerWired) {
      _channel.setMethodCallHandler(null);
      _handlerWired = false;
    }
    if (!_initialized) return;
    _initialized = false;
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // 忽略缺失通道。
    } on PlatformException {
      // 退出前清理失败不阻断关闭。
    }
  }
}
