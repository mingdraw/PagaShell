import 'dart:io';

import '../entities/proxy_config.dart';

enum ProxyPreviewRoute { gateway, direct, needsDns }

typedef ProxyRulePreview = ({ProxyPreviewRoute route, ProxyRule? rule});

/// Mirrors the Rust router. Domain rules precede IP rules for a hostname.
/// DNS answers are supplied by the caller; a preview never makes a request.
ProxyRulePreview previewProxyRules(
  ProxyConfig config,
  String target, {
  Iterable<String> dnsAddresses = const [],
}) {
  final normalized = target.trim().toLowerCase().replaceFirst(
    RegExp(r'\.+$'),
    '',
  );
  final ip = _address(normalized);
  if (ip == null) {
    ProxyRule(type: ProxyRuleType.domainExact, value: normalized).validate();
  }
  if (config.mode == ProxyMode.global) {
    return (route: ProxyPreviewRoute.gateway, rule: null);
  }
  final ipRules = <ProxyRule>[];
  for (final rule in config.rules) {
    if (rule.type == ProxyRuleType.ip) {
      ipRules.add(rule);
    } else if (ip == null) {
      final raw = rule.value.trim().toLowerCase();
      final domain = raw.replaceFirst(RegExp(r'\.+$'), '');
      final matches = switch (rule.type) {
        ProxyRuleType.domainExact => normalized == domain,
        ProxyRuleType.domainPrefix => normalized.startsWith(raw),
        ProxyRuleType.domainSuffix =>
          normalized == domain || normalized.endsWith('.$domain'),
        ProxyRuleType.ip => false,
      };
      if (matches) return (route: ProxyPreviewRoute.gateway, rule: rule);
    }
  }
  if (ipRules.isEmpty) return (route: ProxyPreviewRoute.direct, rule: null);
  final List<InternetAddress> targets;
  if (ip != null) {
    targets = [ip];
  } else {
    targets = [];
    for (final address in dnsAddresses) {
      final value = _address(address.trim());
      if (value == null) throw StateError('请填写有效的 DNS 解析 IP 地址');
      targets.add(value);
    }
    if (targets.isEmpty) {
      return (route: ProxyPreviewRoute.needsDns, rule: null);
    }
  }
  for (final rule in ipRules) {
    rule.validate();
    final parts = rule.value.trim().split('/');
    final network = InternetAddress(parts.first).rawAddress;
    final prefix = parts.length == 2 ? int.parse(parts[1]) : network.length * 8;
    if (targets.any((address) {
      final bytes = address.rawAddress;
      if (bytes.length != network.length) return false;
      for (var bit = 0; bit < prefix; bit += 8) {
        final shift = (bit + 8 - prefix).clamp(0, 8);
        final index = bit ~/ 8;
        if (bytes[index] >> shift != network[index] >> shift) return false;
      }
      return true;
    })) {
      return (route: ProxyPreviewRoute.gateway, rule: rule);
    }
  }
  return (route: ProxyPreviewRoute.direct, rule: null);
}

InternetAddress? _address(String value) {
  if (value.contains('%')) return null;
  if (value.startsWith('[') && value.endsWith(']')) {
    final ip = InternetAddress.tryParse(value.substring(1, value.length - 1));
    return ip?.type == InternetAddressType.IPv6 ? ip : null;
  }
  return InternetAddress.tryParse(value);
}
