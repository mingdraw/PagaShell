import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/host_tree_item.dart';
import '../../domain/repositories/host_tree_repository.dart';
import '../../domain/services/host_tree.dart';
import '../folders/folder_controller.dart';
import 'host_controller.dart';

class HostTreeController extends GetxController {
  HostTreeController({
    required this.repository,
    required this.folders,
    required this.hosts,
  });

  final HostTreeRepository repository;
  final FolderController folders;
  final HostController hosts;

  // 快照按列表内容缓存：侧边栏每次构建、拖拽时每次指针移动都会访问，
  // 逐次重建会反复复制两张列表并重排整棵树。列表任何变更都会清空缓存。
  HostTreeSnapshot? _snapshot;
  List<StreamSubscription<Object?>>? _watchers;

  HostTreeSnapshot get snapshot {
    // 读取列表让调用方所在的 Obx 订阅它们的变化。
    folders.folders.length;
    hosts.hosts.length;
    _watchers ??= [
      folders.folders.listen((_) => _snapshot = null),
      hosts.hosts.listen((_) => _snapshot = null),
    ];
    return _snapshot ??= HostTreeSnapshot(
      folders: folders.folders.toList(),
      hosts: hosts.hosts.toList(),
    );
  }

  @override
  void onClose() {
    for (final watcher in _watchers ?? const <StreamSubscription<Object?>>[]) {
      unawaited(watcher.cancel());
    }
    _watchers = null;
    super.onClose();
  }

  List<HostTreeNode> childrenOf(String? parentId) =>
      snapshot.childrenOf(parentId);

  bool canMove(HostTreeItem item, HostTreePlacement placement) =>
      snapshot.canMove(item, placement);

  Future<void> move(HostTreeItem item, HostTreePlacement placement) async {
    await repository.move(item, placement);
    final parentId = placement.parentId;
    if (parentId != null) folders.expanded.add(parentId);
  }
}
