import '../entities/folder.dart';

/// 文件夹存储的抽象接口。
abstract interface class FolderRepository {
  /// 监听全量文件夹列表（含首帧当前值）。
  Stream<List<Folder>> watchAll();

  Future<List<Folder>> getAll();

  Future<void> upsert(Folder folder);

  /// 删除文件夹。其直接子文件夹与主机的归属由上层（FolderController）
  /// 决定如何处理（上移到父级），仓库只负责删除该行。
  Future<void> remove(String id);
}
