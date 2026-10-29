import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

/// 进度流可控的假引擎会话（每个实例承载一次传输）。
class _FakeTransferSession implements SshEngineSession {
  final StreamController<SftpTransferProgress> progress =
      StreamController<SftpTransferProgress>();
  String? lastRemotePath;
  String? lastLocalPath;

  /// 测试收尾：关闭进度流。未被监听的 controller 的 close future
  /// 不会完成，因此不 await。
  void dispose() {
    unawaited(progress.close());
  }

  @override
  Stream<SftpTransferProgress> download(String remotePath, String localPath) {
    lastRemotePath = remotePath;
    lastLocalPath = localPath;
    return progress.stream;
  }

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) {
    lastRemotePath = remotePath;
    lastLocalPath = localPath;
    return progress.stream;
  }

  @override
  Stream<String> startShell({required int cols, required int rows}) =>
      const Stream.empty();

  @override
  void write(String data) {}

  @override
  void resizeTerminal(int width, int height) {}

  @override
  Future<List<SftpDirEntry>> listDir(String path) async => const [];

  @override
  Future<String> canonicalize(String path) async => '/';

  @override
  Future<void> createDir(String path) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> remove(String path, {required bool isDir}) async {}

  @override
  Future<void> close() async {}
}

class _RetrySession extends _FakeTransferSession {
  final attempts = <StreamController<SftpTransferProgress>>[];
  final targets = <(String, String)>[];

  Stream<SftpTransferProgress> _open(String local, String remote) {
    targets.add((local, remote));
    final attempt = StreamController<SftpTransferProgress>();
    attempts.add(attempt);
    return attempt.stream;
  }

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) =>
      _open(localPath, remotePath);

  @override
  Stream<SftpTransferProgress> download(String remotePath, String localPath) =>
      _open(localPath, remotePath);

  @override
  void dispose() {
    for (final attempt in attempts) {
      unawaited(attempt.close());
    }
    super.dispose();
  }
}

void main() {
  for (final upload in [true, false]) {
    test('${upload ? '上传' : '下载'}失败后原任务重试，清零进度错误且连点只启动一次', () async {
      final controller = TransferController();
      final session = _RetrySession();
      addTearDown(controller.onClose);
      addTearDown(session.dispose);
      final task = upload
          ? controller.startUpload(
              sessionId: 's1',
              engineSession: session,
              localPath: '/local/a',
              remotePath: '/remote/a',
            )
          : controller.startDownload(
              sessionId: 's1',
              engineSession: session,
              localPath: '/local/a',
              remotePath: '/remote/a',
            );
      session.attempts.first.add(
        const SftpTransferProgress(transferred: 20, total: 100),
      );
      session.attempts.first.addError(const SshEngineException('failed'));
      await Future<void>.delayed(Duration.zero);
      expect(task.status.value, TransferStatus.failed);
      expect(task.transferred.value, 20);
      await Future.wait([controller.retry(task.id), controller.retry(task.id)]);
      expect(controller.tasks, [task]);
      expect(session.targets, [
        ('/local/a', '/remote/a'),
        ('/local/a', '/remote/a'),
      ]);
      expect(task.status.value, TransferStatus.running);
      expect(task.error.value, isNull);
      expect(task.transferred.value, 0);
      expect(task.total.value, 0);
      expect(task.bytesPerSecond.value, 0);
      session.attempts.last.add(
        const SftpTransferProgress(transferred: 100, total: 100),
      );
      await session.attempts.last.close();
      expect(task.status.value, TransferStatus.done);
      await controller.retry(task.id);
      expect(session.attempts, hasLength(2));
    });
  }

  test('重试等待前次取消清理并重新获得源权限，关闭标签时迟到的权限会释放', () async {
    final controller = TransferController();
    final session = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    final cleanup = Completer<void>();
    final acquired = Completer<Future<void> Function()>();
    var acquireCount = 0;
    var releaseCount = 0;
    final task = controller.startUpload(
      sessionId: 's1',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
      releaseSource: () => cleanup.future,
      acquireSource: () {
        acquireCount++;
        return acquired.future;
      },
    );
    session.attempts.first.addError(const SshEngineException('failed'));
    await Future<void>.delayed(Duration.zero);
    final retry = controller.retry(task.id);
    await Future<void>.delayed(Duration.zero);
    expect(acquireCount, 0);
    cleanup.complete();
    await Future<void>.delayed(Duration.zero);
    expect(acquireCount, 1);
    controller.clearFinished();
    expect(controller.tasks, [task]);
    await controller.cancelSession('s1');
    acquired.complete(() async {
      releaseCount++;
    });
    await retry;
    expect(session.attempts, hasLength(1));
    expect(releaseCount, 1);
    expect(task.retrying.value, isFalse);
  });

  test('同一目标正在传输时不重试，重试再次失败后仍可继续重试', () async {
    final controller = TransferController();
    final session = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    TransferTask start() => controller.startUpload(
      sessionId: 's1',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    final failed = start();
    session.attempts.first.addError(const SshEngineException('failed'));
    await Future<void>.delayed(Duration.zero);
    final running = start();
    await controller.retry(failed.id);
    expect(session.attempts, hasLength(2));
    await controller.cancel(running.id);
    await controller.retry(failed.id);
    session.attempts.last.addError(const SshEngineException('failed again'));
    await Future<void>.delayed(Duration.zero);
    expect(failed.error.value, 'failed again');
    await controller.retry(failed.id);
    expect(session.attempts, hasLength(4));
    expect(failed.status.value, TransferStatus.running);
  });

  for (final ending in ['done', 'failed', 'cancel', 'close']) {
    test('上传源权限在 $ending 后释放一次，取消等待引擎清理完成', () async {
      final controller = TransferController();
      final session = _FakeTransferSession();
      final cancelled = Completer<void>();
      final cancelStarted = Completer<void>();
      var releases = 0;
      if (ending == 'cancel' || ending == 'close') {
        session.progress.onCancel = () {
          cancelStarted.complete();
          return cancelled.future;
        };
      }
      final task = controller.startUpload(
        sessionId: 's1',
        engineSession: session,
        localPath: '/local/a',
        remotePath: '/remote/a',
        releaseSource: () async {
          releases++;
        },
      );
      expect(releases, 0);
      if (ending == 'done') {
        await session.progress.close();
      } else if (ending == 'failed') {
        session.progress.addError(const SshEngineException('upload failed'));
        await Future<void>.delayed(Duration.zero);
      } else {
        Future<void>? cancellation;
        if (ending == 'cancel') {
          cancellation = controller.cancel(task.id);
        } else {
          controller.onClose();
        }
        await cancelStarted.future;
        expect(releases, 0);
        cancelled.complete();
        await cancellation;
      }
      await Future<void>.delayed(Duration.zero);
      expect(releases, 1);
      controller.onClose();
      await Future<void>.delayed(Duration.zero);
      expect(releases, 1);
      session.dispose();
    });
  }

  testWidgets('速率平滑短暂上报空档，持续停滞归零，恢复和完成时正确更新', (tester) async {
    final started = tester.binding.clock.now();
    final controller = TransferController(
      elapsed: () => tester.binding.clock.now().difference(started),
    );
    final session = _FakeTransferSession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    final task = controller.startUpload(
      sessionId: 's1',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    session.progress.add(
      const SftpTransferProgress(transferred: 512, total: 8192),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(task.bytesPerSecond.value, 1024);
    await tester.pump(const Duration(milliseconds: 500));
    expect(task.bytesPerSecond.value, 512);
    session.progress.add(
      const SftpTransferProgress(transferred: 1280, total: 8192),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(task.bytesPerSecond.value, closeTo(1280 / 1.5, 0.01));
    for (var tick = 0; tick < 6; tick++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(task.status.value, TransferStatus.running);
    expect(task.bytesPerSecond.value, 0);
    session.progress.add(
      const SftpTransferProgress(transferred: 2048, total: 8192),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(task.bytesPerSecond.value, 256);
    await session.progress.close();
    await tester.pump();
    expect(task.status.value, TransferStatus.done);
    expect(task.bytesPerSecond.value, 0);
    expect(controller.totalBytesPerSecond('s1'), 0);
  });

  testWidgets('下载按秒分块上报时总速率持续显示且使用最近三秒数据', (tester) async {
    final started = tester.binding.clock.now();
    final controller = TransferController(
      elapsed: () => tester.binding.clock.now().difference(started),
    );
    final session = _FakeTransferSession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    final task = controller.startDownload(
      sessionId: 's1',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    for (var chunk = 1; chunk <= 6; chunk++) {
      session.progress.add(
        SftpTransferProgress(transferred: chunk * 1024, total: 16384),
      );
      await tester.pump();
      for (var tick = 0; tick < 2; tick++) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.totalBytesPerSecond('s1'), greaterThan(0));
      }
    }
    expect(task.bytesPerSecond.value, 1024);
    await session.progress.close();
    await tester.pump();
    expect(controller.totalBytesPerSecond('s1'), 0);
  });

  test('总速率仅汇总当前会话，取消与失败立即移除速率', () async {
    var elapsed = Duration.zero;
    final controller = TransferController(elapsed: () => elapsed);
    final sessions = List.generate(3, (_) => _FakeTransferSession());
    addTearDown(() {
      controller.onClose();
      for (final session in sessions) {
        session.dispose();
      }
    });
    final tasks = [
      for (var index = 0; index < sessions.length; index++)
        controller.startDownload(
          sessionId: index == 2 ? 's2' : 's1',
          engineSession: sessions[index],
          localPath: '/local/$index',
          remotePath: '/remote/$index',
        ),
    ];
    for (var index = 0; index < sessions.length; index++) {
      sessions[index].progress.add(
        SftpTransferProgress(transferred: 1024 * (1 << index), total: 16384),
      );
    }
    elapsed = const Duration(milliseconds: 500);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(controller.totalBytesPerSecond('s1'), 6144);
    expect(controller.totalBytesPerSecond('s2'), 8192);
    await controller.cancel(tasks[0].id);
    expect(tasks[0].bytesPerSecond.value, 0);
    expect(controller.totalBytesPerSecond('s1'), 4096);
    sessions[1].progress.addError(const SshEngineException('transfer failed'));
    await Future<void>.delayed(Duration.zero);
    expect(tasks[1].bytesPerSecond.value, 0);
    expect(controller.totalBytesPerSecond('s1'), 0);
    expect(controller.totalBytesPerSecond('s2'), 8192);
  });

  group('TransferController', () {
    late TransferController controller;
    late _FakeTransferSession session;

    setUp(() {
      controller = TransferController();
      session = _FakeTransferSession();
    });

    tearDown(() {
      controller.onClose();
      session.dispose();
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('下载任务跟踪进度并在流结束后标记完成', () async {
      final task = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/var/log/app.log',
        localPath: '/tmp/app.log',
      );

      expect(task.fileName, 'app.log');
      expect(task.status.value, TransferStatus.running);

      session.progress.add(
        const SftpTransferProgress(transferred: 512, total: 1024),
      );
      await pump();
      expect(task.transferred.value, 512);
      expect(task.fraction, 0.5);

      await session.progress.close();
      await pump();
      expect(task.status.value, TransferStatus.done);
    });

    test('传输失败记录错误信息', () async {
      final task = controller.startUpload(
        sessionId: 's1',
        engineSession: session,
        localPath: '/tmp/big.bin',
        remotePath: '/data/big.bin',
      );

      session.progress.addError(const SshEngineException('磁盘空间不足'));
      await pump();

      expect(task.status.value, TransferStatus.failed);
      expect(task.error.value, '磁盘空间不足');
    });

    test('取消任务后不再接收事件', () async {
      final task = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/a.bin',
        localPath: '/tmp/a.bin',
      );

      await controller.cancel(task.id);
      expect(task.status.value, TransferStatus.cancelled);

      // 取消后引擎流的迟到事件不影响任务状态。
      session.progress.add(
        const SftpTransferProgress(transferred: 999, total: 1000),
      );
      await pump();
      expect(task.transferred.value, 0);
      expect(task.status.value, TransferStatus.cancelled);
    });

    test('clearFinished 只保留进行中的任务', () async {
      final running = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/a',
        localPath: '/tmp/a',
      );
      final done = controller.startDownload(
        sessionId: 's1',
        engineSession: _FakeTransferSession(),
        remotePath: '/b',
        localPath: '/tmp/b',
      );
      done.status.value = TransferStatus.done;

      controller.clearFinished();

      expect(controller.tasks.map((t) => t.id), [running.id]);
    });

    test('cancelSession 只取消指定标签，其他标签继续传输', () async {
      final otherSession = _FakeTransferSession();
      final first = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/a',
        localPath: '/tmp/a',
      );
      final other = controller.startDownload(
        sessionId: 's2',
        engineSession: otherSession,
        remotePath: '/b',
        localPath: '/tmp/b',
      );
      await controller.cancelSession('s1');
      expect(first.status.value, TransferStatus.cancelled);
      expect(other.status.value, TransferStatus.running);
      await controller.cancelSession('s2');
      otherSession.dispose();
    });

    test('tasksOf 按会话过滤', () async {
      controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/a',
        localPath: '/tmp/a',
      );
      controller.startDownload(
        sessionId: 's2',
        engineSession: _FakeTransferSession(),
        remotePath: '/b',
        localPath: '/tmp/b',
      );

      expect(controller.tasksOf('s1').length, 1);
      expect(controller.tasksOf('s2').single.fileName, 'b');
    });
  });
}
