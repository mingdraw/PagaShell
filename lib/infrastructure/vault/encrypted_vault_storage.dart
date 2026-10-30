import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../storage/application_directories.dart';

/// 只接受加密后的数据；读、改、写在同一事务内完成。
abstract interface class EncryptedVaultStorage {
  Future<T> transaction<T>(Future<T> Function(VaultTransaction) action);
}

abstract interface class VaultTransaction {
  Future<List<int>?> read();
  Future<void> write(List<int> encrypted);
}

/// 应用支持目录内的保险库，进程内排队、进程间文件锁，替换时不覆盖半成品。
class FileEncryptedVaultStorage implements EncryptedVaultStorage {
  FileEncryptedVaultStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? ApplicationDirectories.vault;

  final Future<Directory> Function() _directory;
  static const filename = 'credentials.vault';
  static final _queues = <String, Future<void>>{};

  @override
  Future<T> transaction<T>(Future<T> Function(VaultTransaction) action) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final directoryPath = await directory.resolveSymbolicLinks();
    final file = File(path.join(directoryPath, filename));
    final previous = _queues[file.path] ?? Future<void>.value();
    final release = Completer<void>();
    _queues[file.path] = release.future;
    await previous;
    RandomAccessFile? lock;
    try {
      lock = await File('${file.path}.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      return await action(_FileVaultTransaction(file));
    } finally {
      try {
        // 关闭文件描述符同时释放进程间的锁。
        await lock?.close();
      } finally {
        release.complete();
        if (identical(_queues[file.path], release.future)) {
          unawaited(_queues.remove(file.path));
        }
      }
    }
  }
}

class _FileVaultTransaction implements VaultTransaction {
  const _FileVaultTransaction(this.file);

  final File file;

  @override
  Future<List<int>?> read() async {
    try {
      return await file.readAsBytes();
    } on FileSystemException catch (error) {
      // 只把不存在视为初次使用；权限或 I/O 失败不得当作空库覆盖。
      if (error.osError?.errorCode == 2 ||
          (Platform.isWindows && error.osError?.errorCode == 3)) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> write(List<int> encrypted) async {
    final temporary = await file.parent.createTemp('.credentials-vault-');
    try {
      final staged = File(path.join(temporary.path, 'vault'));
      await staged.writeAsBytes(encrypted, flush: true);
      // 临时文件与目标同一文件系统；macOS rename 原子替换旧文件。
      await staged.rename(file.path);
    } finally {
      try {
        await temporary.delete(recursive: true);
      } on FileSystemException {
        // 清理临时密文失败不能把已成功的提交报告为失败。
      }
    }
  }
}
