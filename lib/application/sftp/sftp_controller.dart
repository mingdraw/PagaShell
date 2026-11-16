import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/ssh_engine.dart';

/// 每个文件传输标签独立的远程浏览状态；连接归会话所有。
class SftpController extends GetxController {
  SftpController({required this.engine, this.reconnect});

  SshEngineSession engine;
  final Future<SshEngineSession> Function()? reconnect;
  final cwd = ''.obs;
  final entries = <SftpDirEntry>[].obs;
  final loading = true.obs;
  final error = RxnString();
  final needsReconnect = false.obs;
  final reconnecting = false.obs;
  int _request = 0;
  bool _disposed = false;

  /// 确认或批量操作期间检查是否发生过目录导航或连接更替。
  int get navigationRevision => _request;

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
    } on Object catch (e) {
      if (_disposed || request != _request) return;
      if (e is SshEngineException && e.isConnectionClosed) {
        _recordError(e, '无法读取远程目录，请重试');
        loading.value = false;
        return;
      }
      home = '/';
    }
    if (_disposed || request != _request) return;
    await _load(home);
  }

  String pathOf(String name) => join(cwd.value, name);

  static String join(String directory, String name) =>
      directory == '/' ? '/$name' : '$directory/$name';

  /// 只有用户主动刷新才尝试重连；传输完成后的后台刷新不发起连接。
  Future<void> refreshDirectory({bool reconnectIfNeeded = true}) async {
    if (_disposed || reconnecting.value) return;
    if (!needsReconnect.value) {
      await (cwd.value.isEmpty ? initialize() : _load(cwd.value));
    }
    if (!_disposed && needsReconnect.value && reconnectIfNeeded) {
      await _reconnect();
    }
  }

  void replaceEngine(SshEngineSession replacement) {
    if (_disposed || identical(engine, replacement)) return;
    _request++;
    engine = replacement;
    needsReconnect.value = false;
    error.value = null;
  }

  Future<void> _reconnect() async {
    final connect = reconnect;
    if (connect == null || reconnecting.value) return;
    reconnecting.value = true;
    loading.value = true;
    error.value = null;
    _request++;
    try {
      final replacement = await connect();
      if (_disposed) return;
      replaceEngine(replacement);
      await (cwd.value.isEmpty ? initialize() : _load(cwd.value));
    } on Object catch (e) {
      if (_disposed) return;
      needsReconnect.value = true;
      _recordError(e, '重新连接失败，请刷新重试');
    } finally {
      if (!_disposed) {
        reconnecting.value = false;
        loading.value = false;
      }
    }
  }

  Future<void> enter(String name) => navigate(pathOf(name));

  Future<void> navigate(String path) async {
    if (needsReconnect.value || reconnecting.value) return;
    await _load(path);
  }

  Future<void> up() async {
    final path = cwd.value;
    if (path.isEmpty || path == '/') return;
    final cut = path.lastIndexOf('/');
    await navigate(cut <= 0 ? '/' : path.substring(0, cut));
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
      _recordError(e, '无法读取远程目录，请重试');
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

  /// 同一连接、同一目录中的批量删除；连接失效时停止后续请求。
  Future<void> removeMany(List<SftpDirEntry> selected) async {
    if (_disposed ||
        needsReconnect.value ||
        reconnecting.value ||
        selected.isEmpty) {
      return;
    }
    final directory = cwd.value;
    final revision = _request;
    final activeEngine = engine;
    bool current() =>
        !_disposed &&
        revision == _request &&
        cwd.value == directory &&
        identical(activeEngine, engine) &&
        !needsReconnect.value &&
        !reconnecting.value;
    final removed = <String>{};
    var failed = false;
    for (final entry in List<SftpDirEntry>.of(selected)) {
      if (!current()) return;
      try {
        if (entry.name.isEmpty ||
            entry.name == '.' ||
            entry.name == '..' ||
            entry.name.contains('/')) {
          throw const SshEngineException('文件传输路径无效');
        }
        await activeEngine.remove(
          join(directory, entry.name),
          isDir: entry.isDir,
        );
        removed.add(entry.name);
      } on Object catch (e) {
        if (!current()) return;
        if (e is SshEngineException && e.isConnectionClosed) {
          // 无法刷新失效连接，先从当前列表移除已确认成功的条目。
          entries.removeWhere((entry) => removed.contains(entry.name));
          _recordError(e, '远程文件操作失败，请重试');
          return;
        }
        failed = true;
      }
    }
    if (!current()) return;
    await refreshDirectory(reconnectIfNeeded: false);
    if (!_disposed &&
        revision + 1 == _request &&
        cwd.value == directory &&
        identical(activeEngine, engine) &&
        error.value == null &&
        failed) {
      error.value = '部分文件删除失败，请重试';
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed || needsReconnect.value || reconnecting.value) return;
    final activeEngine = engine;
    try {
      await action();
      if (!_disposed && identical(activeEngine, engine)) {
        await refreshDirectory(reconnectIfNeeded: false);
      }
    } on Object catch (e) {
      if (!_disposed && identical(activeEngine, engine)) {
        _recordError(e, '远程文件操作失败，请重试');
      }
    }
  }

  void _recordError(Object failure, String fallback) {
    if (failure is SshEngineException) {
      if (failure.isConnectionClosed) {
        needsReconnect.value = true;
        error.value = SshEngineException.connectionClosedMessage;
      } else {
        error.value = failure.message;
      }
    } else {
      error.value = fallback;
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _request++;
    super.onClose();
  }
}
