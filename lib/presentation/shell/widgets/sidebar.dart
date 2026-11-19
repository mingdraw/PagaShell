import 'dart:async';

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
import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../application/settings/settings_controller.dart';
import '../../../domain/entities/folder.dart';
import '../../../domain/entities/host.dart';
import '../../../domain/entities/host_tree_item.dart';
import '../../../domain/entities/identity.dart';
import '../../../domain/entities/identity_tree_item.dart';
import '../../../domain/entities/sidebar_state.dart';
import '../../../domain/services/host_tree.dart';
import '../../../domain/services/identity_tree.dart';
import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_list_row.dart';
import '../../components/app_menu.dart';
import '../../components/app_tree_drag.dart';
import '../../components/app_tree_expansion.dart';
import '../../folders/folder_dialogs.dart';
import '../../hosts/host_edit_dialog.dart';
import '../../identities/identity_edit_dialog.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import '../connect_flow.dart';
import 'host_tree_drag.dart';
import 'identity_tree_drag.dart';

part 'sidebar_search.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  late final _settings = Get.find<SettingsController>();
  late final _hostController = Get.find<HostController>();
  late final TextEditingController _searchController = TextEditingController(
    text: _hostController.searchQuery.value,
  );
  final _searchFocus = FocusNode();
  final _searchScroll = ScrollController();
  final _searchIndex = 0.obs;
  bool get _hostsExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.services);
  bool get _identitiesExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.identities);
  bool get _gatewaysExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.gateways);
  final _dragAnchor = TreeDragAnchor();
  final _identityDragAnchor = TreeDragAnchor();
  final _gatewayDragAnchor = TreeDragAnchor();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _searchScroll.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    _updateSearch('');
    _searchFocus.requestFocus();
  }

  void _updateSearch(String value) {
    _searchIndex.value = 0;
    if (_searchScroll.hasClients) _searchScroll.jumpTo(0);
    _hostController.searchQuery.value = value;
  }

  void _moveSearchSelection(int direction) {
    final hits = _searchSidebar(_searchTerms(_searchController.text));
    if (hits.isEmpty) return;
    final index =
        (_searchIndex.value.clamp(0, hits.length - 1) + direction) %
        hits.length;
    _searchIndex.value = index;
    if (!_searchScroll.hasClients) return;
    final position = _searchScroll.position;
    final top = hits[index].slot * AppTheme.sidebarSearchResultHeight;
    final bottom = top + AppTheme.sidebarSearchResultHeight;
    final visibleBottom = position.pixels + position.viewportDimension;
    final offset = top < position.pixels
        ? top
        : bottom > visibleBottom
        ? bottom - position.viewportDimension
        : position.pixels;
    position.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
  }

  void _openSearchSelection() {
    final hits = _searchSidebar(_searchTerms(_searchController.text));
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
    final hits = _searchSidebar(terms);
    if (hits.isEmpty) return _EmptyHint(text: '没有匹配的结果'.tr);
    final selected = _searchIndex.value.clamp(0, hits.length - 1);
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
      itemExtent: AppTheme.sidebarSearchResultHeight,
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
        final display = (
          terms: terms,
          detail: hit.detail,
          selected: index == selected,
        );
        if (hit.identity case final identity?) {
          return _IdentityTile(
            key: ValueKey(IdentityTreeItem.identity(identity.id)),
            identity: identity,
            depth: 0,
            dragAnchor: _identityDragAnchor,
            search: display,
          );
        }
        final host = hit.host!;
        final gateway = hit.section == SidebarSection.gateways;
        return _HostTile(
          key: gateway
              ? ValueKey('search-gateway-${host.id}')
              : ValueKey(HostTreeItem.host(host.id)),
          host: host,
          depth: 0,
          dragAnchor: gateway ? _gatewayDragAnchor : _dragAnchor,
          reorderable: false,
          gateway: gateway,
          search: display,
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
    final hostController = Get.find<HostController>();
    final folderController = Get.find<FolderController>();
    final treeController = Get.find<HostTreeController>();
    final identityController = Get.find<IdentityController>();
    final identityFolders = Get.find<IdentityFolderController>();
    final identityTree = Get.find<IdentityTreeController>();

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
              // Obx 的依赖追踪只在此 builder 同步执行期间生效，因此分组内容
              // 必须在这里以同步函数完成（而非下沉到子 Widget 的 build），
              // 否则新增服务/文件夹/凭证、展开折叠都不会触发重建。
              child: Obx(() {
                final terms = _searchTerms(hostController.searchQuery.value);
                if (terms.isNotEmpty) return _searchResults(terms);
                // 服务、凭证、网关使用独立目录空间。
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    // 组头兼作放置目标：把文件夹或服务移到根级末尾。
                    DragTarget<HostTreeItem>(
                      onWillAcceptWithDetails: (d) => treeController.canMove(
                        d.data,
                        const HostTreePlacement(parentId: null),
                      ),
                      onAcceptWithDetails: (d) {
                        _setGroupExpanded(SidebarSection.services, true);
                        unawaited(
                          moveHostTreeItem(
                            treeController,
                            d.data,
                            const HostTreePlacement(parentId: null),
                          ),
                        );
                      },
                      builder: (context, candidates, _) => ColoredBox(
                        color: candidates.isEmpty
                            ? shadcn.Colors.transparent
                            : shadcn.Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.12),
                        child: _SectionHeader(
                          icon: AppIcons.server,
                          title: '服务'.tr,
                          count: hostController.hosts.length,
                          expanded: _hostsExpanded,
                          onToggle: () => _setGroupExpanded(
                            SidebarSection.services,
                            !_hostsExpanded,
                          ),
                          menuSemanticLabel: '服务组操作'.tr,
                          actions: [
                            ('new-host', '新建服务'.tr),
                            ('new-folder', '新建文件夹'.tr),
                          ],
                          onAction: _onHostsGroupAction,
                        ),
                      ),
                    ),
                    AppTreeExpansion(
                      key: const ValueKey('sidebar-services-expansion'),
                      expanded: _hostsExpanded,
                      children: _hostsExpanded
                          ? _hostGroupChildren(
                              folderController,
                              treeController.snapshot,
                              _dragAnchor,
                            )
                          : const [],
                    ),
                    const SizedBox(height: 4),
                    DragTarget<IdentityTreeItem>(
                      onWillAcceptWithDetails: (d) => identityTree.canMove(
                        d.data,
                        const IdentityTreePlacement(parentId: null),
                      ),
                      onAcceptWithDetails: (d) {
                        _setGroupExpanded(SidebarSection.identities, true);
                        unawaited(
                          moveIdentityTreeItem(
                            identityTree,
                            d.data,
                            const IdentityTreePlacement(parentId: null),
                          ),
                        );
                      },
                      builder: (context, candidates, _) => ColoredBox(
                        color: candidates.isEmpty
                            ? shadcn.Colors.transparent
                            : shadcn.Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.12),
                        child: _SectionHeader(
                          icon: AppIcons.bookKey,
                          title: '凭证'.tr,
                          count: identityController.identities.length,
                          expanded: _identitiesExpanded,
                          onToggle: () => _setGroupExpanded(
                            SidebarSection.identities,
                            !_identitiesExpanded,
                          ),
                          menuSemanticLabel: '凭证组操作'.tr,
                          actions: [
                            ('new-identity', '新建凭证'.tr),
                            ('new-folder', '新建文件夹'.tr),
                          ],
                          onAction: _onIdentitiesGroupAction,
                        ),
                      ),
                    ),
                    AppTreeExpansion(
                      key: const ValueKey('sidebar-identities-expansion'),
                      expanded: _identitiesExpanded,
                      children: _identitiesExpanded
                          ? _identityGroupChildren(
                              identityFolders,
                              identityTree.snapshot,
                              _identityDragAnchor,
                            )
                          : const [],
                    ),
                    if (Get.isRegistered<GatewayTreeController>()) ...[
                      const SizedBox(height: 4),
                      _gatewayHeader(),
                      AppTreeExpansion(
                        key: const ValueKey('sidebar-gateways-expansion'),
                        expanded: _gatewaysExpanded,
                        children: [
                          if (_gatewaysExpanded) ...[
                            ..._buildTreeNodes(
                              Get.find<GatewayFolderController>(),
                              Get.find<GatewayTreeController>().snapshot,
                              null,
                              1,
                              _gatewayDragAnchor,
                              gateway: true,
                            ),
                            if (Get.find<GatewayController>().hosts.isEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  28,
                                  8,
                                  12,
                                  8,
                                ),
                                child: Text(
                                  '还没有网关，可通过组菜单新建'.tr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: shadcn.Theme.of(context)
                                        .colorScheme
                                        .mutedForeground,
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ],
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gatewayHeader() {
    final tree = Get.find<GatewayTreeController>();
    return DragTarget<HostTreeItem>(
      onWillAcceptWithDetails: (d) =>
          tree.canMove(d.data, const HostTreePlacement(parentId: null)),
      onAcceptWithDetails: (d) {
        _setGroupExpanded(SidebarSection.gateways, true);
        unawaited(
          moveHostTreeItem(
            tree,
            d.data,
            const HostTreePlacement(parentId: null),
          ),
        );
      },
      builder: (context, candidates, _) => ColoredBox(
        color: candidates.isEmpty
            ? shadcn.Colors.transparent
            : shadcn.Theme.of(context).colorScheme.primary
                  .withValues(alpha: 0.12),
        child: _SectionHeader(
          icon: AppIcons.network,
          title: '网关'.tr,
          count: tree.hosts.hosts.length,
          expanded: _gatewaysExpanded,
          onToggle: () =>
              _setGroupExpanded(SidebarSection.gateways, !_gatewaysExpanded),
          menuSemanticLabel: '网关组操作'.tr,
          actions: [('new-gateway', '新建网关'.tr), ('new-folder', '新建文件夹'.tr)],
          onAction: (action) {
            if (action == 'new-gateway') {
              showHostEditDialog(context, gateway: true);
            }
            if (action == 'new-folder') {
              showFolderDialog(
                context,
                folderController: Get.find<GatewayFolderController>(),
              );
            }
          },
        ),
      ),
    );
  }
}

/// 「服务」组内容：文件夹与服务共用同级顺序。
///
/// 必须在 Obx builder 内同步调用，读到的 hosts/folders/expanded 才会被追踪。
List<Widget> _hostGroupChildren(
  FolderController folderController,
  HostTreeSnapshot snapshot,
  TreeDragAnchor dragAnchor,
) {
  if (snapshot.childCount(null) == 0) {
    return const [_EmptyHostsHint()];
  }
  return _buildTreeNodes(folderController, snapshot, null, 1, dragAnchor);
}

/// 「凭证」组内容。同样必须在 Obx builder 内同步调用。
List<Widget> _identityGroupChildren(
  IdentityFolderController folders,
  IdentityTreeSnapshot snapshot,
  TreeDragAnchor dragAnchor,
) {
  if (snapshot.childCount(null) == 0) return const [_EmptyIdentitiesHint()];
  return _buildIdentityTreeNodes(folders, snapshot, null, 1, dragAnchor);
}

List<Widget> _buildIdentityTreeNodes(
  IdentityFolderController folders,
  IdentityTreeSnapshot snapshot,
  String? parentId,
  int depth,
  TreeDragAnchor dragAnchor,
) {
  final widgets = <Widget>[];
  for (final node in snapshot.childrenOf(parentId)) {
    if (node.isFolder) {
      final folder = node.folder!;
      final expanded = folders.isExpanded(folder.id);
      widgets.add(
        _FolderTile(
          key: ValueKey(node.item),
          folder: folder,
          containsIdentities: true,
          depth: depth,
          expanded: expanded,
          childCount: snapshot.childCount(folder.id),
          dragAnchor: dragAnchor,
        ),
      );
      widgets.add(
        AppTreeExpansion(
          key: ValueKey('identity-folder-children:${folder.id}'),
          expanded: expanded,
          children: expanded
              ? _buildIdentityTreeNodes(
                  folders,
                  snapshot,
                  folder.id,
                  depth + 1,
                  dragAnchor,
                )
              : const [],
        ),
      );
    } else {
      widgets.add(
        _IdentityTile(
          key: ValueKey(node.item),
          identity: node.identity!,
          depth: depth,
          dragAnchor: dragAnchor,
        ),
      );
    }
  }
  return widgets;
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

List<Widget> _buildTreeNodes(
  FolderController folderController,
  HostTreeSnapshot snapshot,
  String? parentId,
  int depth,
  TreeDragAnchor dragAnchor, {
  bool gateway = false,
}) {
  final widgets = <Widget>[];
  for (final node in snapshot.childrenOf(parentId)) {
    if (node.isFolder) {
      final folder = node.folder!;
      final expanded = folderController.isExpanded(folder.id);
      widgets.add(
        _FolderTile(
          key: ValueKey(node.item),
          folder: folder,
          containsGateways: gateway,
          depth: depth,
          expanded: expanded,
          childCount: snapshot.childCount(folder.id),
          dragAnchor: dragAnchor,
        ),
      );
      widgets.add(
        AppTreeExpansion(
          key: ValueKey('host-folder-children:${folder.id}'),
          expanded: expanded,
          children: expanded
              ? _buildTreeNodes(
                  folderController,
                  snapshot,
                  folder.id,
                  depth + 1,
                  dragAnchor,
                  gateway: gateway,
                )
              : const [],
        ),
      );
    } else {
      widgets.add(
        _HostTile(
          key: ValueKey(node.item),
          host: node.host!,
          gateway: gateway,
          depth: depth,
          dragAnchor: dragAnchor,
        ),
      );
    }
  }
  return widgets;
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
    super.key,
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
    if (action != 'delete') controller.expanded.add(folder.id);
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
        dragAnchor: dragAnchor,
        child: IdentityTreeDraggable(
          item: identityItem,
          dragAnchor: dragAnchor,
          preview: row,
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
      dragAnchor: dragAnchor,
      child: HostTreeDraggable(
        item: item,
        dragAnchor: dragAnchor,
        preview: row,
        child: tile,
      ),
    );
  }
}

List<(String, String)> get _folderActions => [
  ('new-host', '在此新建服务'.tr),
  ('new-subfolder', '新建文件夹'.tr),
  ('rename', '重命名'.tr),
  ('delete', '删除'.tr),
];

List<(String, String)> get _identityFolderActions => [
  ('new-identity', '在此新建凭证'.tr),
  ('new-subfolder', '新建文件夹'.tr),
  ('rename', '重命名'.tr),
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

class _EmptyHostsHint extends StatelessWidget {
  const _EmptyHostsHint();

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
      child: Text(
        '还没有服务'.tr,
        style: TextStyle(fontSize: 12, color: colors.mutedForeground),
      ),
    );
  }
}

class _EmptyIdentitiesHint extends StatelessWidget {
  const _EmptyIdentitiesHint();

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
      child: Text(
        '还没有凭证，连接服务时可保存'.tr,
        style: TextStyle(fontSize: 12, color: colors.mutedForeground),
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

/// 凭证项：双击编辑；悬停显示类型与编辑按钮；右键菜单：编辑、复制、删除。
class _IdentityTile extends StatefulWidget {
  const _IdentityTile({
    required this.identity,
    required this.depth,
    required this.dragAnchor,
    this.search,
    super.key,
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
      case 'delete':
        await confirmDeleteIdentity(context, widget.identity);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final identity = widget.identity;
    final actions = [('edit', '编辑'.tr), ('copy', '复制'.tr), ('delete', '删除'.tr)];

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

    final previewRow = buildRow(showQuickActions: false);
    final row = buildRow(showQuickActions: _hovered);
    final item = IdentityTreeItem.identity(identity.id);
    final draggable = IdentityTreeDraggable(
      item: item,
      dragAnchor: widget.dragAnchor,
      preview: previewRow,
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
/// - 右键菜单：新建会话（同一服务多开）、文件传输、编辑、复制、删除。
class _HostTile extends StatefulWidget {
  const _HostTile({
    required this.host,
    required this.depth,
    required this.dragAnchor,
    this.reorderable = true,
    this.gateway = false,
    this.search,
    super.key,
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
    final previewRow = buildRow(showQuickActions: false, showStatus: false);
    final Widget row = Get.isRegistered<SessionController>()
        ? Obx(() {
            final controller = Get.find<SessionController>();
            final active = controller.activeSession;
            bool belongsToTile(Session session) =>
                session.host.id == host.id &&
                widget.gateway ==
                    (session.kind == SessionKind.portForward ||
                        session.kind == SessionKind.dynamicProxy);
            final current = active != null && belongsToTile(active);
            final hostSessions = controller.sessions
                .where(
                  (s) =>
                      belongsToTile(s) &&
                      s.kind != SessionKind.containerTerminal &&
                      s.phase != SessionPhase.closed,
                )
                .toList();
            final statusColor = hostSessions.isEmpty
                ? null
                : hostSessions.any((s) => s.phase == SessionPhase.ready)
                ? StatusColors.ready
                : hostSessions.any((s) => s.phase.isBusy)
                ? StatusColors.connecting
                : StatusColors.failed;
            return buildRow(
              showQuickActions: _hovered,
              showStatus: true,
              active: current,
              statusColor: statusColor,
              sessionCount: hostSessions.length,
            );
          })
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
      preview: previewRow,
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
