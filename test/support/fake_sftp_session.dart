import 'dart:async';

import 'package:pagashell/domain/ssh/ssh_engine.dart';

import 'in_memory_local_file_repository.dart';

class FakeSftpSession implements SshEngineSession {
  FakeSftpSession({this.localFiles});

  final InMemoryLocalFileRepository? localFiles;
  final Map<String, List<SftpDirEntry>> fs = {
    '/home/test': [
      const SftpDirEntry(name: 'logs', isDir: true, size: 0),
      const SftpDirEntry(name: 'readme.txt', isDir: false, size: 42),
    ],
    '/home/test/logs': [
      const SftpDirEntry(name: 'app.log', isDir: false, size: 2048),
    ],
  };
  final List<String> removed = [];
  final List<(String, String)> uploads = [];
  final List<(String, String)> downloads = [];
  final StreamController<String> _shell = StreamController<String>();
  int closes = 0;
  int shellStarts = 0;

  @override
  Future<String> canonicalize(String path) async => '/home/test';

  @override
  Future<List<SftpDirEntry>> listDir(String path) async =>
      List.of(fs[path] ?? (throw const SshEngineException('目录不存在')));

  @override
  Future<void> createDir(String path) async {
    fs[path] = [];
    final cut = path.lastIndexOf('/');
    fs[cut == 0 ? '/' : path.substring(0, cut)]?.add(
      SftpDirEntry(name: path.substring(cut + 1), isDir: true, size: 0),
    );
  }

  @override
  Future<void> remove(String path, {required bool isDir}) async {
    removed.add(path);
    final cut = path.lastIndexOf('/');
    fs[cut == 0 ? '/' : path.substring(0, cut)]?.removeWhere(
      (entry) => entry.name == path.substring(cut + 1),
    );
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Stream<SftpTransferProgress> download(
    String remotePath,
    String localPath,
  ) async* {
    downloads.add((remotePath, localPath));
    localFiles?.putFile(localPath, 42);
    yield const SftpTransferProgress(transferred: 42, total: 42);
  }

  @override
  Stream<SftpTransferProgress> upload(
    String localPath,
    String remotePath,
  ) async* {
    uploads.add((localPath, remotePath));
    final cut = remotePath.lastIndexOf('/');
    final parent = fs[cut == 0 ? '/' : remotePath.substring(0, cut)]!;
    final name = remotePath.substring(cut + 1);
    parent.removeWhere((entry) => entry.name == name);
    parent.add(SftpDirEntry(name: name, isDir: false, size: 100));
    yield const SftpTransferProgress(transferred: 100, total: 100);
  }

  @override
  Stream<String> startShell({required int cols, required int rows}) {
    shellStarts++;
    return _shell.stream;
  }

  @override
  void write(String data) {}

  @override
  void resizeTerminal(int width, int height) {}

  @override
  Future<void> close() async {
    closes++;
    unawaited(_shell.close());
  }
}
