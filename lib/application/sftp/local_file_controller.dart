import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/local_file_entry.dart';
import '../../domain/repositories/local_file_repository.dart';

/// 每个文件传输标签独立的本地浏览状态。
class LocalFileController extends GetxController {
  LocalFileController({required this.files});

  final LocalFileRepository files;
  final cwd = ''.obs;
  final entries = <LocalFileEntry>[].obs;
  final loading = true.obs;
  final error = RxnString();
  final permissionDeniedPath = RxnString();
  final showHidden = false.obs;
  int _request = 0;
  bool _disposed = false;
  late final Future<void> initialNavigation;

  /// 系统选择窗口返回时，用于判断是否已有新的目录导航。
  int get navigationRevision => _request;

  List<LocalFileEntry> get visibleEntries => [
    for (final entry in entries)
      if (showHidden.value || (!entry.isHidden && !entry.name.startsWith('.')))
        entry,
  ];

  @override
  void onInit() {
    super.onInit();
    initialNavigation = navigate(files.homeDirectory);
    unawaited(initialNavigation);
  }

  String pathOf(String name) => files.pathOf(cwd.value, name);

  Future<void> refreshDirectory() =>
      navigate(cwd.value.isEmpty ? files.homeDirectory : cwd.value);

  Future<void> up() => navigate(
    cwd.value.isEmpty ? files.homeDirectory : files.parentOf(cwd.value),
  );

  /// 将创建失败交给命名弹窗显示，保持当前目录列表可用。
  Future<void> createDirectory(String name) async {
    if (_disposed) return;
    final directory = cwd.value;
    if (directory.isEmpty) throw StateError('请先打开目标目录');
    final version = navigationRevision;
    await files.createDirectory(
      files.pathOf(directory, name),
      rejectExisting: true,
    );
    if (!_disposed && version == navigationRevision && directory == cwd.value) {
      await refreshDirectory();
    }
  }

  Future<void> rename(LocalFileEntry entry, String newName) =>
      _run(() => files.rename(entry.path, newName, isDir: entry.isDir));

  Future<void> remove(LocalFileEntry entry) =>
      _run(() => files.remove(entry.path, isDir: entry.isDir));

  /// 同一目录批量删除，完成后只刷新一次；失败项仍保留在列表中。
  Future<void> removeMany(List<LocalFileEntry> selected) async {
    if (_disposed || selected.isEmpty) return;
    final directory = cwd.value;
    final revision = navigationRevision;
    bool current() =>
        !_disposed && revision == navigationRevision && cwd.value == directory;
    var failed = false;
    for (final entry in List<LocalFileEntry>.of(selected)) {
      if (!current()) return;
      try {
        await files.remove(entry.path, isDir: entry.isDir);
      } on Object {
        failed = true;
      }
    }
    if (!current()) return;
    await refreshDirectory();
    if (!_disposed &&
        navigationRevision == revision + 1 &&
        cwd.value == directory &&
        error.value == null &&
        failed) {
      error.value = '部分文件删除失败，请重试';
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed) return;
    final directory = cwd.value;
    final revision = navigationRevision;
    try {
      await action();
      if (!_disposed &&
          revision == navigationRevision &&
          directory == cwd.value) {
        await refreshDirectory();
      }
    } on Object catch (e) {
      if (!_disposed &&
          revision == navigationRevision &&
          directory == cwd.value) {
        error.value = e is LocalFileTargetExists
            ? '目标位置已存在同名文件或目录'
            : '本地文件操作失败，请重试';
      }
    }
  }

  Future<void> navigate(String path) async {
    if (_disposed) return;
    final request = ++_request;
    loading.value = true;
    error.value = null;
    permissionDeniedPath.value = null;
    try {
      final result = List<LocalFileEntry>.of(await files.listDirectory(path))
        ..sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.compareTo(b.name);
        });
      if (_disposed || request != _request) return;
      cwd.value = path;
      entries.assignAll(result);
    } on LocalDirectoryAccessDenied {
      if (!_disposed && request == _request) {
        permissionDeniedPath.value = path;
        error.value = '需要授权才能访问此文件夹';
      }
    } on Object {
      if (!_disposed && request == _request) {
        error.value = '无法读取本地目录，请重试';
      }
    } finally {
      if (!_disposed && request == _request) loading.value = false;
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _request++;
    super.onClose();
  }
}
