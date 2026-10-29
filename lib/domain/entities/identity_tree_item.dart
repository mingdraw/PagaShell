import 'folder.dart';
import 'identity.dart';

/// 凭证树的引用，与主机树的拖放类型和存储空间分离。
class IdentityTreeItem {
  const IdentityTreeItem.folder(this.id) : isFolder = true;
  const IdentityTreeItem.identity(this.id) : isFolder = false;

  final String id;
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is IdentityTreeItem && other.id == id && other.isFolder == isFolder;
  @override
  int get hashCode => Object.hash(id, isFolder);
}

class IdentityTreeNode {
  const IdentityTreeNode.folder(Folder value) : folder = value, identity = null;
  const IdentityTreeNode.identity(Identity value)
    : identity = value,
      folder = null;

  final Folder? folder;
  final Identity? identity;
  bool get isFolder => folder != null;
  IdentityTreeItem get item => isFolder
      ? IdentityTreeItem.folder(folder!.id)
      : IdentityTreeItem.identity(identity!.id);
  String get name => isFolder ? folder!.name : identity!.name;
  String? get parentId => isFolder ? folder!.parentId : identity!.folderId;
  int get sortOrder => isFolder ? folder!.sortOrder : identity!.sortOrder;
}

class IdentityTreePlacement {
  const IdentityTreePlacement({
    required this.parentId,
    this.anchor,
    this.after = false,
  });
  final String? parentId;
  final IdentityTreeItem? anchor;
  final bool after;

  @override
  bool operator ==(Object other) =>
      other is IdentityTreePlacement &&
      other.parentId == parentId &&
      other.anchor == anchor &&
      other.after == after;
  @override
  int get hashCode => Object.hash(parentId, anchor, after);
}
