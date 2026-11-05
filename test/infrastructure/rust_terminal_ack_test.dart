import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/terminal/terminal_frame.dart';
import 'package:pagashell/infrastructure/ssh/rust_ssh_engine.dart';
import 'package:pagashell/src/rust/api/ssh.dart';
import 'package:pagashell/src/rust/api/terminal.dart' as native;
import 'package:pagashell/src/rust/frb_generated.dart';

class _TerminalApi extends RustLibApi {
  final frames = StreamController<native.TerminalFrame>();
  final acknowledgements = <(int, int)>[];
  final starts = <(int, int, int, int)>[];
  final disconnected = <int>[];

  Future<void> dispose() => frames.close();

  @override
  Future<SshHandshake> crateApiSshSshHandshake({
    required String host,
    required int port,
  }) async =>
      const SshHandshake(sessionId: 37, keyType: 'ed25519', fingerprint: 'fp');

  @override
  Future<int> crateApiSshSshAuthenticate({
    required int sessionId,
    required String expectedFingerprint,
    required String username,
    required String password,
  }) async => sessionId;

  @override
  Stream<native.TerminalFrame> crateApiSshSshStartTerminal({
    required int sessionId,
    required int cols,
    required int rows,
    required int scrollback,
  }) {
    starts.add((sessionId, cols, rows, scrollback));
    return frames.stream;
  }

  @override
  Future<void> crateApiSshSshTerminalAck({
    required int sessionId,
    required int frameId,
  }) async {
    acknowledgements.add((sessionId, frameId));
  }

  @override
  Future<void> crateApiSshSshDisconnect({required int sessionId}) async {
    disconnected.add(sessionId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late _TerminalApi api;
  setUp(() {
    api = _TerminalApi();
    RustLib.initMock(api: api);
  });
  tearDown(() async {
    await api.dispose();
    RustLib.dispose();
  });

  test('帧序号跨桥保留，由消费者应用后显式确认；关闭后忽略迟到确认', () async {
    final session = await const RustSshEngine().connect(
      const Host(id: 'h', name: 'h', hostname: 'h.test', username: 'test'),
      const SshCredentials.password('test-only'),
      verifyHostKey: (_) async => true,
    );
    final source = session as TerminalScreenSource;
    final received = <TerminalFrame>[];
    final subscription = source
        .startTerminalShell(cols: 2, rows: 1, scrollback: 100)
        .listen(received.add);
    addTearDown(subscription.cancel);
    api.frames.add(
      native.TerminalFrame(
        frameId: 42,
        columns: 2,
        rows: 1,
        alternate: false,
        cursorX: 1,
        cursorY: 0,
        modes: 17,
        cursorBlink: true,
        trimFront: 0,
        keepRows: 0,
        appendRows: Uint32List.fromList([9]),
        lines: [
          native.TerminalLine(
            id: 9,
            wrapped: false,
            cells: Uint32List.fromList([0, 0, 0, 97 | (1 << 22), 0, 0, 0, 0]),
            clusters: const [
              native.TerminalCluster(column: 0, text: 'a\u0301'),
            ],
          ),
        ],
        title: 'test',
        bell: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(api.starts, [(37, 2, 1, 100)]);
    expect(received.single.frameId, 42);
    expect(received.single.cursorX, 1);
    expect(received.single.modes, 17);
    expect(received.single.lines.single.clusters, {0: 'a\u0301'});
    expect(api.acknowledgements, isEmpty);
    await source.acknowledgeTerminalFrame(received.single.frameId);
    expect(api.acknowledgements, [(37, 42)]);

    await subscription.cancel();
    await session.close();
    await source.acknowledgeTerminalFrame(43);
    expect(api.disconnected, [37]);
    expect(api.acknowledgements, [(37, 42)]);
  });
}
