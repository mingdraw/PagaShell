import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/folders/folder_controller.dart';
import '../../../application/gateways/gateway_controller.dart';
import '../../../application/hosts/host_controller.dart';
import '../../../application/hosts/host_tree_controller.dart';
import '../../../application/identities/identity_controller.dart';
import '../../../application/identities/identity_folder_controller.dart';
import '../../../application/identities/identity_tree_controller.dart';
import '../../../application/session/session.dart' show SessionKind;
import '../../../application/session/session_controller.dart';
import '../../../application/settings/settings_controller.dart';
import '../../../domain/entities/connection_configuration.dart';
import '../../../domain/entities/folder.dart';
import '../../../domain/entities/host.dart';
import '../../../domain/entities/host_tree_item.dart';
import '../../../domain/entities/identity.dart';
import '../../../domain/entities/identity_tree_item.dart';
import '../../../domain/entities/sidebar_state.dart';
import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_indexed_selection.dart';
import '../../components/app_list_row.dart';
import '../../components/app_menu.dart';
import '../../components/app_tree_drag.dart';
import '../../components/app_tree_expansion.dart';
import '../../configuration/configuration_transfer_dialog.dart';
import '../../folders/folder_dialogs.dart';
import '../../hosts/host_edit_dialog.dart';
import '../../identities/identity_edit_dialog.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import '../connect_flow.dart';
import 'host_tree_drag.dart';
import 'identity_tree_drag.dart';

part 'sidebar_search.dart';
part 'sidebar_tree.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  SidebarStateView createState() => SidebarStateView();
}

class SidebarStateView extends State<Sidebar> {
  late final _settings = Get.find<SettingsController>();
  late final _hostController = Get.find<HostController>();
  late final TextEditingController _searchController = TextEditingController(
    text: _hostController.searchQuery.value,
  );
  final _searchFocus = FocusNode();
  final _searchScroll = ScrollController();
  final _treeScroll = ScrollController();
  final _treeViewport = GlobalKey();
  final _searchIndex = ValueNotifier(0);
  List<_SidebarSearchHit> _searchHits = const [];
  String _searchHitsQuery = '';
  late final _dragAnchor = TreeDragAnchor(onPointer: _treeDragMoved);
  late final _identityDragAnchor = TreeDragAnchor(onPointer: _treeDragMoved);
  late final _gatewayDragAnchor = TreeDragAnchor(onPointer: _treeDragMoved);
  Timer? _dragScrollTimer;
  Offset? _dragPoint;
  TreeDragAnchor? _activeDrag;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _searchIndex.dispose();
    _searchScroll.dispose();
    _dragScrollTimer?.cancel();
    _treeScroll.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    _updateSearch('');
    _searchFocus.requestFocus();
  }

  void focusSearch() => _searchFocus.requestFocus();

  double get _searchResultHeight {
    final scale = MediaQuery.textScalerOf(context);
    return AppTheme.sidebarSearchResultHeight +
        math.max(0.0, scale.scale(13) - 13) +
        math.max(0.0, scale.scale(11) - 11);
  }

  void _treeDragMoved(TreeDragAnchor anchor, Offset? point) {
    if (!mounted) return;
    if (point != null) {
      _activeDrag = anchor;
      _dragPoint = point;
      _dragScrollTimer ??= Timer.periodic(const Duration(milliseconds: 30), (
        _,
      ) {
        final viewport = _treeViewport.currentContext?.findRenderObject();
        final dragPoint = _dragPoint;
        if (viewport is! RenderBox ||
            !viewport.hasSize ||
            dragPoint == null ||
            !_treeScroll.hasClients) {
          return;
        }
        final local = viewport.globalToLocal(dragPoint);
        if (!(Offset.zero & viewport.size).contains(local)) return;
        const edge = 28.0;
        final direction = local.dy < edge
            ? -1
            : local.dy > viewport.size.height - edge
            ? 1
            : 0;
        if (direction == 0) return;
        final position = _treeScroll.position;
        final next = (position.pixels + direction * 10).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (position.pixels != next) {
          _activeDrag?.scrolledSinceMove = true;
          position.jumpTo(next);
        }
      });
    } else if (identical(_activeDrag, anchor)) {
      _activeDrag = null;
      _dragPoint = null;
      _dragScrollTimer?.cancel();
      _dragScrollTimer = null;
    }
  }

  void _updateSearch(String value) {
    _searchIndex.value = 0;
    if (_searchScroll.hasClients) _searchScroll.jumpTo(0);
    _hostController.searchQuery.value = value;
  }

  void _moveSearchSelection(int direction) {
    final hits = _searchHits;
    if (hits.isEmpty) return;
    final index =
        (_searchIndex.value.clamp(0, hits.length - 1) + direction) %
        hits.length;
    _searchIndex.value = index;
    if (!_searchScroll.hasClients) return;
    final position = _searchScroll.position;
    final top = hits[index].slot * _searchResultHeight;
    final bottom = top + _searchResultHeight;
    final visibleBottom = position.pixels + position.viewportDimension;
    final offset = top < position.pixels
        ? top
        : bottom > visibleBottom
        ? bottom - position.viewportDimension
        : position.pixels;
    position.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
  }

  void _openSearchSelection() {
    final query = _searchController.text;
    // A key event can arrive before the rebuild for a text change.
    final hits = query == _searchHitsQuery
        ? _searchHits
        : _searchSidebar(_searchTerms(query));
    if (hits.isEmpty) return;
    final hit = hits[_searchIndex.value.clamp(0, hits.length - 1)];
    if (hit.identity case final identity?) {
      unawaited(showIdentityEditDialog(context, identity: identity));
    } else if (hit.host case final host?) {
      if (hit.section == SidebarSection.gateways) {
        unawaited(showHostEditDialog(context, host: host, gateway: true));
      } else {
        unawaited(connectToHost(context, host));
      }
    }
  }

  Widget _searchResults(List<String> terms) {
    final hits = _searchHits = _searchSidebar(terms);
    if (hits.isEmpty) return _EmptyHint(text: '没有匹配的结果'.tr);
    final headingBySlot = <int, SidebarSection>{};
    final rowBySlot = <int, int>{};
    SidebarSection? section;
    for (var i = 0; i < hits.length; i++) {
      final hit = hits[i];
      if (hit.section != section) {
        section = hit.section;
        headingBySlot[hit.slot - 1] = section;
      }
      rowBySlot[hit.slot] = i;
    }
    return ListView.builder(
      key: const ValueKey('sidebar-search-results'),
      controller: _searchScroll,
      padding: EdgeInsets.zero,
      itemCount: hits.last.slot + 1,
      itemExtent: _searchResultHeight,
      itemBuilder: (_, slot) {
        final heading = headingBySlot[slot];
        if (heading != null) {
          final label = switch (heading) {
            SidebarSection.services => '服务',
            SidebarSection.identities => '凭证',
            SidebarSection.gateways => '网关',
          };
          return Padding(
            key: ValueKey('sidebar-search-${heading.name}'),
            padding: const EdgeInsets.fromLTRB(14, 0, 4, 5),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                label.tr,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: shadcn.Theme.of(context).colorScheme.mutedForeground,
                ),
              ),
            ),
          );
        }
        final index = rowBySlot[slot]!;
        final hit = hits[index];
        final key = ValueKey((hit.section, hit.identity?.id ?? hit.host!.id));
        return AppIndexedSelection(
          key: key,
          selection: _searchIndex,
          index: index,
          itemCount: hits.length,
          builder: (_, selected) {
            final display = (
              terms: terms,
              detail: hit.detail,
              selected: selected,
            );
            if (hit.identity case final identity?) {
              return _IdentityTile(
                identity: identity,
                depth: 0,
                dragAnchor: _identityDragAnchor,
                search: display,
              );
            }
            final gateway = hit.section == SidebarSection.gateways;
            return _HostTile(
              host: hit.host!,
              depth: 0,
              dragAnchor: gateway ? _gatewayDragAnchor : _dragAnchor,
              reorderable: false,
              gateway: gateway,
              search: display,
            );
          },
        );
      },
    );
  }

  void _handleSearchEscape() {
    if (_searchController.text.isNotEmpty) {
      _clearSearch();
    } else {
      _searchFocus.unfocus();
    }
  }

  void _setGroupExpanded(SidebarSection section, bool expanded) {
    unawaited(
      _settings.setSidebarSectionExpanded(section, expanded).catchError((
        Object _,
      ) {
        if (mounted) AppNotice.error('保存失败，请重试'.tr);
      }),
    );
  }

  void _onHostsGroupAction(String action) {
    switch (action) {
      case 'new-host':
        showHostEditDialog(context);
      case 'new-folder':
        showFolderDialog(context);
    }
  }

  void _onIdentitiesGroupAction(String action) {
    switch (action) {
      case 'new-identity':
        showIdentityEditDialog(context);
      case 'new-folder':
        showFolderDialog(
          context,
          folderController: Get.find<IdentityFolderController>(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.sidebar(context),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _searchController,
                builder: (context, value, _) => CallbackShortcuts(
                  bindings: {
                    if (value.composing.isCollapsed)
                      const SingleActivator(LogicalKeyboardKey.escape):
                          _handleSearchEscape,
                    if (value.composing.isCollapsed &&
                        value.text.trim().isNotEmpty) ...{
                      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                          _moveSearchSelection(1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                          _moveSearchSelection(-1),
                      const SingleActivator(LogicalKeyboardKey.enter):
                          _openSearchSelection,
                      const SingleActivator(LogicalKeyboardKey.numpadEnter):
                          _openSearchSelection,
                    },
                  },
                  child: shadcn.TextField(
                    key: const ValueKey('sidebar-search'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: _updateSearch,
                    borderRadius: AppTheme.sidebarSearchRadius,
                    filled: true,
                    padding: AppTheme.sidebarSearchPadding,
                    style: const TextStyle(
                      fontSize: AppTheme.sidebarSearchFontSize,
                    ),
                    hintText: '搜索服务、凭证或网关'.tr,
                    placeholder: Text('搜索服务、凭证或网关'.tr),
                    features: [
                      const shadcn.InputFeature.leading(
                        AppIcon(
                          AppIcons.search,
                          size: AppTheme.sidebarSearchIconSize,
                        ),
                      ),
                      if (value.text.isNotEmpty)
                        shadcn.InputFeature.trailing(
                          SizedBox.square(
                            dimension: 18,
                            child: AppIconButton.text(
                              key: const ValueKey('sidebar-search-clear'),
                              semanticLabel: '清空搜索'.tr,
                              tooltip: '清空搜索'.tr,
                              density: shadcn.ButtonDensity.compact,
                              onPressed: _clearSearch,
                              icon: const AppIcon(AppIcons.x, size: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Obx(() {
                final query = _hostController.searchQuery.value;
                final terms = _searchTerms(query);
                _searchHitsQuery = query;
                if (terms.isNotEmpty) return _searchResults(terms);
                _searchHits = const [];
                return _tree();
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内置根组的组头：仅支持折叠与「新建」类操作，不提供重命名/删除。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.menuSemanticLabel,
    required this.actions,
    required this.onAction,
  });

  final AppIcons icon;
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final String menuSemanticLabel;

  /// (action 值, 菜单文案) 列表，按钮菜单与右键菜单共用。
  final List<(String, String)> actions;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return shadcn.ContextMenu(
      items: appMenuItems(actions, onAction),
      child: AppSurfaceAction(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 4),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                AppTreeChevron(expanded: expanded),
                const SizedBox(width: 2),
                AppIcon(
                  icon,
                  size: AppTheme.sidebarIconSize,
                  color: colors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                shadcn.OutlineBadge(
                  child: Text('$count', style: const TextStyle(fontSize: 10)),
                ),
                AppMenuButton<String>(
                  icon: const AppIcon(AppIcons.plus, size: 16),
                  semanticLabel: menuSemanticLabel,
                  onSelected: onAction,
                  items: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.childCount,
    required this.dragAnchor,
    this.containsIdentities = false,
    this.containsGateways = false,
  });

  final Folder folder;
  final int depth;
  final bool expanded;
  final int childCount;
  final TreeDragAnchor dragAnchor;
  final bool containsIdentities;
  final bool containsGateways;

  Future<void> _onAction(BuildContext context, String action) async {
    final controller = containsIdentities
        ? Get.find<IdentityFolderController>()
        : containsGateways
        ? Get.find<GatewayFolderController>()
        : Get.find<FolderController>();
    if (!context.mounted) return;
    int children() => containsIdentities
        ? Get.find<IdentityTreeController>().snapshot.childCount(folder.id)
        : (containsGateways
                  ? Get.find<GatewayTreeController>()
                  : Get.find<HostTreeController>())
              .snapshot
              .childCount(folder.id);
    final before = children();
    switch (action) {
      case 'new-host':
      case 'new-gateway':
        await showHostEditDialog(
          context,
          initialFolderId: folder.id,
          gateway: containsGateways,
        );
      case 'new-identity':
        await showIdentityEditDialog(context, initialFolderId: folder.id);
      case 'new-subfolder':
        await showFolderDialog(
          context,
          parentId: folder.id,
          folderController: controller,
        );
      case 'rename':
        await showFolderDialog(
          context,
          folderId: folder.id,
          folderController: controller,
        );
      case 'export':
        await showConfigurationExportDialog(
          scope: containsIdentities
              ? ConfigurationExportScope.identityFolder(folder.id)
              : containsGateways
              ? ConfigurationExportScope.gatewayFolder(folder.id)
              : ConfigurationExportScope.serviceFolder(folder.id),
          targetName: folder.name,
        );
      case 'delete':
        if (context.mounted) {
          await confirmDeleteFolder(
            context,
            folder.id,
            folderController: controller,
            containsIdentities: containsIdentities,
            containsGateways: containsGateways,
          );
        }
    }
    if ((action == 'new-host' ||
            action == 'new-gateway' ||
            action == 'new-identity') &&
        context.mounted &&
        children() > before) {
      controller.expanded.add(folder.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final controller = containsIdentities
        ? Get.find<IdentityFolderController>()
        : containsGateways
        ? Get.find<GatewayFolderController>()
        : Get.find<FolderController>();
    final actions = containsIdentities
        ? _identityFolderActions
        : containsGateways
        ? [
            ('new-gateway', '在此新建网关'.tr),
            ('new-subfolder', '新建文件夹'.tr),
            ('rename', '重命名'.tr),
            ('export', '导出配置'.tr),
            ('delete', '删除'.tr),
          ]
        : _folderActions;
    final item = HostTreeItem.folder(folder.id);
    final row = AppSurfaceAction(
      onTap: () => controller.toggleExpanded(folder.id),
      child: Padding(
        padding: EdgeInsets.only(left: 8.0 + depth * 14, right: 4),
        child: SizedBox(
          height: AppTheme.sidebarItemHeight,
          child: Row(
            children: [
              AppTreeChevron(expanded: expanded),
              const SizedBox(width: 2),
              AppIcon(
                expanded ? AppIcons.folderOpen : AppIcons.folder,
                size: AppTheme.sidebarIconSize,
                color: colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folder.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Text(
                '$childCount',
                style: TextStyle(fontSize: 11, color: colors.mutedForeground),
              ),
              AppMenuButton<String>(
                onSelected: (action) => _onAction(context, action),
                items: actions,
              ),
            ],
          ),
        ),
      ),
    );
    final tile = shadcn.ContextMenu(
      items: appMenuItems(actions, (action) => _onAction(context, action)),
      child: row,
    );
    if (containsIdentities) {
      final identityItem = IdentityTreeItem.folder(folder.id);
      return IdentityTreeDropTarget(
        item: identityItem,
        parentId: folder.parentId,
        depth: depth,
        tree: Get.find<IdentityTreeController>(),
        onHoverInside: expanded
            ? null
            : () => controller.expanded.add(folder.id),
        dragAnchor: dragAnchor,
        child: IdentityTreeDraggable(
          item: identityItem,
          dragAnchor: dragAnchor,
          preview: (_) => row,
          child: tile,
        ),
      );
    }
    return HostTreeDropTarget(
      item: item,
      parentId: folder.parentId,
      depth: depth,
      tree: containsGateways
          ? Get.find<GatewayTreeController>()
          : Get.find<HostTreeController>(),
      onHoverInside: expanded ? null : () => controller.expanded.add(folder.id),
      dragAnchor: dragAnchor,
      child: HostTreeDraggable(
        item: item,
        dragAnchor: dragAnchor,
        preview: (_) => row,
        child: tile,
      ),
    );
  }
}

List<(String, String)> get _folderActions => [
  ('new-host', '在此新建服务'.tr),
  ('new-subfolder', '新建文件夹'.tr),
  ('rename', '重命名'.tr),
  ('export', '导出配置'.tr),
  ('delete', '删除'.tr),
];

List<(String, String)> get _identityFolderActions => [
  ('new-identity', '在此新建凭证'.tr),
  ('new-subfolder', '新建文件夹'.tr),
  ('rename', '重命名'.tr),
  ('export', '导出配置'.tr),
  ('delete', '删除'.tr),
];

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: colors.mutedForeground),
      ),
    );
  }
}

class _SidebarQuickActionButton extends StatelessWidget {
  const _SidebarQuickActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final AppIcons icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 22,
    child: AppIconButton.text(
      semanticLabel: label,
      tooltip: label,
      density: shadcn.ButtonDensity.compact,
      onPressed: onPressed,
      icon: AppIcon(icon, size: 13),
    ),
  );
}

Widget _titleWithLabel(
  BuildContext context,
  Widget title, {
  required String? label,
  required Key labelKey,
}) {
  if (label == null || label.isEmpty) return title;
  final colors = shadcn.Theme.of(context).colorScheme;
  const gap = 6.0;
  return LayoutBuilder(
    builder: (_, constraints) {
      if (constraints.maxWidth <= gap) return title;
      return Row(
        children: [
          Flexible(child: title),
          const SizedBox(width: gap),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (constraints.maxWidth - gap) / 2,
            ),
            child: Text(
              label,
              key: labelKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ),
        ],
      );
    },
  );
}

/// 凭证项：双击编辑；悬停显示类型与编辑按钮；右键菜单：编辑、复制、导出配置、删除。
class _IdentityTile extends StatefulWidget {
  const _IdentityTile({
    required this.identity,
    required this.depth,
    required this.dragAnchor,
    this.search,
  });

  final Identity identity;
  final int depth;
  final TreeDragAnchor dragAnchor;
  final _SearchDisplay? search;

  @override
  State<_IdentityTile> createState() => _IdentityTileState();
}

/// 手动判定双击：不用 GestureDetector.onDoubleTap，避免手势仲裁给单击及行内快捷按钮加 ~300ms 延迟。
class _DoubleTapTracker {
  Timer? _timer;
  bool _pending = false;

  bool hit() {
    if (_pending) {
      _pending = false;
      _timer?.cancel();
      _timer = null;
      return true;
    }
    _pending = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () {
      _pending = false;
    });
    return false;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = false;
  }
}

class _IdentityTileState extends State<_IdentityTile> {
  final _doubleTap = _DoubleTapTracker();
  bool _hovered = false;

  @override
  void dispose() {
    _doubleTap.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_doubleTap.hit()) {
      unawaited(showIdentityEditDialog(context, identity: widget.identity));
    }
  }

  Future<void> _onAction(String action) async {
    switch (action) {
      case 'edit':
        await showIdentityEditDialog(context, identity: widget.identity);
      case 'copy':
        await showIdentityEditDialog(context, copyFrom: widget.identity);
      case 'export':
        await showConfigurationExportDialog(
          scope: ConfigurationExportScope.identity(widget.identity.id),
          targetName: widget.identity.name,
        );
      case 'delete':
        await confirmDeleteIdentity(context, widget.identity);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final identity = widget.identity;
    final actions = [
      ('edit', '编辑'.tr),
      ('copy', '复制'.tr),
      ('export', '导出配置'.tr),
      ('delete', '删除'.tr),
    ];

    final search = widget.search;
    final titleText = _sidebarMatchText(
      identity.name,
      search?.terms ?? const [],
      const TextStyle(fontSize: 13),
    );

    Widget buildRow({required bool showQuickActions}) => AppListRow(
      selected: search?.selected ?? false,
      subtitle: _searchSubtitle(context, search),
      minHeight: AppTheme.sidebarItemHeight,
      contentPadding: EdgeInsets.only(left: 14.0 + widget.depth * 14, right: 4),
      leading: AppIcon(
        AppIcons.fileKey,
        size: AppTheme.sidebarIconSize,
        color: colors.primary,
      ),
      title: _titleWithLabel(
        context,
        titleText,
        label: showQuickActions ? identity.serviceType.label : null,
        labelKey: ValueKey('identity-type-${identity.id}'),
      ),
      trailing: showQuickActions
          ? _SidebarQuickActionButton(
              key: ValueKey('identity-quick-edit-${identity.id}'),
              icon: AppIcons.pencil,
              label: '编辑'.tr,
              onPressed: () => unawaited(
                showIdentityEditDialog(context, identity: identity),
              ),
            )
          : null,
      onTap: _handleTap,
    );

    final row = buildRow(showQuickActions: _hovered);
    final item = IdentityTreeItem.identity(identity.id);
    final draggable = IdentityTreeDraggable(
      item: item,
      dragAnchor: widget.dragAnchor,
      preview: (_) => buildRow(showQuickActions: false),
      child: MouseRegion(
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: shadcn.ContextMenu(
          items: appMenuItems(actions, _onAction),
          child: row,
        ),
      ),
    );
    if (search != null) return draggable;
    return IdentityTreeDropTarget(
      item: item,
      parentId: identity.folderId,
      depth: widget.depth,
      tree: Get.find<IdentityTreeController>(),
      dragAnchor: widget.dragAnchor,
      child: draggable,
    );
  }
}

/// 服务项交互：
/// - 单击：聚焦该服务已有的会话标签（若有），不新建；
/// - 双击：打开该服务的标签——已有则聚焦，没有则发起连接（默认一机一标签）；
/// - 右键菜单：新建会话（同一服务多开）、文件传输、编辑、复制、导出配置、删除。
class _HostTile extends StatefulWidget {
  const _HostTile({
    required this.host,
    required this.depth,
    required this.dragAnchor,
    this.reorderable = true,
    this.gateway = false,
    this.search,
  });

  final Host host;
  final int depth;
  final TreeDragAnchor dragAnchor;
  final bool reorderable;
  final bool gateway;
  final _SearchDisplay? search;

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
  final _doubleTap = _DoubleTapTracker();
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    _doubleTap.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_doubleTap.hit()) {
      if (widget.gateway) {
        unawaited(
          showHostEditDialog(context, host: widget.host, gateway: true),
        );
      } else {
        unawaited(connectToHost(context, widget.host));
      }
    } else if (!widget.gateway) {
      Get.find<SessionController>().focusExisting(
        widget.host.id,
        kind: widget.host.isDesktop
            ? SessionKind.remoteDesktop
            : SessionKind.terminal,
      );
    }
  }

  Future<void> _onMenuAction(String action) async {
    switch (action) {
      case 'new-session':
        await connectToHost(context, widget.host, forceNew: true);
      case 'open-transfer':
        await connectToHost(
          context,
          widget.host,
          kind: SessionKind.fileTransfer,
        );
      case 'port-forward':
        Get.find<SessionController>().openForward(widget.host);
      case 'dynamic-proxy':
        Get.find<SessionController>().openProxy(widget.host);
      case 'edit':
        await showHostEditDialog(
          context,
          host: widget.host,
          gateway: widget.gateway,
        );
      case 'copy':
        await showHostEditDialog(
          context,
          copyFrom: widget.host,
          gateway: widget.gateway,
        );
      case 'export':
        await showConfigurationExportDialog(
          scope: widget.gateway
              ? ConfigurationExportScope.gateway(widget.host.id)
              : ConfigurationExportScope.service(widget.host.id),
          targetName: widget.host.name,
        );
      case 'delete':
        await confirmDeleteHost(context, widget.host, gateway: widget.gateway);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final host = widget.host;
    final actions = [
      if (!widget.gateway) ('new-session', '新建会话'.tr),
      if (!widget.gateway && !host.isDesktop) ('open-transfer', '文件传输'.tr),
      if (widget.gateway) ('port-forward', '端口转发'.tr),
      if (widget.gateway) ('dynamic-proxy', '动态代理'.tr),
      ('edit', '编辑'.tr),
      ('copy', '复制'.tr),
      ('export', '导出配置'.tr),
      ('delete', '删除'.tr),
    ];
    final baseIcon = AppIcon(
      widget.gateway
          ? AppIcons.network
          : AppIcons.forServiceType(host.serviceType),
      size: AppTheme.sidebarIconSize,
      color: host.colorValue != null ? Color(host.colorValue!) : colors.primary,
    );
    final search = widget.search;
    final tags = search == null && !widget.gateway ? host.tags.join(' · ') : '';
    final titleText = _sidebarMatchText(
      host.name,
      search?.terms ?? const [],
      const TextStyle(fontSize: 13),
    );

    Widget buildRow({
      required bool showQuickActions,
      required bool showStatus,
      bool active = false,
      Color? statusColor,
      int sessionCount = 0,
    }) => AppListRow(
      key: showStatus ? ValueKey('sidebar-host-row-${host.id}') : null,
      selected: search?.selected ?? active,
      subtitle: _searchSubtitle(context, search),
      minHeight: AppTheme.sidebarItemHeight,
      contentPadding: EdgeInsets.only(left: 14.0 + widget.depth * 14, right: 4),
      leading: showStatus && statusColor != null
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                baseIcon,
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    key: ValueKey('host-status-dot-${host.id}'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.sidebar(context),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : baseIcon,
      title: _titleWithLabel(
        context,
        titleText,
        label: widget.gateway
            ? (showQuickActions ? host.gatewayType.label : null)
            : (showStatus && (showQuickActions || active || _focused)
                  ? tags
                  : null),
        labelKey: ValueKey(
          widget.gateway
              ? 'gateway-type-${host.id}'
              : 'sidebar-host-tags-${host.id}',
        ),
      ),
      trailing: showQuickActions
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.gateway && !host.isDesktop)
                  _SidebarQuickActionButton(
                    key: ValueKey('host-quick-sftp-${host.id}'),
                    icon: AppIcons.folderOpen,
                    label: '文件传输'.tr,
                    onPressed: () => unawaited(
                      connectToHost(
                        context,
                        host,
                        kind: SessionKind.fileTransfer,
                      ),
                    ),
                  ),
                if (widget.gateway) ...[
                  _SidebarQuickActionButton(
                    key: ValueKey('gateway-quick-forward-${host.id}'),
                    icon: AppIcons.arrowLeftRight,
                    label: '端口转发'.tr,
                    onPressed: () =>
                        Get.find<SessionController>().openForward(host),
                  ),
                  _SidebarQuickActionButton(
                    key: ValueKey('gateway-quick-proxy-${host.id}'),
                    icon: AppIcons.proxy,
                    label: '动态代理'.tr,
                    onPressed: () =>
                        Get.find<SessionController>().openProxy(host),
                  ),
                ],
                _SidebarQuickActionButton(
                  key: ValueKey('host-quick-edit-${host.id}'),
                  icon: AppIcons.pencil,
                  label: '编辑'.tr,
                  onPressed: () => unawaited(
                    showHostEditDialog(
                      context,
                      host: host,
                      gateway: widget.gateway,
                    ),
                  ),
                ),
              ],
            )
          : showStatus && sessionCount > 1
          ? Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '$sessionCount',
                key: ValueKey('host-session-count-${host.id}'),
                style: TextStyle(fontSize: 11, color: colors.mutedForeground),
              ),
            )
          : null,
      onTap: _handleTap,
    );
    final Widget row = Get.isRegistered<SessionController>()
        ? GetBuilder<SessionController>(
            id: SessionController.hostActivityUpdateId(
              host.id,
              gateway: widget.gateway,
            ),
            autoRemove: false,
            builder: (controller) {
              final summary = controller.hostActivity(
                host.id,
                gateway: widget.gateway,
              );
              return buildRow(
                showQuickActions: _hovered,
                showStatus: true,
                active: summary.active,
                sessionCount: summary.count,
                statusColor: summary.count == 0
                    ? null
                    : summary.ready
                    ? StatusColors.ready
                    : summary.connecting
                    ? StatusColors.connecting
                    : StatusColors.failed,
              );
            },
          )
        : buildRow(showQuickActions: _hovered, showStatus: true);
    final tile = MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: shadcn.ContextMenu(
        items: appMenuItems(actions, _onMenuAction),
        child: widget.gateway || search != null
            ? row
            : Focus(
                canRequestFocus: false,
                includeSemantics: false,
                onFocusChange: (focused) => setState(() => _focused = focused),
                child: row,
              ),
      ),
    );

    final item = widget.gateway
        ? HostTreeItem.host(host.id)
        : ServiceTerminalDrag(host.id);
    final draggable = HostTreeDraggable(
      item: item,
      dragAnchor: widget.dragAnchor,
      preview: (_) => buildRow(showQuickActions: false, showStatus: false),
      child: tile,
    );
    if (!widget.reorderable) return draggable;
    return HostTreeDropTarget(
      item: item,
      parentId: host.folderId,
      depth: widget.depth,
      tree: widget.gateway
          ? Get.find<GatewayTreeController>()
          : Get.find<HostTreeController>(),
      dragAnchor: widget.dragAnchor,
      child: draggable,
    );
  }
}
