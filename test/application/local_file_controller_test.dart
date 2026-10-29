import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/sftp/local_file_controller.dart';
import 'package:pagashell/domain/entities/local_file_entry.dart';
import 'package:pagashell/domain/repositories/local_file_repository.dart';

import '../support/in_memory_local_file_repository.dart';

class _DelayedFiles extends InMemoryLocalFileRepository {
  final pending = <String, Completer<List<LocalFileEntry>>>{};

  @override
  Future<List<LocalFileEntry>> listDirectory(String path) =>
      (pending[path] ??= Completer<List<LocalFileEntry>>()).future;
}

void main() {
  test('默认过滤点开头和系统隐藏条目，开关保留原始目录和完整条目', () async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/.hidden.txt', 1);
    files.fs['/local']!.addAll([
      const LocalFileEntry(
        path: '/local/.hidden-folder',
        name: '.hidden-folder',
        isDir: true,
        size: 0,
      ),
      const LocalFileEntry(
        path: '/local/system-hidden.txt',
        name: 'system-hidden.txt',
        isDir: false,
        size: 1,
        isHidden: true,
      ),
    ]);
    final controller = LocalFileController(files: files);
    await controller.navigate('/local');
    expect(controller.entries, hasLength(5));
    expect(controller.visibleEntries.map((entry) => entry.name), [
      'downloads',
      'upload.txt',
    ]);
    controller.showHidden.value = true;
    expect(controller.visibleEntries, hasLength(5));
    await controller.refreshDirectory();
    expect(controller.showHidden.value, isTrue);
    controller.showHidden.value = false;
    expect(controller.visibleEntries, hasLength(2));
    expect(controller.cwd.value, '/local');
    controller.onClose();
  });

  test('本地重命名和删除刷新列表，重名时保留文件并提示错误', () async {
    final files = InMemoryLocalFileRepository()..putFile('/local/other.txt', 2);
    final controller = LocalFileController(files: files);
    await controller.navigate('/local');
    final original = controller.entries.singleWhere(
      (entry) => entry.name == 'upload.txt',
    );
    await controller.rename(original, 'other.txt');
    expect(controller.error.value, '目标位置已存在同名文件或目录');
    expect(files.fs['/local']!.where((entry) => !entry.isDir), hasLength(2));
    await controller.rename(original, 'renamed.txt');
    expect(controller.error.value, isNull);
    final renamed = controller.entries.singleWhere(
      (entry) => entry.name == 'renamed.txt',
    );
    await controller.remove(renamed);
    expect(controller.entries.map((entry) => entry.name), [
      'downloads',
      'other.txt',
    ]);
    controller.onClose();
  });

  test('本地目录优先排列，进入与返回使用仓库路径规则', () async {
    final files = InMemoryLocalFileRepository();
    final controller = LocalFileController(files: files);
    await controller.navigate(files.homeDirectory);
    expect(controller.entries.map((entry) => entry.name), [
      'downloads',
      'upload.txt',
    ]);
    expect(controller.pathOf('upload.txt'), '/local/upload.txt');
    await controller.navigate('/local/downloads');
    expect(controller.entries, isEmpty);
    await controller.up();
    expect(controller.cwd.value, '/local');
    controller.onClose();
  });

  test('读取失败保留当前路径和列表，可刷新恢复', () async {
    final files = InMemoryLocalFileRepository();
    final controller = LocalFileController(files: files);
    await controller.navigate('/local');
    await controller.navigate('/unreadable');
    expect(controller.cwd.value, '/local');
    expect(controller.entries, hasLength(2));
    expect(controller.error.value, '无法读取本地目录，请重试');
    expect(controller.permissionDeniedPath.value, isNull);
    expect(controller.loading.value, isFalse);
    await controller.refreshDirectory();
    expect(controller.error.value, isNull);
    controller.onClose();
  });

  test('权限不足记录待授权目录，保留当前列表，重新读取后清除提示', () async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final controller = LocalFileController(files: files);
    await controller.navigate('/local');
    await controller.navigate('/local/downloads');
    expect(controller.cwd.value, '/local');
    expect(controller.entries, hasLength(2));
    expect(controller.permissionDeniedPath.value, '/local/downloads');
    expect(controller.error.value, '需要授权才能访问此文件夹');
    expect(controller.loading.value, isFalse);
    files.deniedDirectories.clear();
    await controller.navigate('/local/downloads');
    expect(controller.cwd.value, '/local/downloads');
    expect(controller.error.value, isNull);
    expect(controller.permissionDeniedPath.value, isNull);
    controller.onClose();
  });

  test('新导航完成后，旧目录的权限错误不能覆盖当前状态', () async {
    final files = _DelayedFiles();
    final controller = LocalFileController(files: files);
    final first = controller.navigate('/denied');
    final second = controller.navigate('/allowed');
    files.pending['/allowed']!.complete([]);
    await second;
    files.pending['/denied']!.completeError(
      const LocalDirectoryAccessDenied('/denied'),
    );
    await first;
    expect(controller.cwd.value, '/allowed');
    expect(controller.error.value, isNull);
    expect(controller.permissionDeniedPath.value, isNull);
    controller.onClose();
  });

  test('快速跳转时忽略旧目录的迟到结果', () async {
    final files = _DelayedFiles();
    final controller = LocalFileController(files: files);
    final first = controller.navigate('/first');
    final second = controller.navigate('/second');
    files.pending['/second']!.complete([]);
    await second;
    files.pending['/first']!.complete([]);
    await first;
    expect(controller.cwd.value, '/second');
    expect(controller.loading.value, isFalse);
    controller.onClose();
  });

  test('标签关闭后不接收读取结果', () async {
    final files = _DelayedFiles();
    final controller = LocalFileController(files: files);
    final request = controller.navigate('/pending');
    controller.onClose();
    files.pending['/pending']!.complete([]);
    await request;
    expect(controller.cwd.value, isEmpty);
    expect(controller.entries, isEmpty);
  });
}
