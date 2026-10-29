import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/repositories/local_file_repository.dart';
import 'package:pagashell/infrastructure/files/io_local_file_repository.dart';

void main() {
  const files = IoLocalFileRepository();
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('pagashell-local-files-');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('真实本地目录支持文件夹、大小及含特殊字符的文件名', () async {
    final subdirectory = files.pathOf(directory.path, '子目录');
    Directory(subdirectory).createSync();
    const name = '100% + # 中文.txt';
    final path = files.pathOf(directory.path, name);
    File(path).writeAsStringSync('hello');
    final entries = await files.listDirectory(directory.path);
    final file = entries.singleWhere((entry) => !entry.isDir);
    expect(file.name, name);
    expect(file.path, path);
    expect(file.size, 5);
    expect(entries.singleWhere((entry) => entry.isDir).path, subdirectory);
    expect(files.parentOf(subdirectory), directory.path);
  });

  test('下载文件名不能改变目标目录', () {
    for (final name in ['', '.', '..', '../escape', 'child/file']) {
      expect(() => files.pathOf(directory.path, name), throwsArgumentError);
    }
  });

  test('读取拖入文件元数据可区分目录，保留特殊名称并拒绝不存在的源', () async {
    final file = File(files.pathOf(directory.path, '100% + 中文.txt'))
      ..writeAsStringSync('abc');
    final entry = await files.entryAt(file.path);
    expect(entry.path, file.path);
    expect(entry.name, '100% + 中文.txt');
    expect(entry.isDir, isFalse);
    expect(entry.size, 3);
    expect((await files.entryAt(directory.path)).isDir, isTrue);
    await expectLater(
      files.entryAt(files.pathOf(directory.path, 'missing')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('本地重命名文件和目录保留内容，拒绝覆盖和目录穿越', () async {
    final original = File(files.pathOf(directory.path, 'original.txt'))
      ..writeAsStringSync('original');
    final existing = File(files.pathOf(directory.path, 'existing.txt'))
      ..writeAsStringSync('existing');
    await expectLater(
      files.rename(original.path, 'existing.txt', isDir: false),
      throwsA(isA<LocalFileTargetExists>()),
    );
    expect(original.readAsStringSync(), 'original');
    expect(existing.readAsStringSync(), 'existing');
    await expectLater(
      files.rename(original.path, '../escape', isDir: false),
      throwsArgumentError,
    );
    await files.rename(original.path, 'renamed.txt', isDir: false);
    expect(original.existsSync(), isFalse);
    expect(
      File(files.pathOf(directory.path, 'renamed.txt')).readAsStringSync(),
      'original',
    );
    final folder = Directory(files.pathOf(directory.path, 'folder'))
      ..createSync();
    File(files.pathOf(folder.path, 'nested.txt')).writeAsStringSync('nested');
    await files.rename(folder.path, 'renamed-folder', isDir: true);
    expect(folder.existsSync(), isFalse);
    expect(
      File(
        files.pathOf(
          files.pathOf(directory.path, 'renamed-folder'),
          'nested.txt',
        ),
      ).readAsStringSync(),
      'nested',
    );
  });

  test('删除本地文件和目录仅影响指定目标', () async {
    final file = File(files.pathOf(directory.path, 'delete.txt'))
      ..writeAsStringSync('delete');
    final keep = File(files.pathOf(directory.path, 'keep.txt'))
      ..writeAsStringSync('keep');
    final folder = Directory(files.pathOf(directory.path, 'folder'))
      ..createSync();
    File(files.pathOf(folder.path, 'nested.txt')).writeAsStringSync('nested');
    await files.remove(file.path, isDir: false);
    await files.remove(folder.path, isDir: true);
    expect(file.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    expect(keep.readAsStringSync(), 'keep');
  });

  test('点开头的本地文件和目录标记为隐藏，但仓库仍返回用于冲突检测', () async {
    File(files.pathOf(directory.path, '.hidden.txt'))
        .writeAsStringSync('hidden');
    Directory(files.pathOf(directory.path, '.hidden-folder')).createSync();
    File(files.pathOf(directory.path, 'visible.txt'))
        .writeAsStringSync('visible');
    final entries = await files.listDirectory(directory.path);
    expect(
      entries
          .where((entry) => entry.isHidden)
          .map((entry) => entry.name)
          .toSet(),
      {'.hidden.txt', '.hidden-folder'},
    );
    expect(
      entries.singleWhere((entry) => entry.name == 'visible.txt').isHidden,
      isFalse,
    );
  });

  test('Windows 隐藏属性标记为隐藏', () async {
    final file = File(files.pathOf(directory.path, 'hidden.txt'))
      ..writeAsStringSync('hidden');
    final result = await Process.run('attrib', ['+H', file.path]);
    expect(result.exitCode, 0);
    try {
      final entries = await files.listDirectory(directory.path);
      expect(entries.single.isHidden, isTrue);
    } finally {
      await Process.run('attrib', ['-H', file.path]);
    }
  }, skip: !Platform.isWindows);

  test('本地文件条目返回文件系统的更新时间', () async {
    final file = File(files.pathOf(directory.path, 'modified.txt'))
      ..writeAsStringSync('hello')
      ..setLastModifiedSync(DateTime(2025, 1, 2, 3, 4, 5));
    final entries = await files.listDirectory(directory.path);
    expect(entries.single.modified, file.statSync().modified);
    expect(entries.single.modified, isNotNull);
  });

  test('默认用户目录兼容 Windows 与 Linux 的环境路径', () {
    expect(
      IoLocalFileRepository.resolveHomeDirectory({
        'USERPROFILE': r'C:\Users\test',
        'HOME': '/different',
      }, windows: true),
      r'C:\Users\test',
    );
    expect(
      IoLocalFileRepository.resolveHomeDirectory({
        'HOMEDRIVE': 'D:',
        'HOMEPATH': r'\Users\test',
      }, windows: true),
      r'D:\Users\test',
    );
    expect(
      IoLocalFileRepository.resolveHomeDirectory({
        'HOME': '/home/test',
      }, windows: false),
      '/home/test',
    );
  });

  test('注入真实用户目录覆盖 macOS 沙盒 HOME', () {
    const nativeFiles = IoLocalFileRepository(userHomeDirectory: '/Users/test');
    expect(nativeFiles.homeDirectory, '/Users/test');
  });

  test('不存在的目录保留普通文件系统错误', () async {
    await expectLater(
      files.listDirectory(files.pathOf(directory.path, 'missing')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('macOS 权限拒绝转为可授权的目录错误', () async {
    final restricted = Directory(files.pathOf(directory.path, 'restricted'))
      ..createSync();
    final denied = await Process.run('chmod', ['000', restricted.path]);
    expect(denied.exitCode, 0);
    try {
      await expectLater(
        files.listDirectory(restricted.path),
        throwsA(
          isA<LocalDirectoryAccessDenied>().having(
            (error) => error.path,
            'path',
            restricted.path,
          ),
        ),
      );
    } finally {
      await Process.run('chmod', ['700', restricted.path]);
    }
  }, skip: !Platform.isMacOS);
}
