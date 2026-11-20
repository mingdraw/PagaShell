import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/transfer/directory_transfer.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

/// 进度流可控的假引擎会话（每个实例承载一次传输）。
class _FakeTransferSession implements SshEngineSession, ResumableSftpSession {
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
  Stream<SftpTransferProgress> downloadResuming(
    String remotePath,
    String localPath,
  ) => download(remotePath, localPath);

  @override
  Stream<SftpTransferProgress> uploadResuming(
    String localPath,
    String remotePath,
  ) => upload(localPath, remotePath);

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
  final resumes = <bool>[];

  Stream<SftpTransferProgress> _open(
    String local,
    String remote, {
    bool resume = false,
  }) {
    targets.add((local, remote));
    resumes.add(resume);
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
  Stream<SftpTransferProgress> uploadResuming(
    String localPath,
    String remotePath,
  ) => _open(localPath, remotePath, resume: true);

  @override
  Stream<SftpTransferProgress> downloadResuming(
    String remotePath,
    String localPath,
  ) => _open(localPath, remotePath, resume: true);

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
    test('${upload ? '上传' : '下载'}重连等待旧任务收尾，保留记录并使用新连接重试', () async {
      final controller = TransferController();
      final old = _RetrySession();
      final replacement = _RetrySession();
      final other = _RetrySession();
      addTearDown(controller.onClose);
      addTearDown(old.dispose);
      addTearDown(replacement.dispose);
      addTearDown(other.dispose);
      final cleanup = Completer<void>();
      final task = upload
          ? controller.startUpload(
              sessionId: 's1',
              engineSession: old,
              localPath: '/local/a',
              remotePath: '/remote/a',
              releaseSource: () => cleanup.future,
            )
          : controller.startDownload(
              sessionId: 's1',
              engineSession: old,
              localPath: '/local/a',
              remotePath: '/remote/a',
            );
      final otherTask = controller.startUpload(
        sessionId: 's2',
        engineSession: other,
        localPath: '/local/b',
        remotePath: '/remote/b',
      );
      old.attempts.single.onCancel = () => cleanup.future;
      var finished = false;
      final interrupted = controller.interruptSession('s1').then((_) {
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(task.status.value, TransferStatus.failed);
      expect(task.error.value, SshEngineException.connectionClosedMessage);
      expect(otherTask.status.value, TransferStatus.running);
      expect(controller.canRetry(task), isFalse);
      await controller.retry(task.id);
      expect(old.attempts, hasLength(1));
      expect(finished, isFalse);
      cleanup.complete();
      await interrupted;
      controller.bindSession('s1', replacement);
      expect(controller.canRetry(task), isTrue);
      expect(replacement.attempts, isEmpty);
      await controller.retry(task.id);
      expect(replacement.targets, [('/local/a', '/remote/a')]);
      expect(old.attempts, hasLength(1));
      expect(task.status.value, TransferStatus.running);
      replacement.attempts.single.add(
        const SftpTransferProgress(transferred: 100, total: 100),
      );
      await replacement.attempts.single.close();
      await Future<void>.delayed(Duration.zero);
      expect(task.status.value, TransferStatus.done);
    });

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
      expect(session.resumes, [false, true]);
      expect(task.status.value, TransferStatus.running);
      expect(task.error.value, isNull);
      expect(task.transferred.value, 0);
      expect(task.total.value, 0);
      expect(task.bytesPerSecond.value, 0);
      session.attempts.last.add(
        const SftpTransferProgress(transferred: 100, total: 100),
      );
      await session.attempts.last.close();
      await Future<void>.delayed(Duration.zero);
      expect(task.status.value, TransferStatus.done);
      await controller.retry(task.id);
      expect(session.attempts, hasLength(2));
    });
  }

  test('每个会话限制并发，排队任务可取消并在关闭时释放权限', () async {
    final controller = TransferController(maxConcurrentFiles: 2);
    final session = _RetrySession();
    final other = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    addTearDown(other.dispose);
    var releases = 0;
    var acquisitions = 0;
    TransferTask start(String name, {bool withAccess = false}) =>
        controller.startUpload(
          sessionId: 's1',
          engineSession: session,
          localPath: '/local/$name',
          remotePath: '/remote/$name',
          releaseSource: withAccess ? () async => releases++ : null,
          acquireSource: withAccess
              ? () async {
                  acquisitions++;
                  return () async {
                    releases++;
                  };
                }
              : null,
        );
    final first = start('a');
    final second = start('b');
    final queued = start('c', withAccess: true);
    final fourth = start('d');
    final waiting = start('e');
    final isolated = controller.startUpload(
      sessionId: 's2',
      engineSession: other,
      localPath: '/local/other',
      remotePath: '/remote/other',
    );
    expect(session.attempts, hasLength(2));
    expect(first.status.value, TransferStatus.running);
    expect(second.status.value, TransferStatus.running);
    expect(queued.status.value, TransferStatus.queued);
    expect(fourth.status.value, TransferStatus.queued);
    expect(isolated.status.value, TransferStatus.running);
    controller.clearFinished(sessionId: 's1');
    expect(controller.tasksOf('s1'), hasLength(5));
    await controller.cancel(queued.id);
    expect(queued.status.value, TransferStatus.cancelled);
    expect(releases, 1);
    await controller.retry(queued.id);
    expect(acquisitions, 0);
    expect(queued.status.value, TransferStatus.cancelled);
    expect(session.attempts, hasLength(2));
    session.attempts.first.add(
      const SftpTransferProgress(transferred: 1, total: 1),
    );
    await session.attempts.first.close();
    await Future<void>.delayed(Duration.zero);
    expect(session.targets.last, ('/local/d', '/remote/d'));
    expect(fourth.status.value, TransferStatus.running);
    expect(waiting.status.value, TransferStatus.queued);
    await controller.cancelSession('s1');
    expect(session.attempts, hasLength(3));
    expect(queued.status.value, TransferStatus.cancelled);
    expect(releases, 1);
    expect(isolated.status.value, TransferStatus.running);
  });

  test('重连后仅续传已启动的文件，排队未启动的文件从头开始', () async {
    final controller = TransferController(maxConcurrentFiles: 1);
    final old = _RetrySession();
    final replacement = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(old.dispose);
    addTearDown(replacement.dispose);
    final first = controller.startDownload(
      sessionId: 's',
      engineSession: old,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    final queued = controller.startDownload(
      sessionId: 's',
      engineSession: old,
      localPath: '/local/b',
      remotePath: '/remote/b',
    );
    expect(old.attempts, hasLength(1));
    expect(queued.status.value, TransferStatus.queued);
    await controller.interruptSession('s');
    expect(first.status.value, TransferStatus.failed);
    expect(queued.status.value, TransferStatus.failed);
    controller.bindSession('s', replacement);
    await controller.retry(queued.id);
    await controller.retry(first.id);
    expect(replacement.resumes, [false]);
    expect(first.status.value, TransferStatus.queued);
    replacement.attempts.first.add(
      const SftpTransferProgress(transferred: 1, total: 1),
    );
    await replacement.attempts.first.close();
    await Future<void>.delayed(Duration.zero);
    expect(replacement.resumes, [false, true]);
    expect(first.status.value, TransferStatus.running);
  });

  test('排队上传的权限只在获得并发位置时重新获取', () async {
    final controller = TransferController(maxConcurrentFiles: 1);
    final session = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    var acquired = 0;
    var released = 0;
    controller.startUpload(
      sessionId: 's',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    final queued = controller.startUpload(
      sessionId: 's',
      engineSession: session,
      localPath: '/local/b',
      remotePath: '/remote/b',
      releaseSource: () async {
        released++;
      },
      acquireSource: () async {
        acquired++;
        return () async {
          released++;
        };
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(queued.status.value, TransferStatus.queued);
    expect(released, 1);
    expect(acquired, 0);
    session.attempts.first.add(
      const SftpTransferProgress(transferred: 1, total: 1),
    );
    await session.attempts.first.close();
    await Future<void>.delayed(Duration.zero);
    expect(acquired, 1);
    expect(session.targets.last, ('/local/b', '/remote/b'));
    await controller.cancel(queued.id);
    expect(released, 2);
  });

  test('目录取消决定等待所有文件流结束后退出且保留取消状态', () async {
    // 目录级并发取消行为由 directory_transfer_test 覆盖；此处校验错误分支。
    final controller = TransferController();
    final session = _RetrySession();
    addTearDown(controller.onClose);
    addTearDown(session.dispose);
    final task = controller.startUpload(
      sessionId: 's',
      engineSession: session,
      localPath: '/local/a',
      remotePath: '/remote/a',
    );
    session.attempts.first.addError(const DirectoryTransferCancelled());
    await Future<void>.delayed(Duration.zero);
    expect(task.status.value, TransferStatus.cancelled);
    expect(controller.canRetry(task), isFalse);
  });

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

    test('高频进度合并写入，结束时落最后进度', () async {
      final task = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/big.bin',
        localPath: '/tmp/big.bin',
      );
      final writes = <int>[];
      final sub = task.transferred.listen(writes.add);
      addTearDown(sub.cancel);

      for (var i = 1; i <= 50; i++) {
        session.progress.add(
          SftpTransferProgress(transferred: i * 10, total: 500),
        );
      }
      await pump();
      // 首个事件立即生效，其余合并等待下一个间隔。
      expect(task.transferred.value, 10);

      await Future<void>.delayed(
        TransferController.progressInterval + const Duration(milliseconds: 50),
      );
      expect(task.transferred.value, 500);
      expect(writes, [10, 500]);

      session.progress.add(
        const SftpTransferProgress(transferred: 500, total: 500),
      );
      await session.progress.close();
      await pump();
      expect(task.status.value, TransferStatus.done);
      expect(task.fraction, 1.0);
    });

    test('流结束时立即写入尚未合并的进度', () async {
      final task = controller.startDownload(
        sessionId: 's1',
        engineSession: session,
        remotePath: '/b.bin',
        localPath: '/tmp/b.bin',
      );
      session.progress
        ..add(const SftpTransferProgress(transferred: 1, total: 4))
        ..add(const SftpTransferProgress(transferred: 4, total: 4));
      await session.progress.close();
      await pump();
      expect(task.transferred.value, 4);
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

    test('clearFinished 保留进行中和可重试的失败任务', () async {
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
      final broken = _FakeTransferSession();
      addTearDown(broken.dispose);
      final failed = controller.startDownload(
        sessionId: 's1',
        engineSession: broken,
        remotePath: '/c',
        localPath: '/tmp/c',
      );
      broken.progress.addError(const SshEngineException('传输失败'));
      await pump();
      expect(failed.status.value, TransferStatus.failed);
      expect(controller.canRetry(failed), isTrue);

      controller.clearFinished();

      expect(
        controller.tasks.map((t) => t.id),
        unorderedEquals([running.id, failed.id]),
      );
      expect(controller.canRetry(failed), isTrue);
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
