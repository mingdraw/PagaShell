import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/network_ports_parser.dart';

void main() {
  test('Rocky Linux 9.8 ss 6.17 网卡标识位于 IPv6 方括号外时完整解析全部端口', () {
    final sample = parseNetworkPorts(r'''PAGA_NETWORK_PORTS_V1
ACCESS FULL
SS4
udp UNCONN 0 0 127.0.0.1:323 0.0.0.0:* users:(("chronyd",pid=856,fd=5))
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=916,fd=7))
tcp LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=59043,fd=6),("nginx",pid=59042,fd=6),("nginx",pid=59041,fd=6),("nginx",pid=59040,fd=6),("nginx",pid=59039,fd=6),("nginx",pid=59038,fd=6),("nginx",pid=59037,fd=6),("nginx",pid=59036,fd=6),("nginx",pid=25415,fd=6))
tcp LISTEN 0 1024 0.0.0.0:9100 0.0.0.0:* users:(("supervisord",pid=2681281,fd=4))
tcp LISTEN 0 4096 127.0.0.1:7001 0.0.0.0:* users:(("minio",pid=2681284,fd=10))
tcp LISTEN 0 511 0.0.0.0:6379 0.0.0.0:* users:(("redis-server",pid=2681286,fd=6))
tcp LISTEN 0 4096 0.0.0.0:7010 0.0.0.0:* users:(("minio",pid=2681284,fd=12))
SS6
udp UNCONN 0 0 *:56441 *:* users:(("java",pid=1950259,fd=57))
udp UNCONN 0 0 [::1]:323 [::]:* users:(("chronyd",pid=856,fd=6))
udp UNCONN 0 0 [fe80::1234:5678:9abc:def0]%ens18:546 [::]:* users:(("NetworkManager",pid=903,fd=29))
tcp LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=916,fd=8))
tcp LISTEN 0 1024 *:3306 *:* users:(("mysqld",pid=16522,fd=24))
tcp LISTEN 0 4096 [::1]:7001 [::]:* users:(("minio",pid=2681284,fd=11))
tcp LISTEN 0 4096 *:7001 *:* users:(("minio",pid=2681284,fd=9))
tcp LISTEN 0 4096 *:7000 *:* users:(("java",pid=1950259,fd=50))
END_PORTS
''');
    expect(sample.ports, hasLength(11));
    final dhcp = sample.ports.singleWhere((port) => port.port == 546);
    expect(dhcp.protocol, NetworkPortProtocol.udp);
    expect(dhcp.addresses.single.ipv6, isTrue);
    expect(dhcp.addresses.single.address, 'fe80::1234:5678:9abc:def0%ens18');
    expect(
      dhcp.addresses.single.endpoint(546),
      '[fe80::1234:5678:9abc:def0%ens18]:546',
    );
    expect(dhcp.processes.single.name, 'NetworkManager');
    expect(dhcp.processes.single.pid, 903);
    expect(
      sample.ports.singleWhere((port) => port.port == 80).processes,
      hasLength(9),
    );
    expect(
      sample.ports.singleWhere((port) => port.port == 7001).addresses,
      hasLength(3),
    );
    expect(
      sample.ports.singleWhere((port) => port.port == 22).addresses,
      hasLength(2),
    );
  });

  for (final host in [
    '[fe80::1]%ens18',
    '[fe80::1%ens18]',
    'fe80::1%ens18',
    '[fe80::1]%2',
  ]) {
    test('IPv6 区域标识兼容 $host', () {
      final sample = parseNetworkPorts(
        'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS6\nudp UNCONN 0 0 $host:546 [::]:*\nEND_PORTS\n',
      );
      final address = sample.ports.single.addresses.single;
      expect(address.ipv6, isTrue);
      expect(
        address.address,
        host.endsWith('%2') ? 'fe80::1%2' : 'fe80::1%ens18',
      );
      expect(sample.ports.single.port, 546);
    });
  }

  test('IPv6 区域标识的括号或后缀损坏时仍报错', () {
    for (final host in [
      '[fe80::1]ens18',
      '[fe80::1]%',
      '[fe80::1%ens18]%eth0',
      '[fe80::1',
    ]) {
      expect(
        () => parseNetworkPorts(
          'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS6\nudp UNCONN 0 0 $host:546 [::]:*\nEND_PORTS\n',
        ),
        throwsA(isA<SshEngineException>()),
      );
    }
  });

  test('Linux 双栈按端口和进程集合合并，保留作用域和多个进程，排除已连接 UDP', () {
    final sample = parseNetworkPorts(r'''PAGA_NETWORK_PORTS_V1
ACCESS FULL
SS4
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=7,fd=3))
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("dns server",pid=80,fd=3))
tcp LISTEN 0 128 127.0.0.1:443 0.0.0.0:* users:(("nginx",pid=8,fd=3),("nginx",pid=9,fd=3))
udp ESTAB 0 0 127.0.0.1:3000 127.0.0.1:9000 users:(("client",pid=123,fd=3))
SS6
tcp LISTEN 0 128 *:22 *:* users:(("sshd",pid=7,fd=4))
tcp LISTEN 0 128 [fe80::1%en0]:8080 [::]:*
END_PORTS
''');
    expect(sample.ports.map((p) => p.port), [22, 53, 443, 8080]);
    expect(sample.ports.first.addresses.map((a) => a.endpoint(22)), [
      '0.0.0.0:22',
      '[::]:22',
    ]);
    expect(sample.ports[1].protocol, NetworkPortProtocol.udp);
    expect(sample.ports[1].addresses.single.address, '127.0.0.53%lo');
    expect(sample.ports[2].processes.map((p) => p.pid), [8, 9]);
    expect(sample.ports.last.processes, isEmpty);
    expect(
      sample.ports.last.addresses.single.endpoint(8080),
      '[fe80::1%en0]:8080',
    );
  });

  test('macOS lsof 字段保留空格进程名，合并重复 fd 与双栈，过滤非监听 TCP 和未绑定/连接 UDP', () {
    final result = parseNetworkPorts('''PAGA_NETWORK_PORTS_V1
ACCESS LIMITED
LSOF
p42
cExample App
f3
tIPv4
PTCP
n*:8080
TST=LISTEN
f4
tIPv6
PTCP
n*:8080
TST=LISTEN
TQR=0
f5
tIPv6
PTCP
n[::1]:8080->[::1]:9000
TST=ESTABLISHED
f6
tIPv6
PTCP
n127.0.0.1:8080
TST=LISTEN
p50
cDNS
f3
tIPv4
PUDP
n*:53
f4
tIPv4
PUDP
n127.0.0.1:1234->127.0.0.1:9000
f5
tIPv4
PUDP
n*:0
END_PORTS
''');
    expect(result.limited, true);
    expect(result.ports.map((p) => p.port), [53, 8080]);
    expect(result.ports.last.processes.single.name, 'Example App');
    expect(result.ports.last.addresses, hasLength(3));
    expect(
      result.ports.last.addresses.any(
        (a) => a.address == '127.0.0.1' && !a.ipv6,
      ),
      true,
    );
  });

  test('空列表合法，损坏或不完整数据明确报错，不伪装为空列表', () {
    expect(
      parseNetworkPorts(
        'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS4\nSS6\nEND_PORTS\n',
      ).ports,
      isEmpty,
    );
    expect(
      parseNetworkPorts(
        'PAGA_NETWORK_PORTS_V1\nACCESS LIMITED\nLSOF\nEND_PORTS\n',
      ).ports,
      isEmpty,
    );
    for (final raw in [
      '',
      'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS4\n',
      'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS4\ntcp broken\nEND_PORTS\n',
      'PAGA_NETWORK_PORTS_V1\nACCESS FULL\nSS4\ntcp LISTEN 0 0 0.0.0.0:70000 *:*\nEND_PORTS\n',
    ]) {
      expect(() => parseNetworkPorts(raw), throwsA(isA<SshEngineException>()));
    }
  });
}
