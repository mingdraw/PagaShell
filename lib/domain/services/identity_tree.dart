import '../entities/folder.dart';
import '../entities/identity.dart';
import '../entities/identity_tree_item.dart';

/// 凭证文件夹与凭证共用同级顺序，移动和删除只修改元数据。
class IdentityTreeSnapshot {
  IdentityTreeSnapshot({
    required List<Folder> folders,
    required List<Identity> identities,
  }) : _folders = {for (final folder in folders) folder.id: folder},
       _nodes = {
         for (final folder in folders)
           IdentityTreeItem.folder(folder.id): IdentityTreeNode.folder(folder),
         for (final identity in identities)
           IdentityTreeItem.identity(identity.id): IdentityTreeNode.identity(
             identity,
           ),
       };

  final Map<String, Folder> _folders;
  final Map<IdentityTreeItem, IdentityTreeNode> _nodes;

  List<IdentityTreeNode> childrenOf(String? parentId) {
    final children = _nodes.values
        .where((node) => node.parentId == parentId)
        .toList();
    children.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      if (order != 0) return order;
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      final name = a.name.compareTo(b.name);
      return name != 0 ? name : a.item.id.compareTo(b.item.id);
    });
    return children;
  }

  int _nextOrder(String? parentId) {
    var largest = -1;
    for (final node in childrenOf(parentId)) {
      if (node.sortOrder > largest) largest = node.sortOrder;
    }
    return largest + 1;
  }

  void _validateParent(IdentityTreeItem item, String? parentId) {
    if (parentId != null && !_folders.containsKey(parentId)) {
      throw ArgumentError('目标文件夹不存在');
    }
    if (!item.isFolder) return;
    final visited = <String>{};
    var ancestor = parentId;
    while (ancestor != null) {
      if (ancestor == item.id || !visited.add(ancestor)) {
        throw ArgumentError('文件夹不能移动到自身或子文件夹');
      }
      ancestor = _folders[ancestor]?.parentId;
    }
  }

  void _validateName(IdentityTreeItem item, String name, String? parentId) {
    if (childrenOf(parentId).any(
      (node) =>
          node.item != item &&
          node.isFolder == item.isFolder &&
          node.name == name,
    )) {
      final type = item.isFolder ? '文件夹' : '凭证';
      throw ArgumentError('同级下已存在同名$type：$name');
    }
  }

  Folder prepareFolder(Folder folder) {
    final item = IdentityTreeItem.folder(folder.id);
    _validateParent(item, folder.parentId);
    _validateName(item, folder.name, folder.parentId);
    final previous = _nodes[item];
    return folder.copyWith(
      sortOrder: previous != null && previous.parentId == folder.parentId
          ? previous.sortOrder
          : _nextOrder(folder.parentId),
    );
  }

  Identity prepareIdentity(Identity identity) {
    final item = IdentityTreeItem.identity(identity.id);
    _validateParent(item, identity.folderId);
    _validateName(item, identity.name, identity.folderId);
    final previous = _nodes[item];
    return identity.copyWith(
      sortOrder: previous != null && previous.parentId == identity.folderId
          ? previous.sortOrder
          : _nextOrder(identity.folderId),
    );
  }

  bool canMove(IdentityTreeItem item, IdentityTreePlacement placement) {
    try {
      return !planMove(item, placement).isEmpty;
    } on ArgumentError {
      return false;
    }
  }

  IdentityTreeChanges planMove(
    IdentityTreeItem item,
    IdentityTreePlacement placement,
  ) {
    final node = _nodes[item];
    if (node == null) throw ArgumentError('拖拽项不存在');
    _validateParent(item, placement.parentId);
    _validateName(item, node.name, placement.parentId);
    if (placement.anchor == item) throw ArgumentError('不能放到自身位置');
    final destination = childrenOf(placement.parentId)
      ..removeWhere((entry) => entry.item == item);
    var index = destination.length;
    if (placement.anchor != null) {
      index = destination.indexWhere((entry) => entry.item == placement.anchor);
      if (index < 0) throw ArgumentError('插入位置不存在');
      if (placement.after) index++;
    }
    destination.insert(index, node);
    final folders = <Folder>[];
    final identities = <Identity>[];
    void appendPositions(List<IdentityTreeNode> nodes, String? parentId) {
      for (var order = 0; order < nodes.length; order++) {
        final entry = nodes[order];
        if (entry.parentId == parentId && entry.sortOrder == order) continue;
        if (entry.isFolder) {
          folders.add(
            entry.folder!.copyWith(parentId: parentId, sortOrder: order),
          );
        } else {
          identities.add(
            entry.identity!.copyWith(folderId: parentId, sortOrder: order),
          );
        }
      }
    }

    if (node.parentId != placement.parentId) {
      appendPositions(
        childrenOf(node.parentId)..removeWhere((entry) => entry.item == item),
        node.parentId,
      );
    }
    appendPositions(destination, placement.parentId);
    return IdentityTreeChanges(folders: folders, identities: identities);
  }

  IdentityTreeChanges planRemoveFolder(String id) {
    final folder = _folders[id];
    if (folder == null) return const IdentityTreeChanges();
    final parentId = folder.parentId;
    final siblings = childrenOf(parentId)
        .where((node) => node.item != IdentityTreeItem.folder(id));
    final folderNames = siblings
        .where((node) => node.isFolder)
        .map((node) => node.name)
        .toSet();
    final identityNames = siblings
        .where((node) => !node.isFolder)
        .map((node) => node.name)
        .toSet();
    var order = _nextOrder(parentId);
    final folders = <Folder>[];
    final identities = <Identity>[];
    for (final child in childrenOf(id)) {
      final names = child.isFolder ? folderNames : identityNames;
      var name = child.name;
      var suffix = 2;
      while (names.contains(name)) {
        name = '${child.name} (${suffix++})';
      }
      names.add(name);
      if (child.isFolder) {
        folders.add(
          child.folder!.copyWith(
            parentId: parentId,
            name: name,
            sortOrder: order++,
          ),
        );
      } else {
        identities.add(
          child.identity!.copyWith(
            folderId: parentId,
            name: name,
            sortOrder: order++,
          ),
        );
      }
    }
    return IdentityTreeChanges(
      folders: folders,
      identities: identities,
      removedFolderId: id,
    );
  }
}

class IdentityTreeChanges {
  const IdentityTreeChanges({
    this.folders = const [],
    this.identities = const [],
    this.removedFolderId,
  });
  final List<Folder> folders;
  final List<Identity> identities;
  final String? removedFolderId;
  bool get isEmpty =>
      folders.isEmpty && identities.isEmpty && removedFolderId == null;
}
