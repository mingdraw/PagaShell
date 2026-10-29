import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../../domain/ssh/ssh_engine.dart';
import '../../src/rust/api/ssh.dart' as rust;

/// 进度流关闭不代表远端写入成功，必须收到 Rust 在最终确认后发出的完成标记。
Stream<SftpTransferProgress> rustTransferStream(
  Stream<rust.TransferProgress> inner, {
  required Future<void> Function() cancel,
}) {
  final controller = StreamController<SftpTransferProgress>();
  StreamSubscription<rust.TransferProgress>? sub;
  var finished = false;
  var confirmed = false;
  controller.onListen = () {
    sub = inner.listen(
      (progress) {
        if (finished) return;
        confirmed =
            progress.completed &&
            (progress.total == BigInt.zero ||
                progress.transferred == progress.total);
        controller.add(
          SftpTransferProgress(
            transferred: progress.transferred.toInt(),
            total: progress.total.toInt(),
          ),
        );
      },
      onError: (Object error, StackTrace stack) {
        if (finished) return;
        finished = true;
        controller.addError(
          error is AnyhowException
              ? SshEngineException(error.message.split('\n').first, error)
              : error,
          stack,
        );
        unawaited(controller.close());
      },
      onDone: () {
        if (!finished && !confirmed) {
          controller.addError(const SshEngineException('传输未完成，请检查连接后重试'));
        }
        finished = true;
        unawaited(controller.close());
      },
    );
  };
  controller.onCancel = () async {
    await sub?.cancel();
    if (!finished) await cancel();
  };
  return controller.stream;
}
