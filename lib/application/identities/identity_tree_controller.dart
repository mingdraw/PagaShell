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
  IdentityTreeSnapshot get snapshot => IdentityTreeSnapshot(
    folders: folders.folders.toList(),
    identities: identities.identities.toList(),
  );
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
