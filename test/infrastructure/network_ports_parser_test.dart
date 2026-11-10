import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/network_ports_parser.dart';

void main() {
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
