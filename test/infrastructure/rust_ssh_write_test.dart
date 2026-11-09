import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/terminal/terminal_frame.dart';
import 'package:pagashell/infrastructure/ssh/rust_ssh_engine.dart';
import 'package:pagashell/src/rust/api/ssh.dart';
import 'package:pagashell/src/rust/api/terminal.dart' as native;
import 'package:pagashell/src/rust/frb_generated.dart';

class _SshApi extends RustLibApi {
  final writes = <String>[];
  final gates = <Completer<void>>[];
  final dockerFrames = StreamController<native.TerminalFrame>();
  final dockerStarts = <(int, String, int, int)>[];

  void dispose() {
    unawaited(dockerFrames.close());
  }

  @override
  Stream<native.TerminalFrame> crateApiSshSshStartDockerTerminal({
    required int sessionId,
    required String containerId,
    required int cols,
    required int rows,
    required int scrollback,
  }) {
    dockerStarts.add((sessionId, containerId, cols, rows));
    return dockerFrames.stream;
  }

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
  tearDown(() {
    api.dispose();
    RustLib.dispose();
  });

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

  test('容器预检期间保留输入，收到首帧后按序合并发送', () async {
    final session = await const RustSshEngine().connect(
      const Host(id: 'h', name: 'h', hostname: 'h.test'),
      const SshCredentials.password('test-only'),
      verifyHostKey: (_) async => true,
    );
    final frames = <TerminalFrame>[];
    final subscription = (session as DockerTerminalSource)
        .startDockerTerminalShell(
          target: const DockerTerminalTarget(
            id: 'aabbccddeeff',
            name: 'web-api',
          ),
          cols: 100,
          rows: 30,
        )
        .listen(frames.add);
    session.write('echo ');
    session.write('中文\r\x03');
    await Future<void>.delayed(Duration.zero);
    expect(api.dockerStarts, [(1, 'aabbccddeeff', 100, 30)]);
    expect(api.writes, isEmpty);
    api.dockerFrames.add(
      native.TerminalFrame(
        frameId: 1,
        columns: 100,
        rows: 30,
        alternate: false,
        cursorX: 0,
        cursorY: 0,
        modes: 0,
        cursorBlink: false,
        trimFront: 0,
        keepRows: 0,
        appendRows: Uint32List(0),
        lines: const [],
        bell: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(frames.single.frameId, 1);
    expect(api.writes, ['echo 中文\r\x03']);
    session.write('ls\r');
    expect(api.writes, hasLength(1));
    api.gates.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(api.writes, ['echo 中文\r\x03', 'ls\r']);
    api.gates.last.complete();
    await subscription.cancel();
    await api.dockerFrames.close();
    await session.close();
  });

  test('容器预检失败不发送等待中的输入', () async {
    final session = await const RustSshEngine().connect(
      const Host(id: 'h', name: 'h', hostname: 'h.test'),
      const SshCredentials.password('test-only'),
      verifyHostKey: (_) async => true,
    );
    final errors = <Object>[];
    final subscription = (session as DockerTerminalSource)
        .startDockerTerminalShell(
          target: const DockerTerminalTarget(
            id: 'aabbccddeeff',
            name: 'web-api',
          ),
          cols: 80,
          rows: 24,
        )
        .listen(
          (_) => fail('preflight must not emit a frame'),
          onError: errors.add,
        );
    session.write('pending command\r');
    api.dockerFrames.addError(
      AnyhowException('容器中未找到可用的 bash 或 sh\n/private/native/diagnostic'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    expect(
      errors.single,
      isA<SshEngineException>().having(
        (error) => error.message,
        'message',
        '容器中未找到可用的 bash 或 sh',
      ),
    );
    expect(api.writes, isEmpty);
    await subscription.cancel();
    await api.dockerFrames.close();
    await session.close();
  });
}
