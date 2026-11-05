import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// DragTargetDetails.offset 是预览左上角，加上抓取偏移后才是鼠标位置。
class TreeDragAnchor {
  Offset offset = Offset.zero;
}

enum TreeDropPosition { before, inside, after }

/// 保留具体数据类型，避免不同业务树之间接受拖拽。
class AppTreeDraggable<T extends Object> extends StatelessWidget {
  const AppTreeDraggable({
    required this.item,
    required this.dragAnchor,
    required this.child,
    required this.preview,
    super.key,
  });

  final T item;
  final TreeDragAnchor dragAnchor;
  final Widget child;
  final Widget preview;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Draggable<T>(
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

class AppTreeDropTarget<T extends Object> extends StatefulWidget {
  const AppTreeDropTarget({
    required this.isFolder,
    required this.depth,
    required this.dragAnchor,
    required this.canDrop,
    required this.onDrop,
    required this.child,
    super.key,
  });

  final bool isFolder;
  final int depth;
  final TreeDragAnchor dragAnchor;
  final bool Function(T item, TreeDropPosition position) canDrop;
  final Future<void> Function(T item, TreeDropPosition position) onDrop;
  final Widget child;

  @override
  State<AppTreeDropTarget<T>> createState() => _AppTreeDropTargetState<T>();
}

class _AppTreeDropTargetState<T extends Object>
    extends State<AppTreeDropTarget<T>> {
  TreeDropPosition? _highlight;

  TreeDropPosition _position(DragTargetDetails<T> details) {
    final box = context.findRenderObject()! as RenderBox;
    final pointer = box.globalToLocal(
      details.offset + widget.dragAnchor.offset,
    );
    final fraction = pointer.dy / box.size.height;
    if (widget.isFolder &&
        fraction >= AppTheme.treeFolderDropEdgeFraction &&
        fraction <= 1 - AppTheme.treeFolderDropEdgeFraction) {
      return TreeDropPosition.inside;
    }
    return fraction >= 0.5 ? TreeDropPosition.after : TreeDropPosition.before;
  }

  void _update(DragTargetDetails<T> details) {
    final position = _position(details);
    final highlight = widget.canDrop(details.data, position) ? position : null;
    if (_highlight != highlight) setState(() => _highlight = highlight);
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final highlight = _highlight;
    return DragTarget<T>(
      onWillAcceptWithDetails: (details) {
        _update(details);
        // 同一行的边缘与中部是不同落点，保持可接收以便移动后重新验证。
        return [
          TreeDropPosition.before,
          TreeDropPosition.after,
          if (widget.isFolder) TreeDropPosition.inside,
        ].any((position) => widget.canDrop(details.data, position));
      },
      onMove: _update,
      onLeave: (_) {
        if (_highlight != null) setState(() => _highlight = null);
      },
      onAcceptWithDetails: (details) {
        final position = _position(details);
        if (widget.canDrop(details.data, position)) {
          unawaited(widget.onDrop(details.data, position));
        }
        setState(() => _highlight = null);
      },
      builder: (context, _, _) => Stack(
        children: [
          widget.child,
          if (highlight == TreeDropPosition.inside)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: colors.primary.withValues(alpha: 0.12),
                ),
              ),
            ),
          if (highlight != null && highlight != TreeDropPosition.inside)
            Positioned(
              left: 8.0 + widget.depth * 14,
              right: 4,
              top: highlight == TreeDropPosition.after ? null : 0,
              bottom: highlight == TreeDropPosition.after ? 0 : null,
              height: AppTheme.treeDropGuideHeight,
              child: IgnorePointer(child: ColoredBox(color: colors.primary)),
            ),
        ],
      ),
    );
  }
}
