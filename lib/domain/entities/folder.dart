/// 可嵌套的分组文件夹；主机与凭证使用独立的文件夹仓库。
///
/// Domain 层实体：纯 Dart、不可变。[parentId] 为 null 表示根级文件夹。
class Folder {
  const Folder({
    required this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
  });

  final String id;
  final String name;

  /// 父文件夹 id；null 表示根级。
  final String? parentId;

  final int sortOrder;

  Folder copyWith({String? name, Object? parentId = _unset, int? sortOrder}) {
    return Folder(
      id: id,
      name: name ?? this.name,
      parentId: identical(parentId, _unset)
          ? this.parentId
          : parentId as String?,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  static const _unset = Object();

  @override
  bool operator ==(Object other) => other is Folder && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Folder($id, $name, parent=$parentId)';
}
