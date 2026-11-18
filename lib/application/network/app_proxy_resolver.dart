import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/proxy/system_proxy_lookup.dart';
import '../settings/settings_controller.dart';

/// 根据用户代理设置与系统代理，解析每次 HTTP 请求应使用的代理节点。
class AppProxyResolver {
  const AppProxyResolver({
    required this._settings,
    required this._systemLookup,
  });

  final SettingsController _settings;
  final SystemProxyLookup _systemLookup;

  Future<AppProxyEndpoint?> resolve(Uri target) async {
    await _settings.ready;
    if (_settings.proxyLoadFailed.value) return null;
    final config = _settings.proxySettings.value;
    switch (config.mode) {
      case AppProxyMode.off:
        return null;
      case AppProxyMode.auto:
        return _systemLookup.resolve(target);
      case AppProxyMode.manual:
        var password = '';
        if (config.hasSavedPassword) {
          try {
            password = (await _settings.readProxyPassword()) ?? '';
          } on Object {
            password = '';
          }
        }
        return AppProxySettings.parseAddress(
          config.address,
          config.protocol,
          username: config.username,
          password: password,
        );
    }
  }
}
