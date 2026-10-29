import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vnc/vnc_engine.dart';
import 'package:pagashell/infrastructure/ssh/rust_ssh_engine.dart';
import 'package:pagashell/src/rust/frb_generated.dart';

/// Runs the real Dart → FRB → Rust → TCP path without saved user data.
/// flutter test integration_test/vnc_connection_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('原生 VNC：密码握手、RGBA 帧、键鼠及断开回路', () async {
    await RustLib.init();
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? peer;
    VncEngineSession? desktop;
    final inputReceived = Completer<List<List<int>>>();
    final disconnected = Completer<void>();
    final worker = () async {
      peer = await listener.first;
      final reader = _SocketReader(peer!);
      try {
        peer!.add(ascii.encode('RFB 003.008\n'));
        expect(ascii.decode(await reader.read(12)), 'RFB 003.008\n');
        peer!.add([1, 2]); // One security type: standard VNC password.
        expect(await reader.read(1), [2]);
        peer!.add(List<int>.generate(16, (index) => index));
        // Independently calculated DES fixture for password "secret".
        expect(await reader.read(16), [
          0xee,
          0x22,
          0x53,
          0x9f,
          0x33,
          0xa5,
          0x98,
          0x3e,
          0xc1,
          0x2f,
          0x9c,
          0x2e,
          0xdb,
          0xc9,
          0x95,
          0xdd,
        ]);
        peer!.add([0, 0, 0, 0]); // Authentication accepted.
        expect(await reader.read(1), [1]); // Shared desktop.
        peer!.add([
          0, 2, 0, 1, // 2 × 1 pixels.
          32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
          0, 0, 0, 4, 116, 101, 115, 116, // Desktop name "test".
        ]);
        final format = await reader.read(20);
        expect(format.first, 0);
        expect(format.sublist(14, 17), [0, 8, 16]);
        expect(await reader.read(2), [2, 0]); // SetEncodings.
        final count = ByteData.sublistView(await reader.read(2)).getUint16(0);
        await reader.read(count * 4);
        peer!.add([
          0, 0, 0, 1, // FramebufferUpdate: one Raw rectangle.
          0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0,
          255, 0, 0, 0, 0, 255, 0, 0,
        ]);
        final inputs = <List<int>>[];
        while (true) {
          final kind = (await reader.read(1)).single;
          final length = switch (kind) {
            3 => 9, // FramebufferUpdateRequest.
            4 => 7, // KeyEvent.
            5 => 5, // PointerEvent.
            _ => throw StateError('Unexpected RFB message $kind'),
          };
          final body = await reader.read(length);
          if (kind != 3) {
            inputs.add([kind, ...body]);
            if (inputs.length == 4 && !inputReceived.isCompleted) {
              inputReceived.complete(inputs.toList());
            }
          }
        }
      } on _PeerClosed {
        if (!inputReceived.isCompleted) {
          inputReceived.completeError(StateError('VNC closed before input'));
        }
        disconnected.complete();
      } finally {
        await reader.cancel();
      }
    }();
    try {
      desktop =
          await const RustVncEngine()
                  .connectDesktop(
                    Host(
                      id: 'vnc-native-test',
                      name: 'Disposable VNC',
                      hostname: '127.0.0.1',
                      username: '',
                      port: listener.port,
                      serviceType: ServiceType.vnc,
                    ),
                    const SshCredentials.password('secret'),
                    verifyHostKey: (_) async =>
                        throw StateError('Direct VNC has no host key'),
                  )
                  .timeout(const Duration(seconds: 15))
              as VncEngineSession;
      final frame = await desktop.frames
          .firstWhere(
            (value) => value.rgba.isNotEmpty && value.rgba.first == 255,
          )
          .timeout(const Duration(seconds: 5));
      expect((frame.width, frame.height), (2, 1));
      expect(frame.rgba, [255, 0, 0, 255, 0, 255, 0, 255]);
      await desktop.keySymbol(0xff51, down: true);
      await desktop.keySymbol(0xff51, down: false);
      await desktop.pointer(1, 0, 0x9000);
      await desktop.pointer(1, 0, 0x1000);
      final inputs = await inputReceived.future.timeout(
        const Duration(seconds: 5),
      );
      expect(inputs, [
        [4, 1, 0, 0, 0, 0, 0xff, 0x51],
        [4, 0, 0, 0, 0, 0, 0xff, 0x51],
        [5, 1, 0, 1, 0, 0],
        [5, 0, 0, 1, 0, 0],
      ]);
      expect(await desktop.resize(1024, 768), isFalse);
      await desktop.close();
      await desktop.close();
      await disconnected.future.timeout(const Duration(seconds: 5));
      await worker;
    } finally {
      await desktop?.close();
      peer?.destroy();
      await listener.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

class _PeerClosed implements Exception {}

class _SocketReader {
  _SocketReader(Socket socket) : _chunks = StreamIterator(socket);
  final StreamIterator<Uint8List> _chunks;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var copied = 0;
    while (copied < length) {
      if (_offset == _chunk.length) {
        if (!await _chunks.moveNext()) throw _PeerClosed();
        _chunk = _chunks.current;
        _offset = 0;
      }
      final remaining = _chunk.length - _offset;
      final count = remaining < length - copied ? remaining : length - copied;
      result.setRange(copied, copied + count, _chunk, _offset);
      _offset += count;
      copied += count;
    }
    return result;
  }

  Future<void> cancel() => _chunks.cancel();
}
