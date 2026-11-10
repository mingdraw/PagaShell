import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../domain/entities/local_file_entry.dart';
import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';

enum DirectoryConflictAction { overwrite, skip, cancel }

typedef DirectoryConflictResolver = Future<DirectoryConflictAction> Function(
  String name,
);
typedef DirectoryAccessRequest = Future<bool> Function(String path);

class DirectoryTransferCancelled implements Exception {
  const DirectoryTransferCancelled();
}

class _DirectoryCancellation {
  bool cancelled = false;
  StreamIterator<SftpTransferProgress>? currentFile;
  Future<void>? currentDirectoryWrite;
  final _cancelled = Completer<void>();

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
  }

  Future<T> wait<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>((_) => throw const DirectoryTransferCancelled()),
  ]);

  Future<void> writeDirectory(Future<void> Function() write) async {
    if (cancelled) throw const DirectoryTransferCancelled();
    final pending = write();
    currentDirectoryWrite = pending;
    try {
      await pending;
    } finally {
      currentDirectoryWrite = null;
    }
    if (cancelled) throw const DirectoryTransferCancelled();
  }
}

class _Entry {
  const _Entry(this.localPath, this.remotePath, [this.size = 0]);
  final String localPath;
  final String remotePath;
  final int size;
}

/// 一个目录对应一个进度流；重试时重新扫描，保留空目录并合并已有目录。
Stream<SftpTransferProgress> transferDirectory({
  required SshEngineSession engine,
  required LocalFileRepository localFiles,
  required String localPath,
  required String remotePath,
  required bool upload,
  DirectoryConflictResolver? onConflict,
  DirectoryAccessRequest? authorizeLocalDirectory,
}) {
  final cancellation = _DirectoryCancellation();
  StreamSubscription<SftpTransferProgress>? subscription;
  var completed = false;
  late final StreamController<SftpTransferProgress> output;
  output = StreamController<SftpTransferProgress>(
    onListen: () {
      subscription =
          _transferDirectory(
            engine: engine,
            localFiles: localFiles,
            localPath: localPath,
            remotePath: remotePath,
            upload: upload,
            onConflict: onConflict,
            authorizeLocalDirectory: authorizeLocalDirectory,
            cancellation: cancellation,
          ).listen(
            (event) {
              if (!cancellation.cancelled) output.add(event);
            },
            onError: (Object error, StackTrace stack) {
              if (!cancellation.cancelled) output.addError(error, stack);
            },
            onDone: () {
              completed = true;
              unawaited(output.close());
            },
          );
    },
    onCancel: () async {
      cancellation.cancel();
      if (completed) return;
      // async* 在等待下一块数据时不会自行取消内层流，显式唤醒当前文件。
      await cancellation.currentFile?.cancel();
      // mkdir 接口无法中断；已发出的创建请求收尾后才释放源目录权限。
      try {
        await cancellation.currentDirectoryWrite;
      } on Object {
        // 取消中的目录写入错误不再变更任务状态。
      }
      await subscription?.cancel();
    },
  );
  return output.stream;
}

Stream<SftpTransferProgress> _transferDirectory({
  required SshEngineSession engine,
  required LocalFileRepository localFiles,
  required String localPath,
  required String remotePath,
  required bool upload,
  required _DirectoryCancellation cancellation,
  DirectoryConflictResolver? onConflict,
  DirectoryAccessRequest? authorizeLocalDirectory,
}) async* {
  Future<List<LocalFileEntry>> listLocal(String path) async {
    try {
      return await cancellation.wait(localFiles.listDirectory(path));
    } on LocalDirectoryAccessDenied {
      if (authorizeLocalDirectory == null ||
          !await cancellation.wait(authorizeLocalDirectory(path))) {
        rethrow;
      }
      return cancellation.wait(localFiles.listDirectory(path));
    }
  }

  void validateName(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw const SshEngineException('文件传输路径无效');
    }
  }

  final root = _Entry(localPath, remotePath);
  final directories = <_Entry>[root];
  final pending = Queue<_Entry>()..add(root);
  final files = <_Entry>[];
  var total = 0;
  var transferred = 0;
  String sourceOf(_Entry entry) => upload ? entry.localPath : entry.remotePath;
  SftpTransferProgress progress(String path) => SftpTransferProgress(
    transferred: transferred,
    total: total,
    currentPath: path,
  );

  // 扫描时保持可取消；不把目录自身的文件系统大小计入传输字节。
  yield progress(sourceOf(root));
  while (pending.isNotEmpty) {
    final directory = pending.removeFirst();
    final entries = upload
        ? [
            for (final entry in await listLocal(directory.localPath))
              if (!entry.isSymbolicLink || !entry.isDir)
                (name: entry.name, isDir: entry.isDir, size: entry.size),
          ]
        : [
            for (final entry in await cancellation.wait(
              engine.listDir(directory.remotePath),
            ))
              if (entry.name != '.' && entry.name != '..')
                (name: entry.name, isDir: entry.isDir, size: entry.size),
          ];
    for (final entry in entries) {
      validateName(entry.name);
      final child = _Entry(
        localFiles.pathOf(directory.localPath, entry.name),
        p.posix.join(directory.remotePath, entry.name),
        math.max(0, entry.size),
      );
      if (entry.isDir) {
        directories.add(child);
        pending.add(child);
      } else {
        files.add(child);
        total += child.size;
      }
    }
    // 大小扫描结束前保持不定进度，并给取消订阅一个检查点。
    yield SftpTransferProgress(
      transferred: 0,
      total: 0,
      currentPath: sourceOf(root),
    );
  }
  yield progress(sourceOf(root));

  final targetDirectories = <String, Map<String, bool>>{};
  Future<Map<String, bool>> targetEntries(String directory) async {
    if (targetDirectories[directory] case final entries?) return entries;
    final entries = upload
        ? {
            for (final entry in await cancellation.wait(
              engine.listDir(directory),
            ))
              entry.name: entry.isDir,
          }
        : {
            for (final entry in await listLocal(directory))
              entry.name: entry.isDir,
          };
    targetDirectories[directory] = entries;
    return entries;
  }

  for (final directory in directories) {
    final target = upload ? directory.remotePath : directory.localPath;
    final parent = upload
        ? p.posix.dirname(target)
        : localFiles.parentOf(target);
    final name = upload ? p.posix.basename(target) : p.basename(target);
    final entries = await targetEntries(parent);
    yield progress(sourceOf(directory));
    if (entries.containsKey(name)) {
      if (!entries[name]!) {
        throw const SshEngineException('目标文件与目录类型不一致');
      }
    } else {
      if (upload) {
        await cancellation.writeDirectory(() => engine.createDir(target));
      } else {
        try {
          await cancellation.writeDirectory(
            () => localFiles.createDirectory(target),
          );
        } on LocalDirectoryAccessDenied catch (error) {
          if (cancellation.cancelled) throw const DirectoryTransferCancelled();
          if (authorizeLocalDirectory == null ||
              !await cancellation.wait(authorizeLocalDirectory(error.path))) {
            rethrow;
          }
          await cancellation.writeDirectory(
            () => localFiles.createDirectory(target),
          );
        }
      }
      entries[name] = true;
    }
    yield progress(sourceOf(directory));
  }

  for (final file in files) {
    final source = sourceOf(file);
    final target = upload ? file.remotePath : file.localPath;
    final parent = upload
        ? p.posix.dirname(target)
        : localFiles.parentOf(target);
    final name = upload ? p.posix.basename(target) : p.basename(target);
    final entries = await targetEntries(parent);
    yield progress(source);
    if (entries.containsKey(name)) {
      if (entries[name]!) {
        throw const SshEngineException('目标文件与目录类型不一致');
      }
      if (onConflict == null) {
        throw const SshEngineException('目标文件已存在');
      }
      final decision = await cancellation.wait(onConflict(name));
      // 决策返回后先检查取消，避免取消任务仍打开下一份文件。
      yield progress(source);
      if (decision == DirectoryConflictAction.cancel) {
        throw const DirectoryTransferCancelled();
      }
      if (decision == DirectoryConflictAction.skip) {
        total -= file.size;
        yield progress(source);
        continue;
      }
    }
    var fileSize = file.size;
    SftpTransferProgress? last;
    final stream = upload
        ? engine.upload(file.localPath, file.remotePath)
        : engine.download(file.remotePath, file.localPath);
    final current = StreamIterator(stream);
    cancellation.currentFile = current;
    try {
      while (await current.moveNext()) {
        if (cancellation.cancelled) return;
        final event = current.current;
        last = event;
        if (event.total != fileSize) {
          total += event.total - fileSize;
          fileSize = event.total;
        }
        yield SftpTransferProgress(
          transferred: transferred + event.transferred,
          total: total,
          currentPath: source,
        );
      }
    } finally {
      cancellation.currentFile = null;
      // 正常结束/出错时 StreamIterator 已取消其订阅；主动取消的清理
      // 由外层 onCancel 等待，避免再次等待同一个已结束的订阅。
      unawaited(current.cancel());
    }
    if (cancellation.cancelled) return;
    if (last == null || last.transferred < fileSize) {
      throw const SshEngineException('传输未完成，请检查连接后重试');
    }
    transferred += last.transferred;
    entries[name] = false;
    yield progress(source);
  }
}
