import 'package:flutter/widgets.dart';

import '../../../application/hosts/host_tree_controller.dart';
import '../../../domain/entities/host_tree_item.dart';
import '../../components/app_tree_drag.dart';
import '../../navigation/app_notice.dart';

class HostTreeDraggable extends StatelessWidget {
  const HostTreeDraggable({
    required this.item,
    required this.dragAnchor,
    required this.child,
    required this.preview,
    super.key,
  });

  final HostTreeItem item;
  final TreeDragAnchor dragAnchor;
  final Widget child;
  final Widget preview;

  @override
  Widget build(BuildContext context) => AppTreeDraggable<HostTreeItem>(
    item: item,
    dragAnchor: dragAnchor,
    preview: preview,
    child: child,
  );
}

class HostTreeDropTarget extends StatelessWidget {
  const HostTreeDropTarget({
    required this.item,
    required this.parentId,
    required this.depth,
    required this.tree,
    required this.dragAnchor,
    required this.child,
    super.key,
  });

  final HostTreeItem item;
  final String? parentId;
  final int depth;
  final HostTreeController tree;
  final TreeDragAnchor dragAnchor;
  final Widget child;

  HostTreePlacement _placement(TreeDropPosition position) =>
      position == TreeDropPosition.inside
      ? HostTreePlacement(parentId: item.id)
      : HostTreePlacement(
          parentId: parentId,
          anchor: item,
          after: position == TreeDropPosition.after,
        );

  @override
  Widget build(BuildContext context) => AppTreeDropTarget<HostTreeItem>(
    isFolder: item.isFolder,
    depth: depth,
    dragAnchor: dragAnchor,
    canDrop: (item, position) => tree.canMove(item, _placement(position)),
    onDrop: (item, position) =>
        moveHostTreeItem(tree, item, _placement(position)),
    child: child,
  );
}

Future<void> moveHostTreeItem(
  HostTreeController tree,
  HostTreeItem item,
  HostTreePlacement placement,
) async {
  try {
    await tree.move(item, placement);
  } on ArgumentError {
    // 目标在拖拽期间被删除、重命名或移动时放弃本次操作。
  } on Object {
    AppNotice.error('移动失败，请重试');
  }
}
