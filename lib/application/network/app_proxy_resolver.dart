import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/proxy/system_proxy_lookup.dart';
import '../settings/settings_controller.dart';

/// 根据用户代理设置与系统代理，解析每次 HTTP 请求应使用的代理节点。
class AppProxyResolver {
  AppProxyResolver({
    required this._settings,
    required this._systemLookup,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _monotonicClock();

  final SettingsController _settings;
  final SystemProxyLookup _systemLookup;
  final Duration Function() _elapsed;
  final _cache = <Object, _ProxyLookup>{};
  AppProxySettings? _current;
  static const _manualKey = Object();
  static const _ttl = Duration(seconds: 10);
  static const _cacheLimit = 64;

  Future<AppProxyEndpoint?> resolve(Uri target) async {
    await _settings.ready;
    while (true) {
      if (_settings.proxyLoadFailed.value) {
        _cache.clear();
        _current = null;
        return null;
      }
      final config = _settings.proxySettings.value;
      if (!identical(_current, config)) {
        _cache.clear();
        _current = config;
      }
      if (config.mode == AppProxyMode.off) return null;
      bool stillCurrent() =>
          !_settings.proxyLoadFailed.value &&
          identical(config, _settings.proxySettings.value);
      try {
        final endpoint = config.mode == AppProxyMode.auto
            // PAC may route paths on the same origin differently.
            ? await _cached(
                target,
                () async => (await _systemLookup.resolve(target), true),
              )
            : await _cached(_manualKey, () => _loadManual(config));
        if (stillCurrent()) return endpoint;
      } on Object {
        if (stillCurrent()) rethrow;
      }
    }
  }

  Future<(AppProxyEndpoint?, bool)> _loadManual(AppProxySettings config) async {
    var password = '';
    var cacheable = true;
    if (config.hasSavedPassword) {
      try {
        final stored = await _settings.readProxyPassword();
        password = stored ?? '';
        cacheable = stored != null;
      } on Object {
        // A user can unlock the vault before the next request.
        cacheable = false;
      }
    }
    return (
      AppProxySettings.parseAddress(
        config.address,
        config.protocol,
        username: config.username,
        password: password,
      ),
      cacheable,
    );
  }

  Future<AppProxyEndpoint?> _cached(
    Object key,
    Future<(AppProxyEndpoint?, bool)> Function() load,
  ) {
    final now = _elapsed();
    final cached = _cache.remove(key);
    final expiry = cached?.expiry;
    if (cached != null && (expiry == null || now < expiry)) {
      _cache[key] = cached;
      return cached.result;
    }
    _cache.removeWhere((_, entry) {
      final expiry = entry.expiry;
      return expiry != null && expiry <= now;
    });
    final lookup = _ProxyLookup();
    _cache[key] = lookup;
    if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
    void forget() {
      if (identical(_cache[key], lookup)) _cache.remove(key);
    }

    return lookup.result = () async {
      try {
        final (endpoint, cacheable) = await load();
        if (cacheable) {
          lookup.expiry = _elapsed() + _ttl;
        } else {
          forget();
        }
        return endpoint;
      } on Object {
        forget();
        rethrow;
      }
    }();
  }
}

Duration Function() _monotonicClock() {
  final clock = Stopwatch()..start();
  return () => clock.elapsed;
}

class _ProxyLookup {
  late final Future<AppProxyEndpoint?> result;
  Duration? expiry;
}
