import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// DragTargetDetails.offset 是预览左上角，加上抓取偏移后才是鼠标位置。
class TreeDragAnchor {
  TreeDragAnchor({this.onPointer});

  final void Function(TreeDragAnchor anchor, Offset? position)? onPointer;
  Offset offset = Offset.zero;
  bool scrolledSinceMove = false;
}

enum TreeDropPosition { before, inside, after }

/// 保留具体数据类型，避免不同业务树之间接受拖拽。
class AppTreeDraggable<T extends Object> extends StatefulWidget {
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
  final WidgetBuilder preview;

  @override
  State<AppTreeDraggable<T>> createState() => _AppTreeDraggableState<T>();
}

class _AppTreeDraggableState<T extends Object>
    extends State<AppTreeDraggable<T>>
    with AutomaticKeepAliveClientMixin {
  bool _dragging = false;

  @override
  bool get wantKeepAlive => _dragging;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final dragAnchor = widget.dragAnchor;
    return LayoutBuilder(
      builder: (context, constraints) => Draggable<T>(
        data: widget.item,
        maxSimultaneousDrags: 1,
        onDragStarted: () {
          _dragging = true;
          updateKeepAlive();
        },
        onDragEnd: (_) {
          _dragging = false;
          updateKeepAlive();
        },
        dragAnchorStrategy: (draggable, context, position) {
          dragAnchor.scrolledSinceMove = false;
          dragAnchor.offset = childDragAnchorStrategy(
            draggable,
            context,
            position,
          );
          return dragAnchor.offset;
        },
        onDragUpdate: (details) {
          dragAnchor.scrolledSinceMove = false;
          dragAnchor.onPointer?.call(dragAnchor, details.globalPosition);
        },
        onDragCompleted: () => dragAnchor.onPointer?.call(dragAnchor, null),
        onDraggableCanceled: (_, _) =>
            dragAnchor.onPointer?.call(dragAnchor, null),
        feedback: Opacity(
          opacity: AppTheme.treeDragFeedbackOpacity,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.hasTightHeight && constraints.hasBoundedHeight
                ? constraints.maxHeight
                : null,
            child: shadcn.SurfaceCard(
              theme: const shadcn.CardTheme(
                padding: EdgeInsets.zero,
                borderWidth: 0,
              ),
              child: Builder(builder: widget.preview),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: widget.child),
        child: widget.child,
      ),
    );
  }
}

class AppTreeDropTarget<T extends Object> extends StatefulWidget {
  const AppTreeDropTarget({
    required this.isFolder,
    required this.depth,
    required this.dragAnchor,
    required this.canDrop,
    required this.onDrop,
    required this.child,
    this.onHoverInside,
    super.key,
  });

  final bool isFolder;
  final int depth;
  final TreeDragAnchor dragAnchor;
  final bool Function(T item, TreeDropPosition position) canDrop;
  final Future<void> Function(T item, TreeDropPosition position) onDrop;
  final Widget child;
  final VoidCallback? onHoverInside;

  @override
  State<AppTreeDropTarget<T>> createState() => _AppTreeDropTargetState<T>();
}

class _AppTreeDropTargetState<T extends Object>
    extends State<AppTreeDropTarget<T>> {
  TreeDropPosition? _highlight;
  Timer? _expandTimer;

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
    if (highlight == TreeDropPosition.inside && widget.onHoverInside != null) {
      _expandTimer ??= Timer(const Duration(milliseconds: 450), () {
        _expandTimer = null;
        if (mounted &&
            _highlight == TreeDropPosition.inside &&
            !widget.dragAnchor.scrolledSinceMove) {
          widget.onHoverInside?.call();
        }
      });
    } else {
      _cancelExpand();
    }
  }

  void _cancelExpand() {
    _expandTimer?.cancel();
    _expandTimer = null;
  }

  @override
  void dispose() {
    _cancelExpand();
    super.dispose();
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
        _cancelExpand();
        if (_highlight != null) setState(() => _highlight = null);
      },
      onAcceptWithDetails: (details) {
        _cancelExpand();
        final position = _position(details);
        if (!widget.dragAnchor.scrolledSinceMove &&
            widget.canDrop(details.data, position)) {
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
