import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/presentation/components/export_file.dart';

void main() {
  late Directory directory;
  final marker = Uint8List.fromList(utf8.encode('public-export-test-marker'));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pagashell-export-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('取消系统保存选择不创建文件', () async {
    expect(
      await saveExportFile(marker, 'test.key', selectPath: (_) async => null),
      isFalse,
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('写入选定文件并保留内容，Unix 文件仅当前用户可读写', () async {
    final file = File('${directory.path}/test.key');
    String? suggestion;
    expect(
      await saveExportFile(
        marker,
        'test.key',
        selectPath: (name) async {
          suggestion = name;
          return file.path;
        },
      ),
      isTrue,
    );
    expect(suggestion, 'test.key');
    expect(await file.readAsBytes(), marker);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
    }
  });

  test('覆盖文件时先收紧 Unix 权限', () async {
    final file = File('${directory.path}/existing.key');
    await file.writeAsString('old-public-marker');
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['644', file.path]);
      expect(result.exitCode, 0);
    }
    expect(
      await saveExportFile(
        marker,
        'existing.key',
        selectPath: (_) async => file.path,
      ),
      isTrue,
    );
    expect(await file.readAsBytes(), marker);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
    }
  });

  test('文件写入失败时不返回成功', () async {
    await expectLater(
      saveExportFile(
        marker,
        'test.key',
        selectPath: (_) async => directory.path,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
