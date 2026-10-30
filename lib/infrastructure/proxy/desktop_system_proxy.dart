import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/system_proxy.dart';
import 'linux_system_proxy.dart';
import 'system_proxy_backend.dart';

/// One owner for the entire app, including concurrent starts on different gateways.
class DesktopSystemProxy implements SystemProxy {
  DesktopSystemProxy({SystemProxyBackend? backend})
    : _backend =
          backend ??
          (Platform.isLinux ? LinuxSystemProxy() : const NativeSystemProxy());

  final SystemProxyBackend _backend;
  _DesktopProxyLease? _owner;
  int _sequence = 0;

  @override
  SystemProxyLease createLease(ProxyConfig config) => _DesktopProxyLease(
    this,
    '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
    config,
  );
}

class _DesktopProxyLease implements SystemProxyLease {
  _DesktopProxyLease(this.service, this.id, this.config);
  final DesktopSystemProxy service;
  final String id;
  final ProxyConfig config;
  Future<void>? _enabling;
  Future<void>? _restoring;
  bool _released = false;

  @override
  Future<void> enable() => _enabling ??= _enable();

  Future<void> _enable() async {
    if (_released || service._owner != null) {
      throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
    }
    service._owner = this;
    // Keep ownership even on failure: restore must handle partial platform writes.
    await service._backend.enable(id, config);
  }

  @override
  Future<void> restore() async {
    if (_released) return;
    if (_restoring case final pending?) return pending;
    final restoring = _restore();
    _restoring = restoring;
    try {
      await restoring;
    } finally {
      _restoring = null;
    }
  }

  Future<void> _restore() async {
    try {
      await _enabling;
    } on Object {
      // A failed enable may still have written some settings.
    }
    if (identical(service._owner, this)) {
      try {
        await service._backend.restore(id);
      } on SystemProxyException {
        rethrow;
      } on Object {
        throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
      }
      service._owner = null;
    }
    _released = true;
  }
}

class NativeSystemProxy implements SystemProxyBackend {
  const NativeSystemProxy({
    this._channel = const MethodChannel('pagashell/system_proxy'),
  });
  final MethodChannel _channel;

  @override
  Future<void> enable(String owner, ProxyConfig config) async {
    try {
      await _channel.invokeMethod<void>('enable', {
        'owner': owner,
        'httpPort': config.httpEnabled ? config.httpPort : 0,
        'httpsPort': config.httpsEnabled ? config.httpsPort : 0,
        'socksPort': config.socks5Enabled ? config.socks5Port : 0,
      });
    } on PlatformException catch (error) {
      throw SystemProxyException(switch (error.code) {
        'proxy_conflict' => '系统代理已被占用，请先停止其他代理或取消自动设置',
        'proxy_permission' => '没有修改系统代理的权限，请授权后重试',
        _ => '自动设置系统代理失败，请检查系统设置或取消自动设置',
      });
    } on MissingPluginException {
      throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
    }
  }

  @override
  Future<void> restore(String owner) async {
    try {
      await _channel.invokeMethod<void>('restore', {'owner': owner});
    } on PlatformException catch (error) {
      if (error.code == 'proxy_restore_conflict') {
        throw const SystemProxyException('系统代理配置已被部分修改，请在系统设置中移除本应用代理后重试停止');
      }
      rethrow;
    }
  }
}
