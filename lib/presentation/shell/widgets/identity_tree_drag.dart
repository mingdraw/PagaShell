import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/identities/identity_tree_controller.dart';
import '../../../domain/entities/identity_tree_item.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import 'host_tree_drag.dart';

/// 与服务树共用预览宽度和抓取偏移，独立的数据类型防止跨组拖入。
class IdentityTreeDraggable extends StatelessWidget {
  const IdentityTreeDraggable({
    required this.item,
    required this.dragAnchor,
    required this.child,
    required this.preview,
    super.key,
  });
  final IdentityTreeItem item;
  final HostTreeDragAnchor dragAnchor;
  final Widget child;
  final Widget preview;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Draggable<IdentityTreeItem>(
      data: item,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: (draggable, context, position) {
        dragAnchor.offset = childDragAnchorStrategy(
          draggable,
          context,
          position,
        );
        return dragAnchor.offset;
      },
      feedback: Opacity(
        opacity: AppTheme.treeDragFeedbackOpacity,
        child: SizedBox(
          width: constraints.maxWidth,
          child: shadcn.SurfaceCard(
            theme: const shadcn.CardTheme(
              padding: EdgeInsets.zero,
              borderWidth: 0,
            ),
            child: preview,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    ),
  );
}

class IdentityTreeDropTarget extends StatefulWidget {
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
  final HostTreeDragAnchor dragAnchor;
  final Widget child;

  @override
  State<IdentityTreeDropTarget> createState() => _IdentityTreeDropTargetState();
}

class _IdentityTreeDropTargetState extends State<IdentityTreeDropTarget> {
  IdentityTreePlacement? _highlight;

  IdentityTreePlacement _placement(
    DragTargetDetails<IdentityTreeItem> details,
  ) {
    final box = context.findRenderObject()! as RenderBox;
    final pointer = box.globalToLocal(
      details.offset + widget.dragAnchor.offset,
    );
    final fraction = pointer.dy / box.size.height;
    if (widget.item.isFolder &&
        fraction >= AppTheme.treeFolderDropEdgeFraction &&
        fraction <= 1 - AppTheme.treeFolderDropEdgeFraction) {
      return IdentityTreePlacement(parentId: widget.item.id);
    }
    return IdentityTreePlacement(
      parentId: widget.parentId,
      anchor: widget.item,
      after: fraction >= 0.5,
    );
  }

  void _update(DragTargetDetails<IdentityTreeItem> details) {
    final placement = _placement(details);
    final highlight = widget.tree.canMove(details.data, placement)
        ? placement
        : null;
    if (_highlight != highlight) setState(() => _highlight = highlight);
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final highlight = _highlight;
    return DragTarget<IdentityTreeItem>(
      onWillAcceptWithDetails: (details) {
        _update(details);
        return [
          IdentityTreePlacement(parentId: widget.parentId, anchor: widget.item),
          IdentityTreePlacement(
            parentId: widget.parentId,
            anchor: widget.item,
            after: true,
          ),
          if (widget.item.isFolder)
            IdentityTreePlacement(parentId: widget.item.id),
        ].any((placement) => widget.tree.canMove(details.data, placement));
      },
      onMove: _update,
      onLeave: (_) {
        if (_highlight != null) setState(() => _highlight = null);
      },
      onAcceptWithDetails: (details) {
        final placement = _placement(details);
        if (widget.tree.canMove(details.data, placement)) {
          unawaited(moveIdentityTreeItem(widget.tree, details.data, placement));
        }
        setState(() => _highlight = null);
      },
      builder: (context, _, _) => Stack(
        children: [
          widget.child,
          if (highlight != null && highlight.anchor == null)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: colors.primary.withValues(alpha: 0.12),
                ),
              ),
            ),
          if (highlight != null && highlight.anchor != null)
            Positioned(
              left: 8.0 + widget.depth * 14,
              right: 4,
              top: highlight.after ? null : 0,
              bottom: highlight.after ? 0 : null,
              height: AppTheme.treeDropGuideHeight,
              child: IgnorePointer(child: ColoredBox(color: colors.primary)),
            ),
        ],
      ),
    );
  }
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
