import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// 仅写入用户选择的位置；Unix 平台在写入敏感内容之前收紧文件权限。
Future<bool> saveExportFile(
  Uint8List bytes,
  String suggestedName, {
  Future<String?> Function(String suggestedName)? selectPath,
}) async {
  final path = selectPath != null
      ? await selectPath(suggestedName)
      : (await getSaveLocation(suggestedName: suggestedName))?.path;
  if (path == null) return false;
  final file = File(path);
  await file.create();
  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) throw const FileSystemException();
  }
  await file.writeAsBytes(bytes, flush: true);
  return true;
}
