import 'dart:convert';

import '../../domain/ssh/firewall.dart';
import '../../domain/ssh/ssh_engine.dart';

final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]');
final _ssRow = RegExp(
  r'^(tcp|udp)\s+(\S+)\s+\d+\s+\d+\s+(\S+)\s+\S+(?:\s+(.*))?$',
);
final _ssProcess = RegExp(r'\("((?:\\.|[^"\\])*)",pid=(\d+),');
final _firewalldPort = RegExp(r'^(\d+(?:-\d+)?)/(tcp|udp)$');
final _firewalldRichPort = RegExp(
  r'\bport\s+port="(\d+(?:-\d+)?)"\s+protocol="(tcp|udp)"',
);
final _firewalldRichFamily = RegExp(r'\bfamily="(ipv4|ipv6)"');
final _firewalldRichPriority = RegExp(r'\bpriority="(-?\d+)"');
final _firewalldRichSource = RegExp(r'\bsource\s+address="([^"]+)"');
final _ufwNumbered = RegExp(r'^\s*\[\s*(\d+)\]\s+(.+)$');
final _ufwAction = RegExp(
  r'^(.+?)\s+(ALLOW|DENY|REJECT|LIMIT)\s+(IN|OUT|FWD)\s+(.+)$',
);
final _ufwPortSpec = RegExp(
  r'^(\d+(?::\d+)?(?:,\d+(?::\d+)?)*)(?:/(tcp|udp))?$',
);
final _nftTable = RegExp(r'^table\s+(inet|ip|ip6)\s+([A-Za-z0-9_.-]+)\s*\{');
final _nftChain = RegExp(r'^\s*chain\s+([A-Za-z0-9_.-]+)\s*\{');
final _nftInputHook = RegExp(r'\btype\s+filter\s+hook\s+input\b');
final _nftPolicy = RegExp(r'\bpolicy\s+(accept|drop)\b');
final _nftHandle = RegExp(r'^(.*?)#\s*handle\s+(\d+)\s*$');
final _nftProtoPort = RegExp(
  r'\b(tcp|udp)\s+dport\s+(\{[^}]+\}|\d+-\d+|\d+|[a-zA-Z0-9_-]+)',
);
final _nftDualProtoPort = RegExp(
  r'\bmeta\s+l4proto\s+\{\s*(?:tcp\s*,\s*udp|udp\s*,\s*tcp)\s*\}\s+th\s+dport\s+(\{[^}]+\}|\d+-\d+|\d+)',
);
final _nftSource4 = RegExp(r'\bip\s+saddr\s+(\{[^}]+\}|[0-9./]+)');
final _nftSource6 = RegExp(r'\bip6\s+saddr\s+(\{[^}]+\}|[0-9a-fA-F:./]+)');
final _nftComment = RegExp(r'\bcomment\s+"([^"]*)"');
final _nftVerdict = RegExp(r'\b(accept|drop|reject)\b');

const _wellKnownPorts = <String, String>{
  'ftp': '21',
  'ssh': '22',
  'telnet': '23',
  'smtp': '25',
  'domain': '53',
  'http': '80',
  'ntp': '123',
  'https': '443',
  'smtps': '465',
  'submission': '587',
  'mysql': '3306',
  'postgresql': '5432',
  'redis': '6379',
  'http-alt': '8080',
};

FirewallSnapshot parseFirewallSnapshot(String raw) {
  try {
    final lines = const LineSplitter().convert(raw);
    if (lines.length < 10 ||
        lines.first != 'PAGA_FIREWALL_V1' ||
        lines.last != 'END_FIREWALL') {
      _invalid();
    }
    final rulesMarker = lines.indexOf('---RULES---');
    final listenersMarker = lines.indexOf('---LISTENERS---');
    if (rulesMarker < 2 ||
        listenersMarker <= rulesMarker ||
        listenersMarker >= lines.length - 1) {
      _invalid();
    }

    final headers = <String, String>{};
    for (final line in lines.sublist(1, rulesMarker)) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      headers[line.substring(0, space)] = _clean(line.substring(space + 1));
    }

    final backend = _parseBackend(headers['BACKEND'] ?? '');
    final available = <FirewallBackend>[];
    for (final token in (headers['AVAILABLE'] ?? '').split(',')) {
      final trimmed = token.trim();
      if (trimmed.isEmpty) continue;
      final parsed = _tryParseBackend(trimmed);
      if (parsed != null && !available.contains(parsed)) {
        available.add(parsed);
      }
    }
    if (!available.contains(backend)) available.insert(0, backend);

    final state = switch (headers['STATE']) {
      'active' => FirewallServiceState.active,
      'inactive' => FirewallServiceState.inactive,
      _ => _invalid(),
    };
    final version = headers['VERSION'] ?? '';
    final zone = headers['ZONE'] ?? '';
    var policy = (headers['POLICY'] ?? '').toUpperCase();
    final serviceActions = <FirewallServiceAction>{};
    for (final token in (headers['SERVICE_ACTIONS'] ?? '').split(',')) {
      switch (token.trim()) {
        case 'enable':
          serviceActions.add(FirewallServiceAction.enable);
        case 'disable':
          serviceActions.add(FirewallServiceAction.disable);
        case 'reload':
          serviceActions.add(FirewallServiceAction.reload);
      }
    }

    final ruleLines = lines.sublist(rulesMarker + 1, listenersMarker);
    final listenerLines = lines.sublist(listenersMarker + 1, lines.length - 1);
    final listeners = _parseListeners(listenerLines);

    final rules = switch (backend) {
      FirewallBackend.firewalld => _parseFirewalld(ruleLines, zone, listeners),
      FirewallBackend.ufw => _parseUfw(ruleLines, listeners),
      FirewallBackend.nftables => () {
        final parsed = _parseNftables(ruleLines, listeners);
        if (policy.isEmpty && parsed.policy.isNotEmpty) {
          policy = parsed.policy;
        }
        return parsed.rules;
      }(),
      FirewallBackend.iptables => _parseIptables(ruleLines, listeners),
    };

    return FirewallSnapshot(
      backend: backend,
      availableBackends: List.unmodifiable(available),
      state: state,
      version: version,
      zone: zone,
      policy: policy,
      serviceActions: Set.unmodifiable(serviceActions),
      rules: List.unmodifiable(rules),
    );
  } on Object {
    throw const SshEngineException('防火墙数据格式无效，请重试');
  }
}

class _Listener {
  const _Listener({
    required this.protocol,
    required this.port,
    required this.name,
    this.pid,
  });

  final FirewallProtocol protocol;
  final int port;
  final String name;
  final int? pid;
}

List<_Listener> _parseListeners(List<String> lines) {
  final result = <_Listener>[];
  var section = '';
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line == 'SS4' || line == 'SS6') {
      section = line;
      continue;
    }
    if (section != 'SS4' && section != 'SS6') continue;
    final match = _ssRow.firstMatch(line);
    if (match == null) continue;
    final tcp = match[1] == 'tcp';
    if (match[2] != (tcp ? 'LISTEN' : 'UNCONN')) continue;
    final endpoint = match[3]!;
    final colon = endpoint.lastIndexOf(':');
    if (colon <= 0) continue;
    final port = int.tryParse(endpoint.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) continue;
    final protocol = tcp ? FirewallProtocol.tcp : FirewallProtocol.udp;
    final tail = match[4] ?? '';
    final procs = _ssProcess.allMatches(tail).toList();
    if (procs.isEmpty) {
      result.add(_Listener(protocol: protocol, port: port, name: ''));
      continue;
    }
    for (final p in procs) {
      final pid = int.tryParse(p[2]!);
      String name;
      try {
        name = jsonDecode('"${p[1]}"') as String;
      } on Object {
        name = p[1]!.replaceAll(r'\', '');
      }
      result.add(
        _Listener(protocol: protocol, port: port, name: _clean(name), pid: pid),
      );
    }
  }
  return result;
}

List<FirewallUsedProcess> _matchListeners(
  FirewallProtocol protocol,
  String portSpec,
  List<_Listener> listeners,
) {
  if (listeners.isEmpty) return const [];
  final probe = FirewallRule(
    id: '',
    backend: FirewallBackend.iptables,
    action: FirewallAction.allow,
    protocol: protocol,
    port: portSpec,
    source: '',
    family: FirewallAddressFamily.any,
  );
  final seen = <String, FirewallUsedProcess>{};
  for (final listener in listeners) {
    if (protocol != FirewallProtocol.tcpUdp && listener.protocol != protocol) {
      continue;
    }
    if (!probe.coversPort(listener.port)) continue;
    if (listener.name.isEmpty) continue;
    final key = '${listener.name}:${listener.port}';
    seen.putIfAbsent(
      key,
      () => FirewallUsedProcess(
        port: listener.port,
        name: listener.name,
        pid: listener.pid,
      ),
    );
  }
  final matched = seen.values.toList()
    ..sort(
      (a, b) => a.port == b.port
          ? a.name.compareTo(b.name)
          : a.port.compareTo(b.port),
    );
  return List.unmodifiable(matched);
}

List<FirewallRule> _parseFirewalld(
  List<String> lines,
  String zone,
  List<_Listener> listeners,
) {
  final rules = <FirewallRule>[];
  var section = '';
  var index = 0;
  for (final rawLine in lines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed == 'FIREWALLD_PORTS' || trimmed == 'FIREWALLD_RICH_RULES') {
      section = trimmed;
      continue;
    }
    if (section == 'FIREWALLD_PORTS') {
      for (final token in trimmed.split(RegExp(r'\s+'))) {
        final match = _firewalldPort.firstMatch(token);
        if (match == null) continue;
        final port = match[1]!;
        final protocol = match[2] == 'tcp'
            ? FirewallProtocol.tcp
            : FirewallProtocol.udp;
        rules.add(
          FirewallRule(
            id: 'firewalld:port:$token:${index++}',
            backend: FirewallBackend.firewalld,
            action: FirewallAction.allow,
            protocol: protocol,
            port: port,
            source: '0.0.0.0/0, ::/0',
            family: FirewallAddressFamily.any,
            zone: zone,
            rawRule: 'port:$token',
            usedProcesses: _matchListeners(protocol, port, listeners),
          ),
        );
      }
    } else if (section == 'FIREWALLD_RICH_RULES') {
      if (!trimmed.startsWith('rule ')) continue;
      final portMatch = _firewalldRichPort.firstMatch(trimmed);
      if (portMatch == null) continue;
      final port = portMatch[1]!;
      final protocol = portMatch[2] == 'tcp'
          ? FirewallProtocol.tcp
          : FirewallProtocol.udp;
      final FirewallAction action;
      if (RegExp(r'\baccept\s*$').hasMatch(trimmed)) {
        action = FirewallAction.allow;
      } else if (RegExp(r'\b(drop|reject(?:\s+type="[^"]*")?)\s*$')
          .hasMatch(trimmed)) {
        action = FirewallAction.deny;
      } else {
        continue;
      }
      final familyText = _firewalldRichFamily.firstMatch(trimmed)?[1] ?? 'ipv4';
      final family = familyText == 'ipv6'
          ? FirewallAddressFamily.ipv6
          : FirewallAddressFamily.ipv4;
      final priorityText = _firewalldRichPriority.firstMatch(trimmed)?[1];
      final priority = priorityText == null
          ? 0
          : int.tryParse(priorityText) ?? 0;
      final sourceMatch = _firewalldRichSource.firstMatch(trimmed);
      final source = sourceMatch != null
          ? _clean(sourceMatch[1]!)
          : (family == FirewallAddressFamily.ipv6 ? '::/0' : '0.0.0.0/0');
      rules.add(
        FirewallRule(
          id: 'firewalld:rich:${index++}:$port:${protocol.name}:$source',
          backend: FirewallBackend.firewalld,
          action: action,
          protocol: protocol,
          port: port,
          source: source,
          family: family,
          priority: priority,
          zone: zone,
          rawRule: 'rich:$trimmed',
          usedProcesses: _matchListeners(protocol, port, listeners),
        ),
      );
    }
  }
  return rules;
}

List<FirewallRule> _parseUfw(List<String> lines, List<_Listener> listeners) {
  final rules = <FirewallRule>[];
  var inStatus = false;
  for (final rawLine in lines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed == 'UFW_STATUS') {
      inStatus = true;
      continue;
    }
    if (!inStatus) continue;
    final numbered = _ufwNumbered.firstMatch(rawLine);
    if (numbered == null) continue;
    final num = numbered[1]!;
    final exactBody = numbered[2]!.trimRight();
    var body = exactBody;
    var comment = '';
    final hash = RegExp(r'\s+#\s*(.*)$').firstMatch(body);
    if (hash != null) {
      comment = _clean(hash[1]!);
      body = body.substring(0, hash.start).trimRight();
    }
    final actionMatch = _ufwAction.firstMatch(body);
    if (actionMatch == null) continue;
    final direction = actionMatch[3]!;
    if (direction != 'IN') continue;
    final action = switch (actionMatch[2]) {
      'ALLOW' || 'LIMIT' => FirewallAction.allow,
      'DENY' || 'REJECT' => FirewallAction.deny,
      _ => null,
    };
    if (action == null) continue;

    var toText = actionMatch[1]!.trim();
    var fromText = actionMatch[4]!.trim();
    var isV6 = false;

    if (toText.contains('(v6)')) {
      isV6 = true;
      toText = toText.replaceAll('(v6)', '').trim();
    }
    if (fromText.contains('(v6)')) {
      isV6 = true;
      fromText = fromText.replaceAll('(v6)', '').trim();
    }
    if (toText.contains(' on ')) {
      toText = toText.split(' on ').first.trim();
    }
    if (fromText.contains(' on ')) {
      fromText = fromText.split(' on ').first.trim();
    }
    final portMatch = _ufwPortSpec.firstMatch(toText);
    if (portMatch == null) continue;
    final port = portMatch[1]!.replaceAll(':', '-');
    final protocol = switch (portMatch[2]) {
      'tcp' => FirewallProtocol.tcp,
      'udp' => FirewallProtocol.udp,
      _ => FirewallProtocol.tcpUdp,
    };
    final String source;
    final FirewallAddressFamily family;
    if (fromText == 'Anywhere') {
      source = isV6 ? '::/0' : '0.0.0.0/0';
      family = isV6 ? FirewallAddressFamily.ipv6 : FirewallAddressFamily.ipv4;
    } else {
      source = _clean(fromText);
      family = (isV6 || source.contains(':'))
          ? FirewallAddressFamily.ipv6
          : FirewallAddressFamily.ipv4;
    }

    rules.add(
      FirewallRule(
        id: 'ufw:$num:$port:${protocol.name}:$source',
        backend: FirewallBackend.ufw,
        action: action,
        protocol: protocol,
        port: port,
        source: source,
        family: family,
        comment: comment,
        rawRule: 'ufw:$num:$exactBody',
        usedProcesses: _matchListeners(protocol, port, listeners),
      ),
    );
  }
  return rules;
}

({List<FirewallRule> rules, String policy}) _parseNftables(
  List<String> lines,
  List<_Listener> listeners,
) {
  final rules = <FirewallRule>[];
  var inRuleset = false;
  var tableFamily = '';
  var tableName = '';
  var chainName = '';
  var inInputFilter = false;
  var detectedPolicy = '';

  for (final rawLine in lines) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed == 'NFT_RULESET') {
      inRuleset = true;
      continue;
    }
    if (!inRuleset) continue;

    final tableMatch = _nftTable.firstMatch(trimmed);
    if (tableMatch != null) {
      tableFamily = tableMatch[1]!;
      tableName = tableMatch[2]!;
      chainName = '';
      inInputFilter = false;
      continue;
    }
    final chainMatch = _nftChain.firstMatch(rawLine);
    if (chainMatch != null && tableName.isNotEmpty) {
      chainName = chainMatch[1]!;
      inInputFilter = false;
      continue;
    }
    if (trimmed == '}') {
      if (chainName.isNotEmpty) {
        chainName = '';
        inInputFilter = false;
      } else {
        tableFamily = '';
        tableName = '';
      }
      continue;
    }
    if (chainName.isNotEmpty && _nftInputHook.hasMatch(trimmed)) {
      inInputFilter = true;
      if (detectedPolicy.isEmpty) {
        final pol = _nftPolicy.firstMatch(trimmed)?[1];
        if (pol != null) detectedPolicy = pol.toUpperCase();
      }
      continue;
    }
    if (!inInputFilter || tableFamily.isEmpty) continue;

    final handleMatch = _nftHandle.firstMatch(trimmed);
    if (handleMatch == null) continue;
    final body = handleMatch[1]!.trim();
    final handle = handleMatch[2]!;

    final verdictMatch = _nftVerdict.firstMatch(body);
    if (verdictMatch == null) continue;
    final action = verdictMatch[1] == 'accept'
        ? FirewallAction.allow
        : FirewallAction.deny;

    FirewallProtocol? protocol;
    String? rawPort;
    final dualMatch = _nftDualProtoPort.firstMatch(body);
    if (dualMatch != null) {
      protocol = FirewallProtocol.tcpUdp;
      rawPort = dualMatch[1]!;
    } else {
      final protoMatch = _nftProtoPort.firstMatch(body);
      if (protoMatch == null) continue;
      protocol = protoMatch[1] == 'tcp'
          ? FirewallProtocol.tcp
          : FirewallProtocol.udp;
      rawPort = protoMatch[2]!;
    }
    final normalizedPort = _normalizeNftPort(rawPort);
    if (normalizedPort == null) continue;

    String source;
    FirewallAddressFamily family;
    final s4 = _nftSource4.firstMatch(body);
    final s6 = _nftSource6.firstMatch(body);
    if (s4 != null) {
      source = _normalizeNftSet(s4[1]!);
      family = FirewallAddressFamily.ipv4;
    } else if (s6 != null) {
      source = _normalizeNftSet(s6[1]!);
      family = FirewallAddressFamily.ipv6;
    } else if (tableFamily == 'ip') {
      source = '0.0.0.0/0';
      family = FirewallAddressFamily.ipv4;
    } else if (tableFamily == 'ip6') {
      source = '::/0';
      family = FirewallAddressFamily.ipv6;
    } else {
      source = '0.0.0.0/0, ::/0';
      family = FirewallAddressFamily.any;
    }

    final comment = _clean(_nftComment.firstMatch(body)?[1] ?? '');

    rules.add(
      FirewallRule(
        id: 'nft:$tableFamily:$tableName:$chainName:$handle',
        backend: FirewallBackend.nftables,
        action: action,
        protocol: protocol,
        port: normalizedPort,
        source: source,
        family: family,
        comment: comment,
        chain: '$tableFamily/$tableName/$chainName',
        rawRule: 'nft:$tableFamily|$tableName|$chainName|$handle',
        usedProcesses: _matchListeners(protocol, normalizedPort, listeners),
      ),
    );
  }
  return (rules: rules, policy: detectedPolicy);
}

String? _normalizeNftPort(String raw) {
  final stripped = raw.trim();
  if (stripped.startsWith('{') && stripped.endsWith('}')) {
    final inner = stripped.substring(1, stripped.length - 1).trim();
    final parts = <String>[];
    for (final token in inner.split(',')) {
      final resolved = _resolveSingleNftPort(token.trim());
      if (resolved == null) return null;
      parts.add(resolved);
    }
    return parts.isEmpty ? null : parts.join(',');
  }
  return _resolveSingleNftPort(stripped);
}

String? _resolveSingleNftPort(String token) {
  if (token.isEmpty) return null;
  final mapped = _wellKnownPorts[token.toLowerCase()] ?? token;
  return FirewallRuleInput.normalizeSinglePort(mapped);
}

String _normalizeNftSet(String raw) {
  final stripped = raw.trim();
  if (stripped.startsWith('{') && stripped.endsWith('}')) {
    return stripped
        .substring(1, stripped.length - 1)
        .split(',')
        .map((s) => _clean(s))
        .where((s) => s.isNotEmpty)
        .join(', ');
  }
  return _clean(stripped);
}

List<FirewallRule> _parseIptables(
  List<String> lines,
  List<_Listener> listeners,
) {
  final rules = <FirewallRule>[];
  var isV6 = false;
  var inSection = false;
  var lineNum = 0;

  for (final rawLine in lines) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) continue;
    if (line == 'IPTABLES_V4') {
      isV6 = false;
      inSection = true;
      lineNum = 0;
      continue;
    }
    if (line == 'IPTABLES_V6') {
      isV6 = true;
      inSection = true;
      lineNum = 0;
      continue;
    }
    if (!inSection || !line.startsWith('-A INPUT ')) continue;
    lineNum++;

    final tokens = _tokenizeArgs(line);
    FirewallProtocol? protocol;
    String? port;
    String? source;
    FirewallAction? action;
    var comment = '';

    for (var i = 2; i < tokens.length; i++) {
      final token = tokens[i];
      if (token == '!') continue;
      switch (token) {
        case '-p':
          if (i + 1 < tokens.length) {
            final value = tokens[++i].toLowerCase();
            if (value == 'tcp') {
              protocol = FirewallProtocol.tcp;
            } else if (value == 'udp') {
              protocol = FirewallProtocol.udp;
            }
          }
        case '--dport' || '--dports':
          if (i + 1 < tokens.length) {
            port = tokens[++i].replaceAll(':', '-');
          }
        case '-s':
          if (i + 1 < tokens.length) {
            source = _normalizeIptablesSource(tokens[++i], isV6: isV6);
          }
        case '--comment':
          if (i + 1 < tokens.length) {
            comment = _clean(tokens[++i]);
          }
        case '-j':
          if (i + 1 < tokens.length) {
            final target = tokens[++i];
            if (target == 'ACCEPT') {
              action = FirewallAction.allow;
            } else if (target == 'DROP' || target == 'REJECT') {
              action = FirewallAction.deny;
            }
          }
        case '-m' ||
            '--reject-with' ||
            '-i' ||
            '-o' ||
            '-d' ||
            '--sport' ||
            '--sports':
          if (i + 1 < tokens.length) i++;
      }
    }

    if (protocol == null || port == null || action == null) continue;
    final resolvedSource = source ?? (isV6 ? '::/0' : '0.0.0.0/0');
    final family = isV6
        ? FirewallAddressFamily.ipv6
        : FirewallAddressFamily.ipv4;
    final ver = isV6 ? 'v6' : 'v4';

    rules.add(
      FirewallRule(
        id: 'iptables:$ver:$lineNum:$port:${protocol.name}:$resolvedSource',
        backend: FirewallBackend.iptables,
        action: action,
        protocol: protocol,
        port: port,
        source: resolvedSource,
        family: family,
        comment: comment,
        chain: isV6 ? 'INPUT (IPv6)' : 'INPUT (IPv4)',
        rawRule: 'iptables:$ver:$lineNum:$line',
        usedProcesses: _matchListeners(protocol, port, listeners),
      ),
    );
  }
  return rules;
}

String _normalizeIptablesSource(String raw, {required bool isV6}) {
  final cleaned = _clean(raw);
  if (!isV6 && cleaned.endsWith('/32')) {
    return cleaned.substring(0, cleaned.length - 3);
  }
  if (isV6 && cleaned.endsWith('/128')) {
    return cleaned.substring(0, cleaned.length - 4);
  }
  return cleaned;
}

List<String> _tokenizeArgs(String line) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  var escaping = false;
  var hasToken = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (escaping) {
      buffer.write(ch);
      escaping = false;
      hasToken = true;
      continue;
    }
    if (ch == r'\' && inQuotes) {
      escaping = true;
      continue;
    }
    if (ch == '"') {
      inQuotes = !inQuotes;
      hasToken = true;
      continue;
    }
    if (!inQuotes && (ch == ' ' || ch == '\t')) {
      if (hasToken) {
        tokens.add(buffer.toString());
        buffer.clear();
        hasToken = false;
      }
      continue;
    }
    buffer.write(ch);
    hasToken = true;
  }
  if (hasToken) tokens.add(buffer.toString());
  return tokens;
}

FirewallBackend _parseBackend(String value) =>
    _tryParseBackend(value) ?? _invalid();

FirewallBackend? _tryParseBackend(String value) => switch (value) {
  'firewalld' => FirewallBackend.firewalld,
  'ufw' => FirewallBackend.ufw,
  'nftables' => FirewallBackend.nftables,
  'iptables' => FirewallBackend.iptables,
  _ => null,
};

String _clean(String value) => value.replaceAll(_controls, '').trim();
Never _invalid() => throw const FormatException('Invalid firewall snapshot');
