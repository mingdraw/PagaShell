import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/identity_tree_item.dart';
import '../../domain/repositories/identity_tree_repository.dart';
import '../../domain/services/identity_tree.dart';
import 'identity_controller.dart';
import 'identity_folder_controller.dart';

class IdentityTreeController extends GetxController {
  IdentityTreeController({
    required this.repository,
    required this.folders,
    required this.identities,
  });
  final IdentityTreeRepository repository;
  final IdentityFolderController folders;
  final IdentityController identities;
  // 与 HostTreeController 相同：按列表内容缓存，任何变更清空。
  IdentityTreeSnapshot? _snapshot;
  List<StreamSubscription<Object?>>? _watchers;

  IdentityTreeSnapshot get snapshot {
    // 读取列表让调用方所在的 Obx 订阅它们的变化。
    folders.folders.length;
    identities.identities.length;
    _watchers ??= [
      folders.folders.listen((_) => _snapshot = null),
      identities.identities.listen((_) => _snapshot = null),
    ];
    return _snapshot ??= IdentityTreeSnapshot(
      folders: folders.folders.toList(),
      identities: identities.identities.toList(),
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

  List<IdentityTreeNode> childrenOf(String? parentId) =>
      snapshot.childrenOf(parentId);
  bool canMove(IdentityTreeItem item, IdentityTreePlacement placement) =>
      snapshot.canMove(item, placement);
  Future<void> move(
    IdentityTreeItem item,
    IdentityTreePlacement placement,
  ) async {
    await repository.move(item, placement);
    if (placement.parentId != null) folders.expanded.add(placement.parentId!);
  }
}
