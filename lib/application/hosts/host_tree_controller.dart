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

  HostTreeSnapshot get snapshot => HostTreeSnapshot(
    folders: folders.folders.toList(),
    hosts: hosts.hosts.toList(),
  );

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
