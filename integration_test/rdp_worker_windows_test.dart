import 'dart:ffi';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/src/rust/api/desktop.dart' as rdp;
import 'package:pagashell/src/rust/api/vnc.dart' as vnc;
import 'package:pagashell/src/rust/frb_generated.dart';

const _deadline = Duration(seconds: 10);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) return;
  setUpAll(RustLib.init);

  test('关闭没有应答的 RDP 进程不会结束另一会话进程', () async {
    final stalled = await _openWorker();
    final healthy = await _openWorker();
    expect(stalled.info.processId, isNot(healthy.info.processId));
    expect(stalled.info.processId, isNot(pid));

    final listener = await _listen();
    final connection = listener.first;
    final blocked = expectLater(
      _handshake(stalled, listener),
      throwsA(_nativeError('RDP 会话进程无响应')),
    );
    final heldPeer = await connection.timeout(_deadline);
    addTearDown(heldPeer.destroy);

    // The server accepts TCP but never replies to negotiation. The selected
    // child cannot handle Close while waiting for this first handshake.
    final elapsed = Stopwatch()..start();
    await rdp.desktopDisconnect(sessionId: stalled.info.sessionId);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 4)));
    await blocked;
    await stalled.waitForExit();
    expect(healthy.exited, isFalse);

    // Prove the sibling can still handle its own request and return a genuine
    // RDP negotiation error from TCP rather than a worker-launch error.
    final otherListener = await _listen();
    final dropConnection = otherListener.first.then(
      (socket) => socket.destroy(),
    );
    await expectLater(
      _handshake(healthy, otherListener),
      throwsA(_nativeError('RDP 安全协议协商失败')),
    );
    await dropConnection;
  });

  test('RDP 子进程意外退出会唤醒正在等待的握手', () async {
    final worker = await _openWorker();
    final listener = await _listen();
    final connection = listener.first;
    final blocked = expectLater(
      _handshake(worker, listener),
      throwsA(_nativeError('RDP 会话进程已退出')),
    );
    final heldPeer = await connection.timeout(_deadline);
    addTearDown(heldPeer.destroy);
    worker.terminate();
    await blocked.timeout(_deadline);
    await worker.waitForExit();
  });

  test('VNC 子进程无响应限时关闭且意外退出会唤醒等待', () async {
    final stalled = await _openVncWorker();
    final crashed = await _openVncWorker();
    expect(stalled.info.processId, isNot(crashed.info.processId));
    expect(stalled.info.processId, isNot(pid));

    final listener = await _listen();
    final connection = listener.first;
    final blocked = expectLater(
      vnc.vncWorkerConnect(
        sessionId: stalled.info.sessionId,
        host: InternetAddress.loopbackIPv4.address,
        port: listener.port,
        password: '',
      ),
      throwsA(_nativeError('VNC 会话进程无响应')),
    );
    final heldPeer = await connection.timeout(_deadline);
    addTearDown(heldPeer.destroy);

    final elapsed = Stopwatch()..start();
    await vnc.vncDisconnect(sessionId: stalled.info.sessionId);
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 4)));
    await blocked;
    await stalled.waitForExit();
    expect(crashed.exited, isFalse);

    final listener2 = await _listen();
    final connection2 = listener2.first;
    final crashWait = expectLater(
      vnc.vncWorkerConnect(
        sessionId: crashed.info.sessionId,
        host: InternetAddress.loopbackIPv4.address,
        port: listener2.port,
        password: '',
      ),
      throwsA(_nativeError('VNC 会话进程已退出')),
    );
    final heldPeer2 = await connection2.timeout(_deadline);
    addTearDown(heldPeer2.destroy);
    crashed.terminate();
    await crashWait.timeout(_deadline);
    await crashed.waitForExit();
  });
}

Matcher _nativeError(String message) => isA<AnyhowException>().having(
  (error) => error.message,
  'message',
  contains(message),
);

Future<rdp.DesktopHandshake> _handshake(
  _Worker worker,
  ServerSocket listener,
) => rdp.desktopWorkerHandshake(
  sessionId: worker.info.sessionId,
  host: InternetAddress.loopbackIPv4.address,
  port: listener.port,
);

Future<ServerSocket> _listen() async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(listener.close);
  return listener;
}

Future<_Worker> _openWorker() async {
  final info = await rdp.desktopWorkerOpen();
  addTearDown(() => rdp.desktopDisconnect(sessionId: info.sessionId));
  final worker = _Worker(info);
  addTearDown(worker.closeHandle);
  return worker;
}

Future<_Worker> _openVncWorker() async {
  final info = await vnc.vncWorkerOpen();
  addTearDown(() => vnc.vncDisconnect(sessionId: info.sessionId));
  final worker = _Worker(info);
  addTearDown(worker.closeHandle);
  return worker;
}

class _Worker {
  _Worker(this.info) {
    // Keep the original process handle so a reused PID cannot make the exit
    // assertion refer to a different process.
    // SYNCHRONIZE | PROCESS_TERMINATE.
    _handle = _open(0x00100001, 0, info.processId);
    expect(_handle.address, isNot(0));
  }

  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _open = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final _wait = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  static final _close = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _terminate = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('TerminateProcess');

  final rdp.DesktopWorkerStarted info;
  late final Pointer<Void> _handle;

  // WAIT_OBJECT_0: the process has exited. Zero timeout never blocks Flutter.
  bool get exited => _wait(_handle, 0) == 0;

  void terminate() => expect(_terminate(_handle, 1), isNot(0));

  Future<void> waitForExit() async {
    final elapsed = Stopwatch()..start();
    while (!exited && elapsed.elapsed < _deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(exited, isTrue, reason: 'RDP worker was left running');
  }

  void closeHandle() => _close(_handle);
}
