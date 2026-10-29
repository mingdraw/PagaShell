import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/hosts/host_tree_controller.dart';
import '../../../domain/entities/host_tree_item.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';

/// DragTargetDetails.offset 是预览左上角，需加上抓取偏移才能得到鼠标位置。
class HostTreeDragAnchor {
  Offset offset = Offset.zero;
}

class HostTreeDraggable extends StatelessWidget {
  const HostTreeDraggable({
    required this.item,
    required this.dragAnchor,
    required this.child,
    required this.preview,
    super.key,
  });

  final HostTreeItem item;
  final HostTreeDragAnchor dragAnchor;
  final Widget child;
  final Widget preview;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Draggable<HostTreeItem>(
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

class HostTreeDropTarget extends StatefulWidget {
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
  final HostTreeDragAnchor dragAnchor;
  final Widget child;

  @override
  State<HostTreeDropTarget> createState() => _HostTreeDropTargetState();
}

class _HostTreeDropTargetState extends State<HostTreeDropTarget> {
  HostTreePlacement? _highlight;

  HostTreePlacement _placement(DragTargetDetails<HostTreeItem> details) {
    final box = context.findRenderObject()! as RenderBox;
    final pointer = box.globalToLocal(
      details.offset + widget.dragAnchor.offset,
    );
    final fraction = pointer.dy / box.size.height;
    if (widget.item.isFolder &&
        fraction >= AppTheme.treeFolderDropEdgeFraction &&
        fraction <= 1 - AppTheme.treeFolderDropEdgeFraction) {
      return HostTreePlacement(parentId: widget.item.id);
    }
    return HostTreePlacement(
      parentId: widget.parentId,
      anchor: widget.item,
      after: fraction >= 0.5,
    );
  }

  void _update(DragTargetDetails<HostTreeItem> details) {
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
    return DragTarget<HostTreeItem>(
      onWillAcceptWithDetails: (details) {
        _update(details);
        // 同一行的边缘与中部是不同落点；移动到另一落点时仍可重新验证。
        return [
          HostTreePlacement(parentId: widget.parentId, anchor: widget.item),
          HostTreePlacement(
            parentId: widget.parentId,
            anchor: widget.item,
            after: true,
          ),
          if (widget.item.isFolder) HostTreePlacement(parentId: widget.item.id),
        ].any((placement) => widget.tree.canMove(details.data, placement));
      },
      onMove: _update,
      onLeave: (_) {
        if (_highlight != null) setState(() => _highlight = null);
      },
      onAcceptWithDetails: (details) {
        final placement = _placement(details);
        if (widget.tree.canMove(details.data, placement)) {
          unawaited(moveHostTreeItem(widget.tree, details.data, placement));
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
