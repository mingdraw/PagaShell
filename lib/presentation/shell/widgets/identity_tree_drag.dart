import 'package:flutter/widgets.dart';

import '../../../application/identities/identity_tree_controller.dart';
import '../../../domain/entities/identity_tree_item.dart';
import '../../components/app_tree_drag.dart';
import '../../navigation/app_notice.dart';

class IdentityTreeDraggable extends StatelessWidget {
  const IdentityTreeDraggable({
    required this.item,
    required this.dragAnchor,
    required this.child,
    required this.preview,
    super.key,
  });

  final IdentityTreeItem item;
  final TreeDragAnchor dragAnchor;
  final Widget child;
  final Widget preview;

  @override
  Widget build(BuildContext context) => AppTreeDraggable<IdentityTreeItem>(
    item: item,
    dragAnchor: dragAnchor,
    preview: preview,
    child: child,
  );
}

class IdentityTreeDropTarget extends StatelessWidget {
  const IdentityTreeDropTarget({
    required this.item,
    required this.parentId,
    required this.depth,
    required this.tree,
    required this.dragAnchor,
    required this.child,
    super.key,
  });

  final IdentityTreeItem item;
  final String? parentId;
  final int depth;
  final IdentityTreeController tree;
  final TreeDragAnchor dragAnchor;
  final Widget child;

  IdentityTreePlacement _placement(TreeDropPosition position) =>
      position == TreeDropPosition.inside
      ? IdentityTreePlacement(parentId: item.id)
      : IdentityTreePlacement(
          parentId: parentId,
          anchor: item,
          after: position == TreeDropPosition.after,
        );

  @override
  Widget build(BuildContext context) => AppTreeDropTarget<IdentityTreeItem>(
    isFolder: item.isFolder,
    depth: depth,
    dragAnchor: dragAnchor,
    canDrop: (item, position) => tree.canMove(item, _placement(position)),
    onDrop: (item, position) =>
        moveIdentityTreeItem(tree, item, _placement(position)),
    child: child,
  );
}

Future<void> moveIdentityTreeItem(
  IdentityTreeController tree,
  IdentityTreeItem item,
  IdentityTreePlacement placement,
) async {
  try {
    await tree.move(item, placement);
  } on ArgumentError {
    // 拖拽期间落点变化时放弃操作。
  } on Object {
    AppNotice.error('移动失败，请重试');
  }
}
