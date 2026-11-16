import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../domain/entities/local_file_entry.dart';
import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import 'transfer_limiter.dart';

enum DirectoryConflictAction { overwrite, skip, cancel }

typedef DirectoryConflictResolver = Future<DirectoryConflictAction> Function(
  String name,
);
typedef DirectoryAccessRequest = Future<bool> Function(String path);
typedef DirectoryFileScheduler = Stream<SftpTransferProgress> Function(
  Stream<SftpTransferProgress> Function() open,
);

/// 只记录本次目录任务实际启动过的目标，避免重试时跳过其他文件的覆盖确认。
class DirectoryTransferState {
  final Set<String> _started = {};
}

Stream<SftpTransferProgress> openSftpFile({
  required SshEngineSession engine,
  required String localPath,
  required String remotePath,
  required bool upload,
  required bool resume,
}) {
  if (!resume) {
    return upload
        ? engine.upload(localPath, remotePath)
        : engine.download(remotePath, localPath);
  }
  if (engine case final ResumableSftpSession resumable) {
    return upload
        ? resumable.uploadResuming(localPath, remotePath)
        : resumable.downloadResuming(remotePath, localPath);
  }
  return Stream.error(const SshEngineException('当前引擎不支持断点续传，请重新发起传输'));
}

class DirectoryTransferCancelled implements Exception {
  const DirectoryTransferCancelled();
}

class _DirectoryCancellation {
  bool cancelled = false;
  Object? failure;
  StackTrace? failureStack;
  final currentFiles = <StreamIterator<SftpTransferProgress>>{};
  final _fileCancellations =
      <StreamIterator<SftpTransferProgress>, Future<void>>{};
  Future<void>? currentDirectoryWrite;
  final _cancelled = Completer<void>();

  bool get stopped => cancelled || failure != null;

  void _signal() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _signal();
  }

  void fail(Object error, StackTrace stack) {
    if (stopped) return;
    failure = error;
    failureStack = stack;
    _signal();
    unawaited(stopFiles());
  }

  void check() {
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureStack!);
    }
    if (cancelled) throw const DirectoryTransferCancelled();
  }

  Future<void> cancelFile(StreamIterator<SftpTransferProgress> file) {
    if (_fileCancellations[file] case final pending?) return pending;
    // 先登记 Future，避免同步取消引发其他文件收尾时重复取消同一流。
    final completed = Completer<void>();
    _fileCancellations[file] = completed.future;
    unawaited(() async {
      try {
        await file.cancel();
        completed.complete();
      } on Object catch (error, stack) {
        completed.completeError(error, stack);
      }
    }());
    return completed.future;
  }

  Future<void> stopFiles() async {
    await Future.wait([
      for (final file in currentFiles.toList())
        () async {
          try {
            await cancelFile(file);
          } on Object {
            // 关闭剩余传输时保留最初的错误。
          }
        }(),
    ]);
  }

  Future<T> wait<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>((_) {
      check();
      throw const DirectoryTransferCancelled();
    }),
  ]);

  Future<void> writeDirectory(Future<void> Function() write) async {
    check();
    final pending = write();
    currentDirectoryWrite = pending;
    try {
      await pending;
    } finally {
      currentDirectoryWrite = null;
    }
    check();
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
  DirectoryTransferState? state,
  bool resume = false,
  DirectoryFileScheduler? scheduleFile,
  int maxPendingFiles = 12,
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
            state: state,
            resume: resume,
            scheduleFile: scheduleFile,
            maxPendingFiles: maxPendingFiles,
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
      // async* 在等待下一块数据时不会自行取消内层流，显式唤醒全部文件。
      await cancellation.stopFiles();
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
  DirectoryTransferState? state,
  required bool resume,
  DirectoryFileScheduler? scheduleFile,
  required int maxPendingFiles,
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

  Stream<SftpTransferProgress> runFiles() {
    final fallbackLimiter = TransferLimiter(1);
    final DirectoryFileScheduler schedule =
        scheduleFile ?? (open) => fallbackLimiter.schedule(open);
    final workers = <Future<void>>{};
    late final StreamController<SftpTransferProgress> output;
    Future<void>? work;
    var finished = false;

    void emit(String path) {
      if (!cancellation.stopped) output.add(progress(path));
    }

    Future<void> transferOne(
      _Entry file,
      String source,
      String target,
      String name,
      Map<String, bool> entries,
      bool resumeFile,
    ) async {
      var fileSize = file.size;
      var fileTransferred = 0;
      SftpTransferProgress? last;
      final current = StreamIterator(
        schedule(() {
          state?._started.add(target);
          return openSftpFile(
            engine: engine,
            localPath: file.localPath,
            remotePath: file.remotePath,
            upload: upload,
            resume: resumeFile,
          );
        }),
      );
      cancellation.currentFiles.add(current);
      var ended = false;
      try {
        while (await cancellation.wait(current.moveNext())) {
          cancellation.check();
          final event = current.current;
          last = event;
          if (event.total != fileSize) {
            total += event.total - fileSize;
            fileSize = event.total;
          }
          transferred += event.transferred - fileTransferred;
          fileTransferred = event.transferred;
          emit(source);
        }
        ended = true;
        cancellation.check();
        if (last == null || last.transferred < fileSize) {
          throw const SshEngineException('传输未完成，请检查连接后重试');
        }
        entries[name] = false;
        emit(source);
      } on Object catch (error, stack) {
        cancellation.fail(error, stack);
      } finally {
        if (!ended) {
          try {
            await cancellation.cancelFile(current);
          } on Object catch (error, stack) {
            cancellation.fail(error, stack);
          }
        }
        cancellation.currentFiles.remove(current);
        unawaited(cancellation._fileCancellations.remove(current));
      }
    }

    Future<void> run() async {
      try {
        for (final file in files) {
          cancellation.check();
          final source = sourceOf(file);
          final target = upload ? file.remotePath : file.localPath;
          final parent = upload
              ? p.posix.dirname(target)
              : localFiles.parentOf(target);
          final name = upload ? p.posix.basename(target) : p.basename(target);
          final entries = await targetEntries(parent);
          final resumeFile =
              resume && (state?._started.contains(target) ?? false);
          emit(source);
          if (entries.containsKey(name)) {
            if (entries[name]!) {
              throw const SshEngineException('目标文件与目录类型不一致');
            }
            if (!resumeFile) {
              if (onConflict == null) {
                throw const SshEngineException('目标文件已存在');
              }
              final decision = await cancellation.wait(onConflict(name));
              cancellation.check();
              emit(source);
              if (decision == DirectoryConflictAction.cancel) {
                throw const DirectoryTransferCancelled();
              }
              if (decision == DirectoryConflictAction.skip) {
                total -= file.size;
                emit(source);
                continue;
              }
            }
          }
          final worker = transferOne(
            file,
            source,
            target,
            name,
            entries,
            resumeFile,
          );
          workers.add(worker);
          unawaited(worker.whenComplete(() => workers.remove(worker)));
          // 不为超大目录同时创建无界数量的排队流。
          if (workers.length >= maxPendingFiles) {
            await cancellation.wait(Future.any(workers));
          }
        }
      } on Object catch (error, stack) {
        cancellation.fail(error, stack);
      }
      if (cancellation.stopped) await cancellation.stopFiles();
      await Future.wait(workers);
      if (!cancellation.cancelled && cancellation.failure != null) {
        output.addError(cancellation.failure!, cancellation.failureStack);
      }
      finished = true;
      unawaited(output.close());
    }

    output = StreamController<SftpTransferProgress>(
      onListen: () => work = run(),
      onCancel: () async {
        if (finished) return;
        cancellation.cancel();
        await cancellation.stopFiles();
        await work;
      },
    );
    return output.stream;
  }

  yield* runFiles();
}
