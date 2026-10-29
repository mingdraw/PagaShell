import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/sftp/sftp_controller.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

SftpDirEntry _file(String name) =>
    SftpDirEntry(name: name, isDir: false, size: 1);
SftpDirEntry _dir(String name) =>
    SftpDirEntry(name: name, isDir: true, size: 0);

class _Session implements SshEngineSession {
  final requests = <String>[];
  final operations = <String>[];
  final pending = <String, Completer<List<SftpDirEntry>>>{};
  List<SftpDirEntry> result = [];
  Object? error;
  bool canonicalizeFails = false;

  @override
  Future<String> canonicalize(String path) async {
    if (canonicalizeFails) throw StateError('server-error');
    return '/home/test';
  }

  @override
  Future<List<SftpDirEntry>> listDir(String path) async {
    requests.add(path);
    final failure = error;
    if (failure != null) throw failure;
    return pending[path]?.future ?? result;
  }

  @override
  Future<void> createDir(String path) async => operations.add('create:$path');
  @override
  Future<void> rename(String oldPath, String newPath) async =>
      operations.add('rename:$oldPath:$newPath');
  @override
  Future<void> remove(String path, {required bool isDir}) async =>
      operations.add('remove:$path:$isDir');
  @override
  Future<void> close() async => operations.add('close');
  @override
  Stream<String> startShell({required int cols, required int rows}) =>
      const Stream.empty();
  @override
  void write(String data) {}
  @override
  void resizeTerminal(int width, int height) {}
  @override
  Stream<SftpTransferProgress> download(String remotePath, String localPath) =>
      const Stream.empty();
  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) =>
      const Stream.empty();
}

void main() {
  late _Session engine;
  late SftpController controller;

  setUp(() {
    engine = _Session();
    controller = SftpController(engine: engine);
  });
  tearDown(() => controller.onClose());

  test('初始化家目录、响应式排序过滤且不修改引擎原集合', () async {
    engine.result = [_file('z'), _dir('b'), _dir('a'), _dir('.'), _dir('..')];
    await controller.initialize();
    expect(controller.cwd.value, '/home/test');
    expect(controller.entries.map((e) => e.name), ['a', 'b', 'z']);
    expect(engine.result.map((e) => e.name), ['z', 'b', 'a', '.', '..']);
    expect(controller.loading.value, isFalse);
    expect(controller.error.value, isNull);
  });

  test('家目录解析失败回退根目录；上级目录不会越过根', () async {
    engine.canonicalizeFails = true;
    await controller.initialize();
    await controller.up();
    expect(engine.requests, ['/']);
    expect(controller.cwd.value, '/');
  });

  test('较早返回的目录请求不能覆盖较新的结果', () async {
    await controller.initialize();
    engine.pending['/home/test/slow'] = Completer();
    engine.pending['/home/test/fast'] = Completer();
    final slow = controller.enter('slow');
    final fast = controller.enter('fast');
    engine.pending['/home/test/fast']!.complete([_file('new')]);
    await fast;
    engine.pending['/home/test/slow']!.complete([_file('old')]);
    await slow;
    expect(controller.cwd.value, '/home/test/fast');
    expect(controller.entries.single.name, 'new');
    expect(controller.loading.value, isFalse);
  });

  test('目录加载失败保留当前路径和内容，可刷新恢复', () async {
    engine.result = [_file('original')];
    await controller.initialize();
    engine.error = const SshEngineException('没有访问权限');
    await controller.enter('denied');
    expect(controller.cwd.value, '/home/test');
    expect(controller.entries.single.name, 'original');
    expect(controller.error.value, '没有访问权限');
    expect(controller.loading.value, isFalse);
    engine.error = null;
    await controller.refreshDirectory();
    expect(controller.error.value, isNull);
  });

  test('文件操作委派同一会话并刷新；关闭控制器不关闭 SSH', () async {
    await controller.initialize();
    await controller.createDir('deploy');
    await controller.rename('old', 'new');
    await controller.remove(_dir('deploy'));
    controller.onClose();
    expect(engine.operations, [
      'create:/home/test/deploy',
      'rename:/home/test/old:/home/test/new',
      'remove:/home/test/deploy:true',
    ]);
    expect(engine.requests, hasLength(4));
  });

  test('面板关闭后忽略在途请求，不再发起浏览或操作', () async {
    await controller.initialize();
    engine.pending['/home/test/later'] = Completer();
    final pending = controller.enter('later');
    controller.onClose();
    engine.pending['/home/test/later']!.complete([_file('late')]);
    await pending;
    await controller.refreshDirectory();
    await controller.createDir('after-close');
    expect(controller.cwd.value, '/home/test');
    expect(controller.entries, isEmpty);
    expect(engine.requests, hasLength(2));
    expect(engine.operations, isEmpty);
  });

  test('未知异常不直接展示服务器或平台错误原文', () async {
    engine.error = StateError('sensitive-server-error');
    await controller.initialize();
    expect(controller.error.value, '无法读取远程目录，请重试');
  });
}
