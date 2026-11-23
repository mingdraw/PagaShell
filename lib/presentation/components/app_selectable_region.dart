import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

/// Shared text selection for a sequence of separately rendered blocks.
class AppSelectableRegion extends StatelessWidget {
  const AppSelectableRegion({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => SelectableRegion(
    selectionControls: shadcn.shadcnTextSelectionHandleControls,
    contextMenuBuilder: (context, state) => shadcn.ContextMenuPopup(
      anchorContext: state.context,
      position: state.contextMenuAnchors.primaryAnchor + const Offset(8, -8),
      children: [
        for (final item in state.contextMenuButtonItems)
          if (item.type == ContextMenuButtonType.copy ||
              item.type == ContextMenuButtonType.selectAll)
            shadcn.MenuButton(
              onPressed: (_) => item.onPressed?.call(),
              child: Text(
                (item.type == ContextMenuButtonType.copy ? '复制' : '全选').tr,
              ),
            ),
      ],
    ),
    child: AppBlockSelection(child: child),
  );
}

/// Use inside a scrollable's selection handler to preserve block boundaries.
class AppBlockSelection extends StatefulWidget {
  const AppBlockSelection({required this.child, super.key});

  final Widget child;

  @override
  State<AppBlockSelection> createState() => _AppBlockSelectionState();
}

class _AppBlockSelectionState extends State<AppBlockSelection> {
  final _selection = _BlockSelectionDelegate();

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _selection, child: widget.child);

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }
}

class _BlockSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    // Flutter's default joins separate text widgets with no separator.
    final blocks = [
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final content?
            when content.plainText.isNotEmpty)
          content.plainText,
    ];
    return blocks.isEmpty
        ? null
        : SelectedContent(plainText: blocks.join('\n'));
  }
}
