import 'dart:io';

enum ProxyMode { rule, global }

enum ProxyRuleType { ip, domainExact, domainPrefix, domainSuffix }

class ProxyRule {
  const ProxyRule({required this.type, required this.value});
  final ProxyRuleType type;
  final String value;

  void validate() {
    final text = value.trim();
    if (type == ProxyRuleType.ip) {
      final parts = text.split('/');
      final ip = InternetAddress.tryParse(parts.first);
      final bits = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (text.contains('%') ||
          parts.length > 2 ||
          ip == null ||
          (parts.length == 2 &&
              (bits == null || bits < 0 || bits > ip.rawAddress.length * 8))) {
        throw StateError('请填写有效的 IPv4、IPv6 或 CIDR');
      }
    } else if (text.isEmpty ||
        text.length > 253 ||
        !RegExp(r'^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.?$').hasMatch(text) ||
        InternetAddress.tryParse(text) != null) {
      throw StateError('请填写域名，不包含协议、端口或通配符');
    }
  }

  Map<String, Object?> toJson() => {'type': type.name, 'value': value.trim()};
  factory ProxyRule.fromJson(Map<String, dynamic> json) => ProxyRule(
    type: ProxyRuleType.values.byName(json['type'] as String),
    value: json['value'] as String,
  );
}

/// 本机显式代理入口。HTTPS 表示 CONNECT 隧道，不终止网站 TLS。
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.global,
    this.httpEnabled = true,
    this.httpPort = 18080,
    this.httpsEnabled = true,
    this.httpsPort = 18080,
    this.socks5Enabled = false,
    this.socks5Port = 1080,
    this.autoSystemProxy = false,
    this.rules = const [],
  });

  final ProxyMode mode;
  final bool httpEnabled;
  final int httpPort;
  final bool httpsEnabled;
  final int httpsPort;
  final bool socks5Enabled;
  final int socks5Port;
  final bool autoSystemProxy;
  final List<ProxyRule> rules;

  void validate({bool forStart = false}) {
    for (final port in [httpPort, httpsPort, socks5Port]) {
      if (port < 1 || port > 65535) {
        throw StateError('请填写有效的端口（1-65535）');
      }
    }
    if (forStart && !httpEnabled && !httpsEnabled && !socks5Enabled) {
      throw StateError('请至少启用一种代理协议');
    }
    if (rules.length > 10000) throw StateError('代理规则过多');
    for (final rule in rules) {
      rule.validate();
    }
  }

  /// Only listener/routing settings cross the strict Rust configuration boundary.
  Map<String, Object?> toEngineJson() => {
    'mode': mode.name,
    'httpEnabled': httpEnabled,
    'httpPort': httpPort,
    'httpsEnabled': httpsEnabled,
    'httpsPort': httpsPort,
    'socks5Enabled': socks5Enabled,
    'socks5Port': socks5Port,
    'rules': rules.map((r) => r.toJson()).toList(),
  };

  Map<String, Object?> toJson() => {
    ...toEngineJson(),
    'autoSystemProxy': autoSystemProxy,
  };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    final mode = json['mode'] as String? ?? 'global';
    final result = ProxyConfig(
      // 兼容旧配置，直连模式归并到规则模式。
      mode: mode == 'direct' ? ProxyMode.rule : ProxyMode.values.byName(mode),
      httpEnabled: json['httpEnabled'] as bool? ?? true,
      httpPort: json['httpPort'] as int? ?? 18080,
      httpsEnabled: json['httpsEnabled'] as bool? ?? true,
      httpsPort: json['httpsPort'] as int? ?? 18080,
      socks5Enabled: json['socks5Enabled'] as bool? ?? false,
      socks5Port: json['socks5Port'] as int? ?? 1080,
      autoSystemProxy: json['autoSystemProxy'] as bool? ?? false,
      rules: List.unmodifiable(
        (json['rules'] as List<dynamic>? ?? []).map(
          (r) => ProxyRule.fromJson(r as Map<String, dynamic>),
        ),
      ),
    );
    result.validate();
    return result;
  }
}
