import '../entities/folder.dart';
import '../entities/host.dart';
import '../entities/host_tree_item.dart';

/// 统一的同级排序与移动规则，不依赖界面或存储实现。
class HostTreeSnapshot {
  HostTreeSnapshot({required List<Folder> folders, required List<Host> hosts})
    : _folders = {for (final folder in folders) folder.id: folder},
      _nodes = {
        for (final folder in folders)
          HostTreeItem.folder(folder.id): HostTreeNode.folder(folder),
        for (final host in hosts)
          HostTreeItem.host(host.id): HostTreeNode.host(host),
      };

  final Map<String, Folder> _folders;
  final Map<HostTreeItem, HostTreeNode> _nodes;

  List<HostTreeNode> childrenOf(String? parentId) {
    final children = _nodes.values
        .where((node) => node.parentId == parentId)
        .toList();
    children.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      if (order != 0) return order;
      // 旧数据的 sortOrder 均为 0 时保持原来的文件夹/名称顺序。
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

  void _validateParent(HostTreeItem item, String? parentId) {
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

  void _validateName(HostTreeItem item, String name, String? parentId) {
    if (childrenOf(parentId).any(
      (node) =>
          node.item != item && node.item.kind == item.kind && node.name == name,
    )) {
      final type = item.isFolder ? '文件夹' : '主机';
      throw ArgumentError('同级下已存在同名$type：$name');
    }
  }

  Folder prepareFolder(Folder folder) {
    final item = HostTreeItem.folder(folder.id);
    _validateParent(item, folder.parentId);
    _validateName(item, folder.name, folder.parentId);
    final previous = _nodes[item];
    return folder.copyWith(
      sortOrder: previous?.parentId == folder.parentId && previous != null
          ? previous.sortOrder
          : _nextOrder(folder.parentId),
    );
  }

  Host prepareHost(Host host) {
    final item = HostTreeItem.host(host.id);
    _validateParent(item, host.folderId);
    _validateName(item, host.name, host.folderId);
    final previous = _nodes[item];
    return host.copyWith(
      sortOrder: previous?.parentId == host.folderId && previous != null
          ? previous.sortOrder
          : _nextOrder(host.folderId),
    );
  }

  bool canMove(HostTreeItem item, HostTreePlacement placement) {
    try {
      return !planMove(item, placement).isEmpty;
    } on ArgumentError {
      return false;
    }
  }

  HostTreeChanges planMove(HostTreeItem item, HostTreePlacement placement) {
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
    final hosts = <Host>[];
    void appendPositions(List<HostTreeNode> nodes, String? parentId) {
      for (var order = 0; order < nodes.length; order++) {
        final entry = nodes[order];
        if (entry.parentId == parentId && entry.sortOrder == order) continue;
        if (entry.isFolder) {
          folders.add(
            entry.folder!.copyWith(parentId: parentId, sortOrder: order),
          );
        } else {
          hosts.add(entry.host!.copyWith(folderId: parentId, sortOrder: order));
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
    return HostTreeChanges(folders: folders, hosts: hosts);
  }

  HostTreeChanges planRemoveFolder(String id) {
    final folder = _folders[id];
    if (folder == null) return const HostTreeChanges();
    final parentId = folder.parentId;
    final siblings = childrenOf(parentId)
        .where((node) => node.item != HostTreeItem.folder(id));
    final folderNames = siblings
        .where((node) => node.isFolder)
        .map((node) => node.name)
        .toSet();
    final hostNames = siblings
        .where((node) => node.host != null)
        .map((node) => node.name)
        .toSet();
    var order = _nextOrder(parentId);
    final folders = <Folder>[];
    final hosts = <Host>[];
    for (final child in childrenOf(id)) {
      final names = child.isFolder ? folderNames : hostNames;
      final name = _dedupeName(child.name, names);
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
        hosts.add(
          child.host!.copyWith(
            folderId: parentId,
            name: name,
            sortOrder: order++,
          ),
        );
      }
    }
    return HostTreeChanges(folders: folders, hosts: hosts, removedFolderId: id);
  }
}

class HostTreeChanges {
  const HostTreeChanges({
    this.folders = const [],
    this.hosts = const [],
    this.removedFolderId,
  });

  final List<Folder> folders;
  final List<Host> hosts;
  final String? removedFolderId;
  bool get isEmpty =>
      folders.isEmpty && hosts.isEmpty && removedFolderId == null;
}

String _dedupeName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  var index = 2;
  while (taken.contains('$name ($index)')) {
    index++;
  }
  return '$name ($index)';
}
