import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/ssh_engine.dart';

/// 每个文件传输标签独立的远程浏览状态；连接归会话所有。
class SftpController extends GetxController {
  SftpController({required this.engine});

  final SshEngineSession engine;
  final cwd = ''.obs;
  final entries = <SftpDirEntry>[].obs;
  final loading = true.obs;
  final error = RxnString();
  int _request = 0;
  bool _disposed = false;

  @override
  void onInit() {
    super.onInit();
    unawaited(initialize());
  }

  Future<void> initialize() async {
    final request = ++_request;
    String home;
    try {
      home = await engine.canonicalize('.');
    } on Object {
      home = '/';
    }
    if (_disposed || request != _request) return;
    await _load(home);
  }

  String pathOf(String name) => join(cwd.value, name);

  static String join(String directory, String name) =>
      directory == '/' ? '/$name' : '$directory/$name';

  Future<void> refreshDirectory() =>
      cwd.value.isEmpty ? initialize() : _load(cwd.value);

  Future<void> enter(String name) => _load(pathOf(name));

  Future<void> navigate(String path) => _load(path);

  Future<void> up() async {
    final path = cwd.value;
    if (path.isEmpty || path == '/') return;
    final cut = path.lastIndexOf('/');
    await _load(cut <= 0 ? '/' : path.substring(0, cut));
  }

  Future<void> _load(String path) async {
    if (_disposed) return;
    final request = ++_request;
    loading.value = true;
    error.value = null;
    try {
      // 不修改引擎返回的原集合；测试与其他调用者也可能持有它。
      final result = List<SftpDirEntry>.of(await engine.listDir(path))
        ..removeWhere((entry) => entry.name == '.' || entry.name == '..')
        ..sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.compareTo(b.name);
        });
      if (_disposed || request != _request) return;
      cwd.value = path;
      entries.assignAll(result);
    } on Object catch (e) {
      if (_disposed || request != _request) return;
      error.value = e is SshEngineException ? e.message : '无法读取远程目录，请重试';
    } finally {
      if (!_disposed && request == _request) loading.value = false;
    }
  }

  Future<void> createDir(String name) =>
      _run(() => engine.createDir(pathOf(name)));

  Future<void> rename(String oldName, String newName) =>
      _run(() => engine.rename(pathOf(oldName), pathOf(newName)));

  Future<void> remove(SftpDirEntry entry) =>
      _run(() => engine.remove(pathOf(entry.name), isDir: entry.isDir));

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed) return;
    try {
      await action();
      if (!_disposed) await refreshDirectory();
    } on Object catch (e) {
      if (!_disposed) {
        error.value = e is SshEngineException ? e.message : '远程文件操作失败，请重试';
      }
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _request++;
    super.onClose();
  }
}
