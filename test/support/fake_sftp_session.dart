import 'dart:async';

import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import 'fixture_terminal.dart';
import 'in_memory_local_file_repository.dart';

class FakeSftpSession
    implements SshEngineSession, TerminalScreenSource, DockerTerminalSource {
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
  final dockerShellStarts = <DockerTerminalTarget>[];
  Object? dockerShellFailure;

  @override
  Stream<TerminalFrame> startDockerTerminalShell({
    required DockerTerminalTarget target,
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    dockerShellStarts.add(target);
    if (dockerShellFailure case final failure?) {
      return Stream<TerminalFrame>.error(failure);
    }
    return startTerminalShell(cols: cols, rows: rows, scrollback: scrollback);
  }

  @override
  Future<void> acknowledgeTerminalFrame(int frameId) async {}

  @override
  Stream<TerminalFrame> startTerminalShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    shellStarts++;
    return TerminalFrameFixture(
      columns: cols,
      rows: rows,
      scrollback: scrollback,
    ).decode(_shell.stream);
  }

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
    final cut = remotePath.lastIndexOf('/');
    final entry = fs[remotePath.substring(0, cut)]!.firstWhere(
      (entry) => entry.name == remotePath.substring(cut + 1),
    );
    localFiles?.putFile(localPath, entry.size);
    yield SftpTransferProgress(transferred: entry.size, total: entry.size);
  }

  @override
  Stream<SftpTransferProgress> upload(
    String localPath,
    String remotePath,
  ) async* {
    uploads.add((localPath, remotePath));
    final size = localFiles == null
        ? 100
        : (await localFiles!.entryAt(localPath)).size;
    final cut = remotePath.lastIndexOf('/');
    final parent = fs[cut == 0 ? '/' : remotePath.substring(0, cut)]!;
    final name = remotePath.substring(cut + 1);
    parent.removeWhere((entry) => entry.name == name);
    parent.add(SftpDirEntry(name: name, isDir: false, size: size));
    yield SftpTransferProgress(transferred: size, total: size);
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
