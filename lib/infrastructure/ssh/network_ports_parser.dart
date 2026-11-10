import 'dart:convert';

import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/ssh_engine.dart';

final _ssRow = RegExp(
  r'^(tcp|udp)\s+(\S+)\s+\d+\s+\d+\s+(\S+)\s+\S+(?:\s+(.*))?$',
);
final _ssProcess = RegExp(r'\("((?:\\.|[^"\\])*)",pid=(\d+),');
final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]');
final _ipv6 = RegExp(r'^[0-9a-fA-F:.]+(?:%[a-zA-Z0-9_.:-]+)?$');
final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}(?:%[a-zA-Z0-9_.:-]+)?$');

NetworkPortsSnapshot parseNetworkPorts(String raw) {
  try {
    final lines = const LineSplitter().convert(raw);
    if (lines.length < 3 ||
        lines.first != 'PAGA_NETWORK_PORTS_V1' ||
        lines.last != 'END_PORTS') {
      _invalid();
    }
    final limited = switch (lines[1]) {
      'ACCESS FULL' => false,
      'ACCESS LIMITED' => true,
      _ => _invalid(),
    };
    final bindings = <_Binding>[];
    var format = '';
    final lsof = <String>[];
    for (final line in lines.skip(2).take(lines.length - 3)) {
      if (const {'SS4', 'SS6', 'LSOF'}.contains(line)) {
        format = line;
      } else if (format == 'LSOF') {
        lsof.add(line);
      } else if (line.trim().isNotEmpty) {
        if (format != 'SS4' && format != 'SS6') _invalid();
        final match = _ssRow.firstMatch(line.trim());
        if (match == null) _invalid();
        final tcp = match[1] == 'tcp';
        if (match[2] != (tcp ? 'LISTEN' : 'UNCONN')) continue;
        if (match[3]!.endsWith(':*') || match[3]!.endsWith(':0')) continue;
        final processes = <int, NetworkPortProcess>{};
        for (final p in _ssProcess.allMatches(match[4] ?? '')) {
          final pid = int.parse(p[2]!);
          if (pid <= 0) _invalid();
          String name;
          try {
            name = jsonDecode('"${p[1]}"') as String;
          } on Object {
            name = p[1]!.replaceAll(r'\', '');
          }
          processes[pid] = NetworkPortProcess(pid: pid, name: _text(name));
        }
        bindings.add(
          _binding(
            tcp ? NetworkPortProtocol.tcp : NetworkPortProtocol.udp,
            match[3]!,
            format == 'SS6',
            processes.values.toList(),
          ),
        );
      }
    }
    if (format.isEmpty) _invalid();
    if (lsof.isNotEmpty) bindings.addAll(_parseLsof(lsof));
    final groups = <String, List<_Binding>>{};
    for (final binding in bindings) {
      binding.processes.sort((a, b) => a.pid.compareTo(b.pid));
      final key =
          '${binding.protocol.name}:${binding.port}:${binding.processes.map((p) => '${p.pid}:${p.name}').join(',')}';
      (groups[key] ??= []).add(binding);
    }
    final result = <ListeningNetworkPort>[];
    for (final group in groups.values) {
      final first = group.first;
      final addresses = <String, NetworkPortAddress>{};
      for (final row in group) {
        addresses['${row.address.ipv6}:${row.address.address}'] = row.address;
      }
      final ordered = addresses.values.toList()
        ..sort(
          (a, b) => a.ipv6 == b.ipv6
              ? a.address.compareTo(b.address)
              : a.ipv6
              ? 1
              : -1,
        );
      result.add(
        ListeningNetworkPort(
          protocol: first.protocol,
          port: first.port,
          addresses: List.unmodifiable(ordered),
          processes: List.unmodifiable(first.processes),
        ),
      );
    }
    result.sort(
      (a, b) => a.port == b.port
          ? a.identity.compareTo(b.identity)
          : a.port.compareTo(b.port),
    );
    return NetworkPortsSnapshot(
      ports: List.unmodifiable(result),
      limited: limited,
    );
  } on Object {
    throw const SshEngineException('网络端口数据格式无效，请重试');
  }
}

class _Binding {
  _Binding(this.protocol, this.port, this.address, this.processes);
  final NetworkPortProtocol protocol;
  final int port;
  final NetworkPortAddress address;
  final List<NetworkPortProcess> processes;
}

_Binding _binding(
  NetworkPortProtocol protocol,
  String endpoint,
  bool ipv6,
  List<NetworkPortProcess> processes,
) {
  final split = endpoint.lastIndexOf(':');
  if (split <= 0) _invalid();
  final port = int.tryParse(endpoint.substring(split + 1));
  if (port == null || port < 1 || port > 65535) _invalid();
  var host = endpoint.substring(0, split);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host == '*') host = ipv6 ? '::' : '0.0.0.0';
  // lsof can report an IPv6 socket's mapped address as a plain IPv4 literal.
  if (ipv6 && _ipv4.hasMatch(host)) ipv6 = false;
  if (ipv6) {
    if (!host.contains(':') || !_ipv6.hasMatch(host)) _invalid();
  } else {
    final octets = host.split('%').first.split('.');
    if (!_ipv4.hasMatch(host) || octets.any((v) => int.parse(v) > 255)) {
      _invalid();
    }
  }
  return _Binding(
    protocol,
    port,
    NetworkPortAddress(address: host, ipv6: ipv6),
    processes,
  );
}

List<_Binding> _parseLsof(List<String> lines) {
  final result = <_Binding>[];
  int? pid;
  var name = '';
  var file = <String, String>{};
  void flush() {
    if (file.isEmpty) return;
    final protocol = file['P'];
    final endpoint = file['n'];
    final family = file['t'];
    if (endpoint == null ||
        (family != 'IPv4' && family != 'IPv6') ||
        pid == null) {
      _invalid();
    }
    if (((protocol == 'TCP' && file['T'] == 'ST=LISTEN') ||
            (protocol == 'UDP' && !endpoint.contains('->'))) &&
        !endpoint.endsWith(':*') &&
        !endpoint.endsWith(':0')) {
      result.add(
        _binding(
          protocol == 'TCP' ? NetworkPortProtocol.tcp : NetworkPortProtocol.udp,
          endpoint,
          family == 'IPv6',
          [NetworkPortProcess(pid: pid, name: name)],
        ),
      );
    }
    file = {};
  }

  for (final line in lines) {
    if (line.isEmpty) continue;
    final field = line[0];
    final value = line.substring(1);
    if (field == 'p') {
      flush();
      pid = int.tryParse(value);
      if (pid == null || pid <= 0) _invalid();
      name = '';
    } else if (field == 'c') {
      name = _text(value);
    } else if (field == 'f') {
      flush();
      file['f'] = value;
    } else if (const {'t', 'P', 'n', 'T'}.contains(field)) {
      if (field != 'T' || value.startsWith('ST=')) file[field] = value;
    } else {
      _invalid();
    }
  }
  flush();
  return result;
}

String _text(String value) => value.replaceAll(_controls, '').trim();
Never _invalid() => throw const FormatException('Invalid network ports');
