import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/rust_transfer_stream.dart';
import 'package:pagashell/src/rust/api/ssh.dart' as rust;

import '../support/fake_sftp_session.dart';

class _RustProgressSession extends FakeSftpSession {
  _RustProgressSession(this.progress);
  final Stream<rust.TransferProgress> progress;

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) =>
      rustTransferStream(progress, cancel: () async {});
}

rust.TransferProgress progress(
  int bytes,
  int total, {
  bool completed = false,
}) => rust.TransferProgress(
  transferred: BigInt.from(bytes),
  total: BigInt.from(total),
  completed: completed,
);

void main() {
  for (final bytes in [14, 20]) {
    test('仅进度流关闭不会把 $bytes/20 的未确认上传标记成功', () async {
      final engine = _RustProgressSession(Stream.value(progress(bytes, 20)));
      addTearDown(engine.close);
      final controller = TransferController();
      addTearDown(controller.onClose);
      final task = controller.startUpload(
        sessionId: 's1',
        engineSession: engine,
        localPath: '/source',
        remotePath: '/target',
      );
      await task.status.stream.firstWhere(
        (value) => value != TransferStatus.running,
      );
      expect(task.status.value, TransferStatus.failed);
      expect(task.error.value, '传输未完成，请检查连接后重试');
      expect(task.transferred.value, bytes);
      expect(controller.canRetry(task), isTrue);
    });
  }

  test('Rust 错误传递到进度流并保留原始失败原因', () async {
    final input = StreamController<rust.TransferProgress>();
    final stream = rustTransferStream(input.stream, cancel: () async {});
    final expected = expectLater(
      stream,
      emitsInOrder([
        isA<SftpTransferProgress>(),
        emitsError(
          isA<SshEngineException>().having(
            (error) => error.message,
            'message',
            '写入远程文件失败',
          ),
        ),
        emitsDone,
      ]),
    );
    input.add(progress(14, 20));
    input.addError(AnyhowException('写入远程文件失败\nChannel send error'));
    await input.close();
    await expected;
  });

  for (final total in [0, 20]) {
    test('完成标记后才允许成功，包括空文件 $total', () async {
      final result = await rustTransferStream(
        Stream.value(progress(total, total, completed: true)),
        cancel: () async {},
      ).toList();
      expect(result.single.transferred, total);
    });
  }

  test('无事件关闭或完成标记字节数不完整时失败', () async {
    for (final input in [
      const Stream<rust.TransferProgress>.empty(),
      Stream.value(progress(14, 20, completed: true)),
    ]) {
      await expectLater(
        rustTransferStream(input, cancel: () async {}).drain<void>(),
        throwsA(isA<SshEngineException>()),
      );
    }
  });

  test('取消监听时只调用一次 Rust 取消且不投递完成错误', () async {
    final input = StreamController<rust.TransferProgress>();
    var cancellations = 0;
    final sub = rustTransferStream(
      input.stream,
      cancel: () async {
        cancellations++;
      },
    ).listen((_) {});
    await sub.cancel();
    await input.close();
    expect(cancellations, 1);
  });
}
