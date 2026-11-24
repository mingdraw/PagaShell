const firewallQueryTimeout = Duration(seconds: 15);
const firewallMutateTimeout = Duration(seconds: 30);
const firewallUnsupportedSystemMessage = '不支持当前系统的防火墙，仅支持 Linux';

/// Linux 主机防火墙规则读取与维护接口，支持 firewalld / ufw / nftables / iptables。
abstract interface class FirewallSource {
  Future<FirewallSnapshot> readFirewall();

  Future<void> addFirewallRules(
    FirewallBackend backend,
    List<FirewallRuleInput> rules,
  );

  Future<void> deleteFirewallRule(FirewallRule rule);

  Future<void> runFirewallServiceAction(
    FirewallBackend backend,
    FirewallServiceAction action,
  );
}

enum FirewallBackend {
  firewalld,
  ufw,
  nftables,
  iptables;

  String get displayName => name;

  bool get supportsPriority => this == firewalld;

  bool get supportsComment => this != firewalld;
}

enum FirewallServiceState { active, inactive }

enum FirewallAction { allow, deny }

enum FirewallProtocol {
  tcp,
  udp,
  tcpUdp;

  String get label => switch (this) {
    tcp => 'TCP',
    udp => 'UDP',
    tcpUdp => 'TCP/UDP',
  };
}

enum FirewallAddressFamily { any, ipv4, ipv6 }

enum FirewallServiceAction { enable, disable, reload }

class FirewallUsedProcess {
  const FirewallUsedProcess({required this.port, required this.name, this.pid});

  final int port;
  final String name;
  final int? pid;

  String get label => name.isEmpty ? '$port' : '$name ($port)';
}

class FirewallRule {
  const FirewallRule({
    required this.id,
    required this.backend,
    required this.action,
    required this.protocol,
    required this.port,
    required this.source,
    required this.family,
    this.priority,
    this.comment = '',
    this.zone = '',
    this.chain = '',
    this.rawRule = '',
    this.usedProcesses = const [],
  });

  final String id;
  final FirewallBackend backend;
  final FirewallAction action;
  final FirewallProtocol protocol;
  final String port;
  final String source;
  final FirewallAddressFamily family;
  final int? priority;
  final String comment;
  final String zone;
  final String chain;
  final String rawRule;
  final List<FirewallUsedProcess> usedProcesses;

  bool get isAnySource =>
      source.isEmpty ||
      source == '0.0.0.0/0' ||
      source == '::/0' ||
      source == '0.0.0.0/0, ::/0';

  bool get coversSsh =>
      coversPort(22) ||
      usedProcesses.any((p) => p.name.toLowerCase() == 'sshd');

  bool coversPort(int target) {
    for (final segment in port.split(',')) {
      final token = segment.trim();
      if (token.isEmpty) continue;
      final dash = token.indexOf('-');
      if (dash > 0) {
        final start = int.tryParse(token.substring(0, dash));
        final end = int.tryParse(token.substring(dash + 1));
        if (start != null && end != null && target >= start && target <= end) {
          return true;
        }
      } else {
        final single = int.tryParse(token);
        if (single == target) return true;
      }
    }
    return false;
  }

  bool matchesProtocolFilter(FirewallProtocol? filter) {
    if (filter == null) return true;
    return protocol == FirewallProtocol.tcpUdp || protocol == filter;
  }

  bool matchesQuery(String term) {
    if (term.isEmpty) return true;
    return port.toLowerCase().contains(term) ||
        source.toLowerCase().contains(term) ||
        protocol.label.toLowerCase().contains(term) ||
        comment.toLowerCase().contains(term) ||
        zone.toLowerCase().contains(term) ||
        chain.toLowerCase().contains(term) ||
        usedProcesses.any(
          (p) => p.name.toLowerCase().contains(term) || '${p.port}' == term,
        );
  }
}

class FirewallRuleInput {
  const FirewallRuleInput({
    required this.action,
    required this.protocol,
    required this.port,
    this.source = '',
    this.priority,
    this.comment = '',
  });

  final FirewallAction action;
  final FirewallProtocol protocol;
  final String port;
  final String source;
  final int? priority;
  final String comment;

  static final _forbiddenCommentChars = RegExp(
    r'''[\x00-\x1f\x7f'"\\`$;|&<>]''',
  );
  static final _digitsOnly = RegExp(r'^\d+$');

  /// 解析单个端口（80）或端口段（8080-8089），返回规范化结果；无效返回 null。
  static String? normalizeSinglePort(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 11) return null;
    final dash = trimmed.indexOf('-');
    if (dash >= 0) {
      if (trimmed.indexOf('-', dash + 1) >= 0) return null;
      final startText = trimmed.substring(0, dash);
      final endText = trimmed.substring(dash + 1);
      if (!_digitsOnly.hasMatch(startText) || !_digitsOnly.hasMatch(endText)) {
        return null;
      }
      final start = int.tryParse(startText);
      final end = int.tryParse(endText);
      if (start == null || end == null || start < 1 || end > 65535) {
        return null;
      }
      if (start >= end) return null;
      return '$start-$end';
    }
    if (!_digitsOnly.hasMatch(trimmed)) return null;
    final port = int.tryParse(trimmed);
    if (port == null || port < 1 || port > 65535) return null;
    return '$port';
  }

  /// 解析逗号分隔的端口列表（例如 `80,443`、`8080-8089`），任一项无效则返回 null。
  static List<String>? parsePortSpecs(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final result = <String>[];
    for (final part in trimmed.split(RegExp(r'[,，]'))) {
      final normalized = normalizeSinglePort(part);
      if (normalized == null) return null;
      result.add(normalized);
    }
    return result.isEmpty ? null : result;
  }

  /// 校验单个 IP 或 CIDR（留空表示任何位置），返回规范化字符串；无效返回 null。
  static String? normalizeSource(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final slash = trimmed.indexOf('/');
    if (slash >= 0) {
      if (trimmed.indexOf('/', slash + 1) >= 0) return null;
      final host = trimmed.substring(0, slash);
      final prefixText = trimmed.substring(slash + 1);
      if (!_digitsOnly.hasMatch(prefixText)) return null;
      final prefix = int.tryParse(prefixText);
      if (prefix == null) return null;
      if (_isValidIpv4(host) && prefix <= 32) return '$host/$prefix';
      if (_isValidIpv6(host) && prefix <= 128) return '$host/$prefix';
      return null;
    }
    if (_isValidIpv4(trimmed) || _isValidIpv6(trimmed)) return trimmed;
    return null;
  }

  /// 校验优先级文本（firewalld 富规则：-32768 ~ 32767）。
  static bool isValidPriority(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return true;
    final parsed = int.tryParse(trimmed);
    return parsed != null && parsed >= -32768 && parsed <= 32767;
  }

  /// 校验规则描述（最多 128 字符，不含控制字符或引号/命令分隔符）。
  static String? validateComment(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.runes.length > 128) return '描述不能超过 128 个字符';
    if (_forbiddenCommentChars.hasMatch(trimmed)) return '描述包含不支持的特殊字符';
    return null;
  }

  static bool _isValidIpv4(String value) {
    try {
      Uri.parseIPv4Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _isValidIpv6(String value) {
    if (!value.contains(':')) return false;
    try {
      Uri.parseIPv6Address(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}

class FirewallSnapshot {
  const FirewallSnapshot({
    required this.backend,
    required this.state,
    this.version = '',
    this.zone = '',
    this.policy = '',
    this.serviceActions = const {},
    this.rules = const [],
  });

  final FirewallBackend backend;
  final FirewallServiceState state;
  final String version;
  final String zone;
  final String policy;
  final Set<FirewallServiceAction> serviceActions;
  final List<FirewallRule> rules;

  bool get isActive => state == FirewallServiceState.active;
}
