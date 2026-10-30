import 'dart:async';

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
import '../../../domain/ssh/ssh_engine.dart';
import '../../../domain/vault/secret_store.dart';
import '../../components/app_list_row.dart';
import '../../components/app_menu.dart';
import '../../folders/folder_dialogs.dart';
import '../../hosts/host_edit_dialog.dart';
import '../../identities/identity_edit_dialog.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import '../connect_flow.dart';
import 'host_tree_drag.dart';
import 'identity_tree_drag.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  late final _settings = Get.find<SettingsController>();
  bool get _hostsExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.services);
  bool get _identitiesExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.identities);
  bool get _gatewaysExpanded =>
      _settings.sidebarState.value.isSectionExpanded(SidebarSection.gateways);
  final _dragAnchor = HostTreeDragAnchor();
  final _identityDragAnchor = HostTreeDragAnchor();
  final _gatewayDragAnchor = HostTreeDragAnchor();

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
        width: AppTheme.sidebarWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: shadcn.TextField(
                onChanged: (v) => hostController.searchQuery.value = v,
                borderRadius: AppTheme.sidebarSearchRadius,
                filled: true,
                padding: AppTheme.sidebarSearchPadding,
                style: const TextStyle(
                  fontSize: AppTheme.sidebarSearchFontSize,
                ),
                hintText: '搜索服务'.tr,
                placeholder: Text('搜索服务'.tr),
                features: const [
                  shadcn.InputFeature.leading(
                    Icon(
                      shadcn.LucideIcons.search,
                      size: AppTheme.sidebarSearchIconSize,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              // Obx 的依赖追踪只在此 builder 同步执行期间生效，因此分组内容
              // 必须在这里以同步函数完成（而非下沉到子 Widget 的 build），
              // 否则新增服务/文件夹/凭证、展开折叠都不会触发重建。
              child: Obx(() {
                final query = hostController.searchQuery.value.trim();
                if (query.isNotEmpty) {
                  final hosts = hostController.filtered;
                  if (hosts.isEmpty) {
                    return _EmptyHint(text: '没有匹配的服务'.tr);
                  }
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final host in hosts)
                        _HostTile(
                          key: ValueKey(HostTreeItem.host(host.id)),
                          host: host,
                          depth: 0,
                          dragAnchor: _dragAnchor,
                          reorderable: false,
                        ),
                    ],
                  );
                }
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
                          icon: shadcn.LucideIcons.server,
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
                    if (_hostsExpanded)
                      ..._hostGroupChildren(
                        folderController,
                        treeController.snapshot,
                        _dragAnchor,
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
                          icon: shadcn.LucideIcons.bookKey,
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
                    if (_identitiesExpanded)
                      ..._identityGroupChildren(
                        identityFolders,
                        identityTree.snapshot,
                        _identityDragAnchor,
                      ),
                    if (Get.isRegistered<GatewayTreeController>()) ...[
                      const SizedBox(height: 4),
                      _gatewayHeader(),
                      if (_gatewaysExpanded)
                        ..._buildTreeNodes(
                          Get.find<GatewayFolderController>(),
                          Get.find<GatewayTreeController>().snapshot,
                          null,
                          1,
                          _gatewayDragAnchor,
                          gateway: true,
                        ),
                      if (_gatewaysExpanded &&
                          Get.find<GatewayController>().hosts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
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
          icon: shadcn.LucideIcons.network,
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
  HostTreeDragAnchor dragAnchor,
) {
  if (snapshot.childrenOf(null).isEmpty) {
    return const [_EmptyHostsHint()];
  }
  return _buildTreeNodes(folderController, snapshot, null, 1, dragAnchor);
}

/// 「凭证」组内容。同样必须在 Obx builder 内同步调用。
List<Widget> _identityGroupChildren(
  IdentityFolderController folders,
  IdentityTreeSnapshot snapshot,
  HostTreeDragAnchor dragAnchor,
) {
  if (snapshot.childrenOf(null).isEmpty) return const [_EmptyIdentitiesHint()];
  return _buildIdentityTreeNodes(folders, snapshot, null, 1, dragAnchor);
}

List<Widget> _buildIdentityTreeNodes(
  IdentityFolderController folders,
  IdentityTreeSnapshot snapshot,
  String? parentId,
  int depth,
  HostTreeDragAnchor dragAnchor,
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
          childCount: snapshot.childrenOf(folder.id).length,
          dragAnchor: dragAnchor,
        ),
      );
      if (expanded) {
        widgets.addAll(
          _buildIdentityTreeNodes(
            folders,
            snapshot,
            folder.id,
            depth + 1,
            dragAnchor,
          ),
        );
      }
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

  final IconData icon;
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
                Icon(
                  expanded
                      ? shadcn.LucideIcons.chevronDown
                      : shadcn.LucideIcons.chevronRight,
                  size: 16,
                  color: colors.mutedForeground,
                ),
                const SizedBox(width: 2),
                Icon(
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
                  icon: const Icon(shadcn.LucideIcons.plus, size: 16),
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
  HostTreeDragAnchor dragAnchor, {
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
          childCount: snapshot.childrenOf(folder.id).length,
          dragAnchor: dragAnchor,
        ),
      );
      if (expanded) {
        widgets.addAll(
          _buildTreeNodes(
            folderController,
            snapshot,
            folder.id,
            depth + 1,
            dragAnchor,
            gateway: gateway,
          ),
        );
      }
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
  final HostTreeDragAnchor dragAnchor;
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
              Icon(
                expanded
                    ? shadcn.LucideIcons.chevronDown
                    : shadcn.LucideIcons.chevronRight,
                size: 16,
                color: colors.mutedForeground,
              ),
              const SizedBox(width: 2),
              Icon(
                containsIdentities
                    ? shadcn.LucideIcons.folderKey
                    : expanded
                    ? shadcn.LucideIcons.folderOpen
                    : shadcn.LucideIcons.folder,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '还没有服务'.tr,
            style: TextStyle(fontSize: 13, color: colors.mutedForeground),
          ),
          const SizedBox(height: 8),
          shadcn.OutlineButton(
            onPressed: () => showHostEditDialog(context),
            leading: const Icon(shadcn.LucideIcons.plus, size: 14),
            size: shadcn.ButtonSize.small,
            child: Text('新建服务'.tr),
          ),
        ],
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

/// 凭证项：单击编辑；右键菜单：编辑、删除。
class _IdentityTile extends StatelessWidget {
  const _IdentityTile({
    required this.identity,
    required this.depth,
    required this.dragAnchor,
    super.key,
  });

  final Identity identity;
  final int depth;
  final HostTreeDragAnchor dragAnchor;

  Future<void> _onAction(BuildContext context, String action) async {
    switch (action) {
      case 'edit':
        await showIdentityEditDialog(context, identity: identity);
      case 'copy':
        await showIdentityEditDialog(context, copyFrom: identity);
      case 'delete':
        await confirmDeleteIdentity(context, identity);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final actions = [('edit', '编辑'.tr), ('copy', '复制'.tr), ('delete', '删除'.tr)];
    final row = AppListRow(
      minHeight: AppTheme.sidebarItemHeight,
      contentPadding: EdgeInsets.only(left: 14.0 + depth * 14, right: 4),
      leading: Icon(
        shadcn.LucideIcons.fileKey,
        size: AppTheme.sidebarIconSize,
        color: colors.primary,
      ),
      title: Text(
        identity.name,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      onTap: () => showIdentityEditDialog(context, identity: identity),
      subtitle: Text(
        identity.serviceType.label,
        style: TextStyle(fontSize: 11, color: colors.mutedForeground),
      ),
    );
    final item = IdentityTreeItem.identity(identity.id);
    return IdentityTreeDropTarget(
      item: item,
      parentId: identity.folderId,
      depth: depth,
      tree: Get.find<IdentityTreeController>(),
      dragAnchor: dragAnchor,
      child: IdentityTreeDraggable(
        item: item,
        dragAnchor: dragAnchor,
        preview: row,
        child: shadcn.ContextMenu(
          items: appMenuItems(actions, (action) => _onAction(context, action)),
          child: row,
        ),
      ),
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
    super.key,
  });

  final Host host;
  final int depth;
  final HostTreeDragAnchor dragAnchor;
  final bool reorderable;
  final bool gateway;

  @override
  State<_HostTile> createState() => _HostTileState();
}

class _HostTileState extends State<_HostTile> {
  /// 手动判定双击：不用 onDoubleTap，避免手势仲裁给单击加 ~300ms 延迟。
  DateTime? _lastTapAt;

  void _handleTap() {
    if (widget.gateway) {
      showHostEditDialog(context, host: widget.host, gateway: true);
      return;
    }
    final now = DateTime.now();
    final isDoubleTap =
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 300);
    _lastTapAt = now;

    if (isDoubleTap) {
      connectToHost(context, widget.host);
    } else {
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
        try {
          final controller = widget.gateway
              ? Get.find<GatewayController>()
              : Get.find<HostController>();
          await controller.remove(widget.host.id);
        } on SecretStoreException catch (e) {
          if (mounted) {
            AppNotice.error(e.message);
          }
        } on SshEngineException catch (e) {
          if (mounted) AppNotice.error(e.message.tr);
        } on StateError catch (e) {
          if (mounted) AppNotice.error(e.message.toString().tr);
        }
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
    final leading = Icon(
      widget.gateway
          ? shadcn.LucideIcons.network
          : host.isDesktop
          ? shadcn.LucideIcons.monitor
          : shadcn.LucideIcons.fileTerminal,
      size: AppTheme.sidebarIconSize,
      color: host.colorValue != null ? Color(host.colorValue!) : colors.primary,
    );
    final title = Text(
      host.name,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13),
    );
    final row = AppListRow(
      minHeight: AppTheme.sidebarItemHeight,
      contentPadding: EdgeInsets.only(left: 14.0 + widget.depth * 14, right: 4),
      leading: leading,
      title: title,
      onTap: _handleTap,
    );
    final tile = shadcn.ContextMenu(
      items: appMenuItems(actions, _onMenuAction),
      child: row,
    );

    final item = HostTreeItem.host(host.id);
    final draggable = HostTreeDraggable(
      item: item,
      dragAnchor: widget.dragAnchor,
      preview: row,
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
