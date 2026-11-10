import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/transfer/directory_transfer.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/local_file_entry.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/fake_sftp_session.dart';
import '../support/in_memory_local_file_repository.dart';

class _ManualSession extends FakeSftpSession {
  _ManualSession({required super.localFiles});

  final attempts = <StreamController<SftpTransferProgress>>[];
  final cancelled = <String>[];

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) {
    uploads.add((localPath, remotePath));
    final events = StreamController<SftpTransferProgress>(
      onCancel: () => cancelled.add(localPath),
    );
    attempts.add(events);
    return events.stream;
  }
}

class _DelayedDirectoryFiles extends InMemoryLocalFileRepository {
  final listing = Completer<List<LocalFileEntry>>();
  bool started = false;

  @override
  Future<List<LocalFileEntry>> listDirectory(String path) {
    if (path != '/local/downloads') return super.listDirectory(path);
    started = true;
    return listing.future;
  }
}

class _DelayedMkdirSession extends FakeSftpSession {
  _DelayedMkdirSession({required super.localFiles});
  final allowCreate = Completer<void>();
  bool creating = false;

  @override
  Future<void> createDir(String path) async {
    creating = true;
    await allowCreate.future;
    await super.createDir(path);
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var index = 0; index < 100 && !predicate(); index++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue, reason: '等待传输异步步骤完成');
}

void main() {
  TransferController controller() {
    final value = TransferController();
    addTearDown(value.onClose);
    return value;
  }

  test('目录上传汇总为一个任务，递归复制隐藏文件及空目录，符号链接不递归展开', () async {
    final files = InMemoryLocalFileRepository();
    await files.createDirectory('/local/downloads/sub');
    await files.createDirectory('/local/downloads/empty');
    files.putFile('/local/downloads/a.txt', 10);
    files.putFile('/local/downloads/sub/.hidden', 20);
    files.fs['/local/downloads']!.add(
      const LocalFileEntry(
        path: '/local/downloads/loop',
        name: 'loop',
        isDir: true,
        size: 0,
        isSymbolicLink: true,
      ),
    );
    final engine = FakeSftpSession(localFiles: files);
    final transfers = controller();
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
    );
    await _until(() => task.status.value != TransferStatus.running);
    expect(task.status.value, TransferStatus.done);
    expect(transfers.tasks, [task]);
    expect(task.isDirectory, isTrue);
    expect(task.total.value, 30);
    expect(task.transferred.value, 30);
    expect(task.currentPath.value, '/local/downloads/sub/.hidden');
    expect(engine.uploads, [
      ('/local/downloads/a.txt', '/home/test/downloads/a.txt'),
      ('/local/downloads/sub/.hidden', '/home/test/downloads/sub/.hidden'),
    ]);
    expect(engine.fs['/home/test/downloads/empty'], isEmpty);
    expect(engine.fs.containsKey('/home/test/downloads/loop'), isFalse);
  });

  test('目录下载保留层级和空目录，显示当前远程文件路径', () async {
    final files = InMemoryLocalFileRepository();
    final engine = FakeSftpSession(localFiles: files);
    engine.fs['/home/test/logs']!.add(
      const SftpDirEntry(name: 'empty', isDir: true, size: 0),
    );
    engine.fs['/home/test/logs/empty'] = [];
    final task = controller().startDownload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/logs',
      remotePath: '/home/test/logs',
      isDirectory: true,
    );
    await _until(() => task.status.value != TransferStatus.running);
    expect(task.status.value, TransferStatus.done);
    expect(task.transferred.value, 2048);
    expect(task.total.value, 2048);
    expect(task.currentPath.value, '/home/test/logs/app.log');
    expect((await files.entryAt('/local/logs/app.log')).size, 2048);
    expect(files.fs['/local/logs/empty'], isEmpty);
  });

  test('文件切换时路径立即更新，字节进度累计且不回退', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10)
      ..putFile('/local/downloads/b.txt', 20);
    final engine = _ManualSession(localFiles: files);
    final task = controller().startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
    );
    await _until(() => engine.attempts.length == 1);
    expect(task.currentPath.value, '/local/downloads/a.txt');
    engine.attempts.first.add(
      const SftpTransferProgress(transferred: 5, total: 10),
    );
    await Future<void>.delayed(TransferController.progressInterval);
    expect(task.total.value, 30);
    expect(task.transferred.value, 5);
    engine.attempts.first.add(
      const SftpTransferProgress(transferred: 10, total: 10),
    );
    await engine.attempts.first.close();
    await _until(() => engine.attempts.length == 2);
    expect(task.currentPath.value, '/local/downloads/b.txt');
    engine.attempts.last.add(
      const SftpTransferProgress(transferred: 5, total: 20),
    );
    await Future<void>.delayed(TransferController.progressInterval);
    expect(task.transferred.value, 15);
    expect(task.total.value, 30);
    engine.attempts.last.add(
      const SftpTransferProgress(transferred: 20, total: 20),
    );
    await engine.attempts.last.close();
    await _until(() => task.status.value == TransferStatus.done);
    expect(task.transferred.value, 30);
  });

  test('取消目录任务会取消当前文件流并停止后续文件，完成清理后释放权限', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10)
      ..putFile('/local/downloads/b.txt', 20);
    final engine = _ManualSession(localFiles: files);
    final transfers = controller();
    var released = 0;
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
      releaseSource: () async {
        released++;
      },
    );
    await _until(() => engine.attempts.isNotEmpty);
    await transfers.cancel(task.id).timeout(const Duration(seconds: 2));
    expect(task.status.value, TransferStatus.cancelled);
    expect(engine.cancelled, ['/local/downloads/a.txt']);
    expect(engine.uploads, hasLength(1));
    expect(released, 1);
  });

  test('目录任务失败可重试，原记录复用并重新获取源权限', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10);
    final engine = _ManualSession(localFiles: files);
    final transfers = controller();
    var acquired = 0;
    var released = 0;
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
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
    await _until(() => engine.attempts.isNotEmpty);
    engine.attempts.first.addError(const SshEngineException('断网'));
    await _until(() => task.status.value == TransferStatus.failed);
    await transfers.retry(task.id);
    await _until(() => engine.attempts.length == 2);
    expect(transfers.tasks, [task]);
    expect(task.status.value, TransferStatus.running);
    expect(acquired, 1);
    expect(released, 1);
    engine.attempts.last.add(
      const SftpTransferProgress(transferred: 10, total: 10),
    );
    await engine.attempts.last.close();
    await _until(
      () => task.status.value == TransferStatus.done && released == 2,
    );
    expect(task.transferred.value, 10);
  });

  test('合并同名目录，文件可跳过或覆盖；取消决策停止任务', () async {
    for (final action in DirectoryConflictAction.values) {
      final files = InMemoryLocalFileRepository()
        ..putFile('/local/downloads/a.txt', 10)
        ..putFile('/local/downloads/b.txt', 20);
      final engine = FakeSftpSession(localFiles: files);
      await engine.createDir('/home/test/downloads');
      engine.fs['/home/test/downloads']!.add(
        const SftpDirEntry(name: 'a.txt', isDir: false, size: 1),
      );
      final conflicts = <String>[];
      final task = controller().startUpload(
        sessionId: 's',
        engineSession: engine,
        localFiles: files,
        localPath: '/local/downloads',
        remotePath: '/home/test/downloads',
        isDirectory: true,
        onConflict: (name) async {
          conflicts.add(name);
          return action;
        },
      );
      await _until(() => task.status.value != TransferStatus.running);
      expect(conflicts, ['a.txt']);
      expect(
        task.status.value,
        action == DirectoryConflictAction.cancel
            ? TransferStatus.cancelled
            : TransferStatus.done,
      );
      expect(engine.uploads.length, switch (action) {
        DirectoryConflictAction.overwrite => 2,
        DirectoryConflictAction.skip => 1,
        DirectoryConflictAction.cancel => 0,
      });
      if (action == DirectoryConflictAction.skip) {
        expect(task.total.value, 20);
        expect(task.transferred.value, 20);
      }
    }
  });

  test('远程条目不能越过目标目录，目录与文件类型冲突明确失败', () async {
    final files = InMemoryLocalFileRepository();
    final engine = FakeSftpSession(localFiles: files);
    engine.fs['/home/test/logs']!.add(
      const SftpDirEntry(name: '../escape', isDir: false, size: 1),
    );
    final task = controller().startDownload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/logs',
      remotePath: '/home/test/logs',
      isDirectory: true,
    );
    await _until(() => task.status.value != TransferStatus.running);
    expect(task.status.value, TransferStatus.failed);
    expect(engine.downloads, isEmpty);
    expect(files.fs.containsKey('/local/logs'), isFalse);
  });

  test('取消等待已发出的目录创建收尾，源权限不会提前释放或继续创建下级目录', () async {
    final files = InMemoryLocalFileRepository();
    await files.createDirectory('/local/downloads/child');
    final engine = _DelayedMkdirSession(localFiles: files);
    final transfers = controller();
    var releases = 0;
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
      releaseSource: () async {
        releases++;
      },
    );
    await _until(() => engine.creating);
    var cancelled = false;
    final cancelling = transfers.cancel(task.id).then((_) => cancelled = true);
    await Future<void>.delayed(Duration.zero);
    expect(task.status.value, TransferStatus.cancelled);
    expect(cancelled, isFalse);
    expect(releases, 0);
    engine.allowCreate.complete();
    await cancelling.timeout(const Duration(seconds: 2));
    expect(releases, 1);
    expect(engine.fs['/home/test/downloads'], isEmpty);
    expect(engine.fs.containsKey('/home/test/downloads/child'), isFalse);
    expect(engine.uploads, isEmpty);
  });

  test('扫描目录等待期间取消能及时结束，迟到的目录结果不启动文件', () async {
    final files = _DelayedDirectoryFiles();
    final engine = FakeSftpSession(localFiles: files);
    final transfers = controller();
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
    );
    await _until(() => files.started);
    await transfers.cancel(task.id).timeout(const Duration(seconds: 2));
    files.listing.complete([
      const LocalFileEntry(
        path: '/local/downloads/late',
        name: 'late',
        isDir: false,
        size: 1,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(task.status.value, TransferStatus.cancelled);
    expect(engine.uploads, isEmpty);
    expect(engine.fs.containsKey('/home/test/downloads'), isFalse);
  });

  test('等待覆盖决定时取消，迟到的覆盖结果也不会开始写入', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10);
    final engine = FakeSftpSession(localFiles: files);
    await engine.createDir('/home/test/downloads');
    engine.fs['/home/test/downloads']!.add(
      const SftpDirEntry(name: 'a.txt', isDir: false, size: 1),
    );
    final decision = Completer<DirectoryConflictAction>();
    var asked = false;
    final transfers = controller();
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
      onConflict: (_) {
        asked = true;
        return decision.future;
      },
    );
    await _until(() => asked);
    await transfers.cancel(task.id).timeout(const Duration(seconds: 2));
    decision.complete(DirectoryConflictAction.overwrite);
    await Future<void>.delayed(Duration.zero);
    expect(task.status.value, TransferStatus.cancelled);
    expect(engine.uploads, isEmpty);
  });

  test('目录中的文件未传完就断开，任务失败并保留出错文件路径', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10);
    final engine = _ManualSession(localFiles: files);
    final task = controller().startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
    );
    await _until(() => engine.attempts.isNotEmpty);
    engine.attempts.first.add(
      const SftpTransferProgress(transferred: 4, total: 10),
    );
    await engine.attempts.first.close();
    await _until(() => task.status.value != TransferStatus.running);
    expect(task.status.value, TransferStatus.failed);
    expect(task.transferred.value, 4);
    expect(task.currentPath.value, '/local/downloads/a.txt');
  });

  test('目录失败重试不会覆盖仍在单独传输的子文件', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10);
    final engine = _ManualSession(localFiles: files);
    final transfers = controller();
    final folder = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
    );
    await _until(() => engine.attempts.isNotEmpty);
    engine.attempts.first.addError(const SshEngineException('断开'));
    await _until(() => folder.status.value == TransferStatus.failed);
    final single = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localPath: '/local/upload.txt',
      remotePath: '/home/test/downloads/a.txt',
    );
    await transfers.retry(folder.id);
    expect(folder.status.value, TransferStatus.failed);
    expect(engine.attempts, hasLength(2));
    await transfers.cancel(single.id);
    await transfers.retry(folder.id);
    await _until(() => engine.attempts.length == 3);
    expect(folder.status.value, TransferStatus.running);
    await transfers.cancel(folder.id);
  });

  test('受限子目录请求授权后继续；单文件始终保留固定源路径', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/downloads/a.txt', 10);
    files.deniedDirectories.add('/local/downloads');
    final engine = FakeSftpSession(localFiles: files);
    final asked = <String>[];
    final transfers = controller();
    final task = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localFiles: files,
      localPath: '/local/downloads',
      remotePath: '/home/test/downloads',
      isDirectory: true,
      authorizeLocalDirectory: (path) async {
        asked.add(path);
        files.deniedDirectories.remove(path);
        return true;
      },
    );
    await _until(() => task.status.value != TransferStatus.running);
    expect(task.status.value, TransferStatus.done);
    expect(asked, ['/local/downloads']);
    final single = transfers.startUpload(
      sessionId: 's',
      engineSession: engine,
      localPath: '/local/upload.txt',
      remotePath: '/home/test/upload.txt',
    );
    await _until(() => single.status.value != TransferStatus.running);
    expect(single.currentPath.value, '/local/upload.txt');
  });
}
