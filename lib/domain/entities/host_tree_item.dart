import 'folder.dart';
import 'host.dart';

enum HostTreeItemKind { folder, host }

/// 服务树中的稳定引用，各类型的 id 分别属于各自命名空间。
class HostTreeItem {
  const HostTreeItem.folder(this.id) : kind = HostTreeItemKind.folder;
  const HostTreeItem.host(this.id) : kind = HostTreeItemKind.host;

  final String id;
  final HostTreeItemKind kind;
  bool get isFolder => kind == HostTreeItemKind.folder;

  @override
  bool operator ==(Object other) =>
      other is HostTreeItem && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);
}

class HostTreeNode {
  const HostTreeNode.folder(Folder value) : folder = value, host = null;
  const HostTreeNode.host(Host value) : host = value, folder = null;

  final Folder? folder;
  final Host? host;

  bool get isFolder => folder != null;
  HostTreeItem get item =>
      isFolder ? HostTreeItem.folder(folder!.id) : HostTreeItem.host(host!.id);
  String get name => folder?.name ?? host!.name;
  String? get parentId => isFolder ? folder!.parentId : host!.folderId;
  int get sortOrder => folder?.sortOrder ?? host!.sortOrder;
}

/// 无锚点时追加到父级末尾；有锚点时插入该同级项之前或之后。
class HostTreePlacement {
  const HostTreePlacement({
    required this.parentId,
    this.anchor,
    this.after = false,
  });

  final String? parentId;
  final HostTreeItem? anchor;
  final bool after;

  @override
  bool operator ==(Object other) =>
      other is HostTreePlacement &&
      other.parentId == parentId &&
      other.anchor == anchor &&
      other.after == after;

  @override
  int get hashCode => Object.hash(parentId, anchor, after);
}
