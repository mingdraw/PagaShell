const networkPortsQueryTimeout = Duration(seconds: 10);

/// 只读端口采集，通过后台 SSH 的独立无 PTY 通道执行。
abstract interface class NetworkPortsSource {
  Future<NetworkPortsSnapshot> readNetworkPorts();
}

enum NetworkPortProtocol { tcp, udp }

class NetworkPortAddress {
  const NetworkPortAddress({required this.address, required this.ipv6});
  final String address;
  final bool ipv6;
  String endpoint(int port) => ipv6 ? '[$address]:$port' : '$address:$port';
}

class NetworkPortProcess {
  const NetworkPortProcess({required this.pid, required this.name});
  final int pid;
  final String name;
}

/// 同一协议、端口和进程集合的 IPv4/IPv6 绑定合并展示。
class ListeningNetworkPort {
  const ListeningNetworkPort({
    required this.protocol,
    required this.port,
    required this.addresses,
    required this.processes,
  });
  final NetworkPortProtocol protocol;
  final int port;
  final List<NetworkPortAddress> addresses;
  final List<NetworkPortProcess> processes;

  String get identity =>
      '${protocol.name}:$port:${processes.map((p) => '${p.pid}:${p.name}').join(',')}';
  bool matches(String term) =>
      term.isEmpty ||
      '$port'.contains(term) ||
      processes.any((p) => p.name.toLowerCase().contains(term));
}

class NetworkPortsSnapshot {
  const NetworkPortsSnapshot({required this.ports, this.limited = false});
  final List<ListeningNetworkPort> ports;

  /// 非 root 且无法使用无密码 sudo 时，进程关联和 macOS 列表可能不完整。
  final bool limited;
}
