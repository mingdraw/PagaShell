import 'dart:convert';

import '../../domain/entities/host.dart';
import '../../domain/entities/proxy_config.dart';

/// A local Clash node and routing rules for the selected gateway proxy mode.
class ClashExtensionScript {
  ClashExtensionScript._(
    this.mode,
    Map<String, Object> node,
    List<String> rules,
  ) : node = Map.unmodifiable(node),
      rules = List.unmodifiable(rules);

  factory ClashExtensionScript.fromConfig(Host gateway, ProxyConfig config) {
    config.validate(forStart: true);
    String label(String value) =>
        value.replaceAll(RegExp(r'[\x00-\x1f\x7f,]'), ' ').trim();
    final name = 'PagaShell-${label(gateway.name)} [${label(gateway.id)}]';
    final http = config.httpEnabled || config.httpsEnabled;
    final node = <String, Object>{
      'name': name,
      'type': http ? 'http' : 'socks5',
      'server': '127.0.0.1',
      'port': http
          ? (config.httpEnabled ? config.httpPort : config.httpsPort)
          : config.socks5Port,
      if (!http) 'udp': false,
    };
    String convert(ProxyRule rule) {
      final value = rule.value.trim().toLowerCase();
      final domain = value.endsWith('.')
          ? value.substring(0, value.length - 1)
          : value;
      return switch (rule.type) {
        ProxyRuleType.domainExact => 'DOMAIN,$domain,$name',
        ProxyRuleType.domainSuffix => 'DOMAIN-SUFFIX,$domain,$name',
        // Prefix rules match strings, without imposing a DNS label boundary.
        ProxyRuleType.domainPrefix =>
          'DOMAIN-REGEX,(?i)^${RegExp.escape(value)},$name',
        ProxyRuleType.ip =>
          '${value.contains(':') ? 'IP-CIDR6' : 'IP-CIDR'},'
              '${value.contains('/') ? value : '$value/${value.contains(':') ? 128 : 32}'},$name',
      };
    }

    // Match all domain rules before any IP rule can trigger local DNS, as the
    // gateway router does. Keep IP resolution enabled for domain-to-CIDR rules.
    final rules = <String>{
      if (config.mode == ProxyMode.global)
        'MATCH,$name'
      else ...[
        for (final rule in config.rules)
          if (rule.type != ProxyRuleType.ip) convert(rule),
        for (final rule in config.rules)
          if (rule.type == ProxyRuleType.ip) convert(rule),
      ],
    };
    return ClashExtensionScript._(config.mode, node, rules.toList());
  }

  final ProxyMode mode;
  final Map<String, Object> node;
  final List<String> rules;

  String get source {
    String literal(Object value) =>
        const JsonEncoder.withIndent('  ')
            .convert(value)
            .replaceAll('\u2028', r'\u2028')
            .replaceAll('\u2029', r'\u2029')
            .replaceAll('\n', '\n  ');
    final routing = mode == ProxyMode.global
        ? r'''  // Keep explicit Clash routes and replace only the final fallback.
  config.rules = [
    ...(config.rules || []).filter(rule => !/^\s*(MATCH|FINAL)\s*,/i.test(rule)),
    ...rules
  ];'''
        : '''  config.rules = [
    ...rules,
    ...(config.rules || []).filter(rule => !rules.includes(rule))
  ];''';

    return '''// PagaShell gateway node and routing rules.
// Merge with the existing main function if you already use a custom script.
function main(config) {
  const node = ${literal(node)};
  const rules = ${literal(rules)};

  config.proxies = [
    ...(config.proxies || []).filter(proxy => proxy.name !== node.name),
    node
  ];
$routing
  return config;
}
''';
  }
}
