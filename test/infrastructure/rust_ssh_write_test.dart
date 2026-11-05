import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/rust_ssh_engine.dart';
import 'package:pagashell/src/rust/api/ssh.dart';
import 'package:pagashell/src/rust/frb_generated.dart';

class _SshApi extends RustLibApi {
  final writes = <String>[];
  final gates = <Completer<void>>[];

  @override
  Future<SshHandshake> crateApiSshSshHandshake({
    required String host,
    required int port,
  }) async =>
      const SshHandshake(sessionId: 1, keyType: 'ed25519', fingerprint: 'fp');

  @override
  Future<int> crateApiSshSshAuthenticate({
    required int sessionId,
    required String expectedFingerprint,
    required String username,
    required String password,
  }) async => sessionId;

  @override
  Future<void> crateApiSshSshWrite({
    required int sessionId,
    required List<int> data,
  }) {
    writes.add(utf8.decode(data));
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<void> crateApiSshSshDisconnect({required int sessionId}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late _SshApi api;
  setUp(() {
    api = _SshApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  test('终端输入同时只有一次写入在途，期间输入按序合并', () async {
    final session = await const RustSshEngine().connect(
      const Host(id: 'h', name: 'h', hostname: 'h.test', username: 'root'),
      const SshCredentials.password('test-only'),
      verifyHostKey: (_) async => true,
    );

    session.write('l');
    session.write('s');
    session.write(' -la');
    session.write('\r');
    await Future<void>.delayed(Duration.zero);
    expect(api.writes, ['l']);

    api.gates.single.complete();
    await Future<void>.delayed(Duration.zero);
    expect(api.writes, ['l', 's -la\r']);

    // 写入失败不影响后续输入。
    api.gates.last.completeError(StateError('busy'));
    session.write('x');
    await Future<void>.delayed(Duration.zero);
    expect(api.writes, ['l', 's -la\r', 'x']);
    api.gates.last.complete();
    await session.close();
  });
}
