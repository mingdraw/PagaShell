import 'dart:convert';

import '../../domain/entities/host.dart';
import '../../domain/entities/proxy_config.dart';

typedef _Json = Map<String, Object?>;

const _loopback = '127.0.0.1';
const _invalidConfig = V2RayConfigException('请选择完整的 V2Ray 或 Xray JSON 配置');

class V2RayConfigException implements Exception {
  const V2RayConfigException(this.message, {this.port});

  final String message;
  final int? port;
}

/// A V2Ray/Xray JSON export using the current gateway's local TCP listener.
class V2RayExtensionConfig {
  V2RayExtensionConfig(this._gateway, this._config) {
    _config.validate(forStart: true);
  }

  final Host _gateway;
  final ProxyConfig _config;

  ProxyMode get mode => _config.mode;
  bool get hasRules => _config.rules.isNotEmpty;

  String get _tag => 'pagashell-${Uri.encodeComponent(_gateway.id)}';
  Set<int> get _gatewayPorts => {
    if (_config.httpEnabled) _config.httpPort,
    if (_config.httpsEnabled) _config.httpsPort,
    if (_config.socks5Enabled) _config.socks5Port,
  };

  int get socksInboundPort {
    final used = _gatewayPorts;
    var port = 10808;
    while (used.contains(port) || used.contains(port + 1)) {
      port += 2;
    }
    return port;
  }

  int get httpInboundPort => socksInboundPort + 1;

  String get source => _merge({
    'remarks': 'PagaShell - ${_gateway.name}',
    'inbounds': <_Json>[
      {
        'tag': 'socks',
        'listen': _loopback,
        'port': socksInboundPort,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': false},
      },
      {
        'tag': 'http',
        'listen': _loopback,
        'port': httpInboundPort,
        'protocol': 'http',
      },
    ],
    'outbounds': <_Json>[
      {'tag': 'direct', 'protocol': 'freedom'},
    ],
  });

  String mergeInto(String source) {
    final _Json base;
    try {
      base = _object(jsonDecode(source));
    } on FormatException {
      throw _invalidConfig;
    }
    for (final key in ['inbounds', 'outbounds']) {
      final entries = _objects(base[key]);
      if (entries.isEmpty ||
          entries.any((entry) => entry['protocol'] is! String)) {
        throw _invalidConfig;
      }
    }
    for (final inbound in _objects(base['inbounds'])) {
      for (final port in _gatewayPorts) {
        if (_includesPort(inbound['port'], port)) {
          throw V2RayConfigException(
            '现有配置已监听 PagaShell 代理端口 @port，请先修改其中一个端口',
            port: port,
          );
        }
      }
    }
    return _merge(base);
  }

  String _merge(_Json base) {
    final routing = base['routing'] == null
        ? <String, Object?>{}
        : _object(base['routing']);
    if (routing['script'] case final String script
        when script.trim().isNotEmpty) {
      throw const V2RayConfigException('现有配置使用了路由脚本，无法自动合并分流规则');
    }
    final outbounds = _objects(base['outbounds']);
    final oldIndex = outbounds.indexWhere(
      (outbound) => outbound['tag'] == _tag,
    );
    outbounds.removeWhere((outbound) => outbound['tag'] == _tag);
    outbounds.insert(oldIndex < 0 ? outbounds.length : oldIndex, _outbound());

    final rules = _objects(routing['rules'])
      ..removeWhere((rule) => rule['outboundTag'] == _tag);
    var strategy = routing['domainStrategy'];
    if (mode == ProxyMode.global) {
      final fallback = rules.indexWhere(_isTcpFallback);
      if (fallback < 0 &&
          strategy == 'IPIfNonMatch' &&
          rules.any(
            (rule) => switch (rule['ip']) {
              List<Object?> ip => ip.isNotEmpty,
              _ => false,
            },
          )) {
        // The new fallback would otherwise prevent the IP resolution pass.
        strategy = 'IPOnDemand';
      }
      // Keep the old fallback for UDP, which PagaShell cannot forward.
      rules.insert(fallback < 0 ? rules.length : fallback, _rule());
    } else {
      final domains = <String>{};
      final ips = <String>{};
      for (final rule in _config.rules) {
        final value = rule.value.trim().toLowerCase();
        if (rule.type == ProxyRuleType.ip) {
          ips.add(
            value.contains('/')
                ? value
                : '$value/${value.contains(':') ? 128 : 32}',
          );
        } else {
          final domain = value.endsWith('.')
              ? value.substring(0, value.length - 1)
              : value;
          domains.add(switch (rule.type) {
            ProxyRuleType.domainExact => 'full:$domain',
            ProxyRuleType.domainSuffix => 'domain:$domain',
            ProxyRuleType.domainPrefix => 'regexp:(?i)^${RegExp.escape(value)}',
            ProxyRuleType.ip => throw StateError('Expected a domain rule'),
          });
        }
      }
      if (ips.isNotEmpty) strategy = 'IPOnDemand';
      rules.insertAll(0, [
        // V2Ray combines domain and IP fields in one rule with AND.
        if (domains.isNotEmpty) _rule('domain', domains.toList()),
        if (ips.isNotEmpty) _rule('ip', ips.toList()),
      ]);
    }

    return const JsonEncoder.withIndent('  ').convert({
      ...base,
      'outbounds': outbounds,
      if (routing.isNotEmpty || rules.isNotEmpty)
        'routing': {...routing, 'domainStrategy': ?strategy, 'rules': rules},
    });
  }

  _Json _outbound() {
    final http = _config.httpEnabled || _config.httpsEnabled;
    return {
      'tag': _tag,
      'protocol': http ? 'http' : 'socks',
      'settings': {
        'servers': [
          {
            'address': _loopback,
            'port': http
                ? (_config.httpEnabled ? _config.httpPort : _config.httpsPort)
                : _config.socks5Port,
          },
        ],
      },
    };
  }

  _Json _rule([String? field, List<String>? values]) => {
    'type': 'field',
    'network': 'tcp',
    ?field: values,
    'outboundTag': _tag,
  };

  static _Json _object(Object? value) =>
      value is _Json ? value : throw _invalidConfig;

  static List<_Json> _objects(Object? value) => switch (value) {
    null => [],
    List<Object?> entries => entries.map(_object).toList(),
    _ => throw _invalidConfig,
  };

  static bool _includesPort(Object? value, int port) {
    if (value is int) return value == port;
    if (value is! String) return false;
    return value.split(',').any((range) {
      final ends = range.split('-');
      final start = int.tryParse(ends.first.trim());
      final end = int.tryParse(ends.last.trim());
      return start != null && end != null && start <= port && port <= end;
    });
  }

  static bool _isTcpFallback(_Json rule) {
    const keys = {
      'type',
      'tag',
      'ruleTag',
      'outboundTag',
      'balancerTag',
      'enabled',
      'domainMatcher',
      'network',
      'port',
    };
    if (rule.entries.any((entry) {
      final value = entry.value;
      return !keys.contains(entry.key) &&
          value != null &&
          value != '' &&
          !(value is List<Object?> && value.isEmpty);
    })) {
      return false;
    }
    final allPorts = switch (rule['port']) {
      null => true,
      String range => const {'', '0-65535', '1-65535'}.contains(range.trim()),
      _ => false,
    };
    final tcp = switch (rule['network']) {
      null => true,
      String network =>
        network.trim().isEmpty ||
            network.split(',').map((s) => s.trim()).contains('tcp'),
      List<Object?> networks => networks.isEmpty || networks.contains('tcp'),
      _ => false,
    };
    return allPorts && tcp;
  }
}
