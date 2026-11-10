import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException, ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/infrastructure/ssh/network_ports_parser.dart';
import 'package:pagashell/src/rust/api/network_ports.dart' as native;
import 'package:pagashell/src/rust/frb_generated.dart';

const _nativeLibrary = String.fromEnvironment('PAGASHELL_NATIVE_LIBRARY');
const _localPorts = bool.fromEnvironment('PAGASHELL_LOCAL_PORTS_TEST');

void main() {
  test(
    '真实原生端口桥接返回明确的关闭原因',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_nativeLibrary));
      addTearDown(RustLib.dispose);
      await expectLater(
        native.sshReadNetworkPorts(sessionId: 0),
        throwsA(
          isA<AnyhowException>().having(
            (error) => error.message,
            'message',
            '网络端口连接已关闭',
          ),
        ),
      );
    },
    skip: _nativeLibrary.isEmpty ? '通过 PAGASHELL_NATIVE_LIBRARY 指定原生库' : false,
  );

  test(
    'macOS 真实 lsof 输出完整解析为自有 TCP/UDP 和双栈端口及进程',
    () async {
      final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final ipv6 = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
      addTearDown(() async {
        await tcp.close();
        udp.close();
        await ipv6.close();
      });
      final temp = await Directory.systemTemp.createTemp('paga-local-ports-');
      addTearDown(() => temp.delete(recursive: true));
      // Make the production script collect only current-user data in this local test.
      final id = File('${temp.path}/id');
      await id.writeAsString("#!/bin/sh\nprintf '0\\n'\n");
      await Process.run('/bin/chmod', ['+x', id.path]);
      final output = await Process.run(
        '/bin/sh',
        ['-c', await File('rust/src/api/network_ports.sh').readAsString()],
        environment: {'PATH': '${temp.path}:/usr/bin:/bin:/usr/sbin'},
      ).timeout(const Duration(seconds: 10));
      expect(output.exitCode, 0);
      const capture = String.fromEnvironment('PAGASHELL_PORTS_CAPTURE');
      if (capture.isNotEmpty) {
        await File(capture).writeAsString(output.stdout as String);
      }
      final result = parseNetworkPorts(output.stdout as String);
      for (final (number, protocol, host, v6) in [
        (tcp.port, NetworkPortProtocol.tcp, '127.0.0.1', false),
        (udp.port, NetworkPortProtocol.udp, '127.0.0.1', false),
        (ipv6.port, NetworkPortProtocol.tcp, '::1', true),
      ]) {
        final found = result.ports.where(
          (p) =>
              p.port == number &&
              p.protocol == protocol &&
              p.processes.any((process) => process.pid == pid),
        );
        expect(found, isNotEmpty);
        expect(
          found.any(
            (p) => p.addresses.any((a) => a.address == host && a.ipv6 == v6),
          ),
          isTrue,
        );
        expect(found.first.processes.first.name, isNotEmpty);
      }
    },
    skip: !_localPorts || !Platform.isMacOS
        ? '显式设置 PAGASHELL_LOCAL_PORTS_TEST 验证本机采集'
        : false,
  );
}
