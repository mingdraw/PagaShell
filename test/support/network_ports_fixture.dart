import 'package:pagashell/domain/ssh/network_ports.dart';

NetworkPortsSnapshot networkPortsFixture({bool limited = false}) =>
    NetworkPortsSnapshot(
      limited: limited,
      ports: const [
        ListeningNetworkPort(
          protocol: NetworkPortProtocol.tcp,
          port: 22,
          addresses: [
            NetworkPortAddress(address: '0.0.0.0', ipv6: false),
            NetworkPortAddress(address: '::', ipv6: true),
          ],
          processes: [NetworkPortProcess(pid: 7, name: 'sshd')],
        ),
        ListeningNetworkPort(
          protocol: NetworkPortProtocol.udp,
          port: 53,
          addresses: [
            NetworkPortAddress(address: '127.0.0.53%lo', ipv6: false),
          ],
          processes: [NetworkPortProcess(pid: 80, name: 'dns server')],
        ),
        ListeningNetworkPort(
          protocol: NetworkPortProtocol.tcp,
          port: 8080,
          addresses: [NetworkPortAddress(address: '::1', ipv6: true)],
          processes: [NetworkPortProcess(pid: 42, name: 'Web API')],
        ),
      ],
    );
