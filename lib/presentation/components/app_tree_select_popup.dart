import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

class AppTreeSelectNode {
  const AppTreeSelectNode({
    required this.id,
    required this.child,
    this.isFolder = false,
  });

  final String id;
  final Widget child;
  final bool isFolder;
}

/// 树弹层统一处理递归、展开和键盘操作；业务侧保留筛选与校验。
class AppTreeSelectPopup extends StatelessWidget {
  const AppTreeSelectPopup({
    required this.keyPrefix,
    required this.folderIcon,
    required this.initialExpanded,
    required this.selectedFolderId,
    required this.parentOfFolder,
    required this.childrenOf,
    this.leadingBuilder,
    super.key,
  });

  final String keyPrefix;
  final IconData folderIcon;
  final Iterable<String> initialExpanded;
  final String? selectedFolderId;
  final String? Function(String id) parentOfFolder;
  final Iterable<AppTreeSelectNode> Function(String? parentId) childrenOf;
  final List<Widget> Function()? leadingBuilder;

  @override
  Widget build(BuildContext context) =>
      shadcn.SelectPopup<String>.noVirtualization(
        items: shadcn.SelectItemList(children: [_TreeRows(popup: this)]),
      );
}

/// 状态在选项 delegate 内部，避免 SelectPopup 的缓存影响展开更新。
class _TreeRows extends StatefulWidget {
  const _TreeRows({required this.popup});
  final AppTreeSelectPopup popup;

  @override
  State<_TreeRows> createState() => _TreeRowsState();
}

class _TreeRowsState extends State<_TreeRows> {
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    final popup = widget.popup;
    _expanded = popup.initialExpanded.toSet();
    var parent = popup.selectedFolderId;
    final visited = <String>{};
    while (parent != null && visited.add(parent)) {
      _expanded.add(parent);
      parent = popup.parentOfFolder(parent);
    }
  }

  void _toggle(String id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  List<Widget> _rows(String? parentId, int depth) {
    final popup = widget.popup;
    final rows = <Widget>[];
    for (final node in popup.childrenOf(parentId)) {
      if (node.isFolder) {
        final expanded = _expanded.contains(node.id);
        rows.add(
          _FolderOption(
            key: ValueKey('${popup.keyPrefix}-folder-${node.id}'),
            icon: popup.folderIcon,
            depth: depth,
            expanded: expanded,
            onToggle: () => _toggle(node.id),
            child: node.child,
          ),
        );
        if (expanded) rows.addAll(_rows(node.id, depth + 1));
      } else {
        rows.add(
          shadcn.SelectItemButton<String>(
            key: ValueKey('${popup.keyPrefix}-option-${node.id}'),
            value: node.id,
            child: Padding(
              padding: EdgeInsets.only(left: 18 + depth * 14.0),
              child: node.child,
            ),
          ),
        );
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) => Obx(
    () => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...?widget.popup.leadingBuilder?.call(), ..._rows(null, 0)],
    ),
  );
}

/// 文件夹只展开，不进入 Select 的值选择路径；Enter 与鼠标使用同一操作。
class _FolderOption extends StatelessWidget {
  const _FolderOption({
    required this.child,
    required this.icon,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final Widget child;
  final IconData icon;
  final int depth;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          onToggle();
          return null;
        },
      ),
    },
    child: shadcn.SubFocus(
      builder: (context, focus) => shadcn.WidgetStatesProvider(
        states: {if (focus.isFocused) WidgetState.hovered},
        child: Semantics(
          button: true,
          expanded: expanded,
          child: shadcn.Button(
            style: const shadcn.ButtonStyle.ghost().copyWith(
              padding: (_, _, _) =>
                  EdgeInsets.all(8 * shadcn.Theme.of(context).scaling),
            ),
            disableTransition: true,
            alignment: AlignmentDirectional.centerStart,
            onPressed: onToggle,
            child: Padding(
              padding: EdgeInsets.only(left: depth * 14.0),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? shadcn.LucideIcons.chevronDown
                        : shadcn.LucideIcons.chevronRight,
                    size: 16,
                  ),
                  const SizedBox(width: 2),
                  Icon(icon, size: AppTheme.sidebarIconSize),
                  const SizedBox(width: 6),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
