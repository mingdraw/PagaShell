import '../entities/local_file_entry.dart';

/// 本地文件浏览与平台路径规则，隔离 UI/控制器中的文件系统访问。
abstract interface class LocalFileRepository {
  String get homeDirectory;
  String parentOf(String path);
  String pathOf(String directory, String name);
  Future<LocalFileEntry> entryAt(String path);
  Future<List<LocalFileEntry>> listDirectory(String path);
  Future<void> rename(String path, String newName, {required bool isDir});
  Future<void> remove(String path, {required bool isDir});
}

class LocalFileTargetExists implements Exception {
  const LocalFileTargetExists();
}

/// macOS 目录访问被拒绝，可通过系统文件夹选择窗口请求授权。
class LocalDirectoryAccessDenied implements Exception {
  const LocalDirectoryAccessDenied(this.path);

  final String path;
}
