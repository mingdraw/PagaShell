/// 本地目录条目。路径使用宿主平台格式，文件名不包含目录分隔符。
class LocalFileEntry {
  const LocalFileEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    this.modified,
    this.isHidden = false,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
  final bool isHidden;
}
