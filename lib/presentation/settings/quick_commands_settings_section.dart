import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/settings/settings_controller.dart';
import '../../domain/terminal/quick_command.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

const _monoCommandStyle = TextStyle(
  fontFamily: 'FiraCode Nerd Font Mono',
  fontFamilyFallback: ['Menlo', 'PingFang SC', 'Microsoft YaHei', 'monospace'],
  fontSize: 12,
  height: 1.35,
);

const _dragFeedbackAnchor = Offset(16, 16);

class _QuickGroupDrag {
  const _QuickGroupDrag(this.groupId);

  final String groupId;
}

class _QuickCommandDrag {
  const _QuickCommandDrag({required this.groupId, required this.commandId});

  final String groupId;
  final String commandId;
}

sealed class _QuickTreeData {
  const _QuickTreeData();
}

final class _GroupTreeData extends _QuickTreeData {
  const _GroupTreeData(this.group);

  final QuickCommandCategory group;
}

final class _CommandTreeData extends _QuickTreeData {
  const _CommandTreeData(this.group, this.command);

  final QuickCommandCategory group;
  final QuickCommand command;
}

final class _EmptyGroupTreeData extends _QuickTreeData {
  const _EmptyGroupTreeData(this.group);

  final QuickCommandCategory group;
}

/// 设置弹窗中的「常用指令」管理页：使用 Tree 组件按分组展开/折叠，支持增删改及拖拽排序。
class QuickCommandsSettingsSection extends StatefulWidget {
  const QuickCommandsSettingsSection({super.key});

  @override
  State<QuickCommandsSettingsSection> createState() =>
      _QuickCommandsSettingsSectionState();
}

class _QuickCommandsSettingsSectionState
    extends State<QuickCommandsSettingsSection> {
  final _collapsedGroupIds = <String>{};
  bool _dialogOpen = false;
  String? _draggingGroupId;
  String? _draggingCommandId;

  SettingsController get _settings => Get.find<SettingsController>();

  bool _isExpanded(String groupId) => !_collapsedGroupIds.contains(groupId);

  void _setGroupExpanded(String groupId, bool expanded) {
    setState(() {
      if (expanded) {
        _collapsedGroupIds.remove(groupId);
      } else {
        _collapsedGroupIds.add(groupId);
      }
    });
  }

  void _toggleGroupExpanded(String groupId) =>
      _setGroupExpanded(groupId, !_isExpanded(groupId));

  void _toggleAll(List<QuickCommandCategory> groups) {
    final anyExpanded = groups.any((group) => _isExpanded(group.id));
    setState(() {
      if (anyExpanded) {
        _collapsedGroupIds.addAll(groups.map((group) => group.id));
      } else {
        _collapsedGroupIds.clear();
      }
    });
  }

  Future<T?> _openDialog<T>(Widget dialog) async {
    if (_dialogOpen) return null;
    _dialogOpen = true;
    try {
      return await AppNavigation.dialog<T>(dialog);
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _addGroup() async {
    final existingTitles = [
      for (final group in _settings.customQuickCommandGroups) group.title,
    ];
    final title = await _openDialog<String>(
      _GroupEditDialog(existingTitles: existingTitles),
    );
    if (title == null || !mounted) return;
    try {
      final created = await _settings.addQuickCommandGroup(title);
      if (mounted) _setGroupExpanded(created.id, true);
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _renameGroup(QuickCommandCategory group) async {
    final existingTitles = [
      for (final item in _settings.customQuickCommandGroups)
        if (item.id != group.id) item.title,
    ];
    final title = await _openDialog<String>(
      _GroupEditDialog(
        initialTitle: group.title,
        existingTitles: existingTitles,
      ),
    );
    if (title == null || !mounted) return;
    try {
      await _settings.renameQuickCommandGroup(group.id, title);
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _deleteGroup(QuickCommandCategory group) async {
    final confirmed =
        await _openDialog<bool>(
          AppDialog(
            title: Text('删除分组「@name」？'.trParams({'name': group.title})),
            content: Text(
              group.commands.isEmpty
                  ? '删除后无法恢复。'.tr
                  : '该分组包含 @count 条指令，删除后无法恢复。'.trParams({
                      'count': '${group.commands.length}',
                    }),
            ),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: const ValueKey('settings-quick-group-confirm-delete'),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('删除'.tr),
              ),
            ],
          ),
        ) ==
        true;
    if (!confirmed || !mounted) return;
    try {
      await _settings.deleteQuickCommandGroup(group.id);
      _collapsedGroupIds.remove(group.id);
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _addCommand(QuickCommandCategory group) async {
    final draft = await _openDialog<({String command, String summary})>(
      const _CommandEditDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      await _settings.addQuickCommand(
        group.id,
        command: draft.command,
        summary: draft.summary,
      );
      if (mounted) _setGroupExpanded(group.id, true);
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _editCommand(
    QuickCommandCategory group,
    QuickCommand command,
  ) async {
    final draft = await _openDialog<({String command, String summary})>(
      _CommandEditDialog(
        initialCommand: command.command,
        initialSummary: command.summary,
      ),
    );
    if (draft == null || !mounted) return;
    try {
      await _settings.updateQuickCommand(
        group.id,
        command.id,
        command: draft.command,
        summary: draft.summary,
      );
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _deleteCommand(
    QuickCommandCategory group,
    QuickCommand command,
  ) async {
    final confirmed =
        await _openDialog<bool>(
          AppDialog(
            title: Text('删除指令？'.tr),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surface(context),
                    border: Border.all(color: AppTheme.border(context)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(command.displayCommand, style: _monoCommandStyle),
                ),
                const SizedBox(height: 10),
                Text('删除后无法恢复。'.tr),
              ],
            ),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: const ValueKey('settings-quick-cmd-confirm-delete'),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('删除'.tr),
              ),
            ],
          ),
        ) ==
        true;
    if (!confirmed || !mounted) return;
    try {
      await _settings.deleteQuickCommand(group.id, command.id);
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _reorderGroup(
    String draggedId,
    String targetId, {
    required bool after,
  }) async {
    try {
      await _settings.reorderQuickCommandGroup(
        draggedId,
        targetId,
        after: after,
      );
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  Future<void> _moveCommand(
    String fromGroupId,
    String commandId,
    String toGroupId, {
    String? targetCommandId,
    bool after = false,
  }) async {
    try {
      await _settings.moveQuickCommand(
        fromGroupId,
        commandId,
        toGroupId,
        targetCommandId: targetCommandId,
        after: after,
      );
      if (mounted && fromGroupId != toGroupId) {
        _setGroupExpanded(toGroupId, true);
      }
    } on QuickCommandsException catch (e) {
      if (mounted) AppNotice.error(e.message);
    }
  }

  List<shadcn.TreeNode<_QuickTreeData>> _buildTreeNodes(
    List<QuickCommandCategory> groups,
  ) => [
    for (final group in groups)
      shadcn.TreeItemNode<_QuickTreeData>(
        data: _GroupTreeData(group),
        expanded: _isExpanded(group.id),
        children: group.commands.isEmpty
            ? [
                shadcn.TreeItemNode<_QuickTreeData>(
                  data: _EmptyGroupTreeData(group),
                ),
              ]
            : [
                for (final command in group.commands)
                  shadcn.TreeItemNode<_QuickTreeData>(
                    data: _CommandTreeData(group, command),
                  ),
              ],
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Obx(() {
      if (!_settings.isLoaded.value) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: shadcn.CircularProgressIndicator()),
        );
      }
      if (_settings.quickCommandsLoadFailed.value) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              Text('常用指令读取失败，请重试'.tr),
              const SizedBox(height: 12),
              shadcn.OutlineButton(
                onPressed: () async {
                  try {
                    await _settings.reloadCustomQuickCommandGroups();
                  } on QuickCommandsException catch (e) {
                    if (mounted) AppNotice.error(e.message);
                  }
                },
                child: Text('重试'.tr),
              ),
            ],
          ),
        );
      }

      final groups = _settings.customQuickCommandGroups.toList(growable: false);
      final busy = _settings.savingQuickCommands.value;
      final anyExpanded = groups.any((group) => _isExpanded(group.id));
      return Column(
        key: const ValueKey('settings-quick-commands-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '自定义分组与运维指令，支持拖拽调整顺序，并显示在终端底部「常用指令」面板中。'.tr,
                  style: TextStyle(fontSize: 12, color: colors.mutedForeground),
                ),
              ),
              if (groups.isNotEmpty) ...[
                const SizedBox(width: 8),
                shadcn.OutlineButton(
                  key: const ValueKey('settings-quick-commands-toggle-all'),
                  size: shadcn.ButtonSize.small,
                  onPressed: () => _toggleAll(groups),
                  child: Text((anyExpanded ? '全部折叠' : '全部展开').tr),
                ),
              ],
              const SizedBox(width: 8),
              shadcn.PrimaryButton(
                key: const ValueKey('settings-quick-commands-add-group'),
                size: shadcn.ButtonSize.small,
                leading: const AppIcon(AppIcons.plus, size: 14),
                onPressed: busy ? null : () => unawaited(_addGroup()),
                child: Text('新建分组'.tr),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (groups.isEmpty)
            shadcn.Card(
              key: const ValueKey('settings-quick-commands-empty'),
              theme: const shadcn.CardTheme(padding: EdgeInsets.all(20)),
              child: Column(
                children: [
                  AppIcon(
                    AppIcons.quickCommands,
                    size: 24,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '还没有自定义指令分组'.tr,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '可按项目或运维场景创建分组（如 Kubernetes、业务发布），添加常用命令与说明提示。'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  shadcn.OutlineButton(
                    size: shadcn.ButtonSize.small,
                    leading: const AppIcon(AppIcons.plus, size: 14),
                    onPressed: busy ? null : () => unawaited(_addGroup()),
                    child: Text('新建分组'.tr),
                  ),
                ],
              ),
            )
          else
            shadcn.Card(
              theme: const shadcn.CardTheme(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              ),
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: shadcn.Tree<_QuickTreeData>(
                  key: const ValueKey('settings-quick-commands-tree'),
                  nodes: _buildTreeNodes(groups),
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  branchLine: shadcn.BranchLine.path,
                  expandIcon: true,
                  allowMultiSelect: false,
                  recursiveSelection: false,
                  builder: (context, node) {
                    final visible =
                        shadcn.Data.maybeOf<shadcn.TreeNodeData<dynamic>>(
                          context,
                        )?.expanded ??
                        true;
                    return switch (node.data) {
                      _GroupTreeData(:final group) => _buildGroupTreeItem(
                        context,
                        group,
                        expanded: node.expanded,
                        busy: busy,
                      ),
                      _CommandTreeData(:final group, :final command) =>
                        _buildCommandTreeItem(
                          context,
                          group,
                          command,
                          visible: visible,
                          busy: busy,
                        ),
                      _EmptyGroupTreeData(:final group) =>
                        _buildEmptyGroupTreeItem(
                          context,
                          group,
                          visible: visible,
                          busy: busy,
                        ),
                    };
                  },
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildGroupTreeItem(
    BuildContext context,
    QuickCommandCategory group, {
    required bool expanded,
    required bool busy,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final dangerColor = AppTheme.menuDanger(context);
    return _SortableDropSlot<_QuickGroupDrag>(
      key: ValueKey('settings-quick-group-slot-${group.id}'),
      canAccept: (drag) => !busy && drag.groupId != group.id,
      onDrop: (drag, after) =>
          unawaited(_reorderGroup(drag.groupId, group.id, after: after)),
      child: DragTarget<_QuickCommandDrag>(
        key: ValueKey('settings-quick-group-drop-${group.id}'),
        onWillAcceptWithDetails: (details) =>
            !busy && details.data.groupId != group.id,
        onAcceptWithDetails: (details) => unawaited(
          _moveCommand(details.data.groupId, details.data.commandId, group.id),
        ),
        builder: (context, candidate, _) {
          final receivingCommand = candidate.isNotEmpty;
          return Opacity(
            opacity: _draggingGroupId == group.id ? 0.35 : 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                color: receivingCommand
                    ? colors.primary.withValues(alpha: 0.1)
                    : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: shadcn.TreeItem(
                key: ValueKey('settings-quick-group-${group.id}'),
                expandable: true,
                onExpand: (next) => _setGroupExpanded(group.id, next),
                onPressed: () => _toggleGroupExpanded(group.id),
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _groupDragHandle(context, group, busy: busy),
                    const SizedBox(width: 2),
                    AppIcon(
                      expanded ? AppIcons.folderOpen : AppIcons.folder,
                      size: 15,
                      color: colors.mutedForeground,
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    shadcn.OutlineButton(
                      key: ValueKey('settings-quick-group-add-cmd-${group.id}'),
                      size: shadcn.ButtonSize.small,
                      leading: const AppIcon(AppIcons.plus, size: 13),
                      onPressed: busy
                          ? null
                          : () => unawaited(_addCommand(group)),
                      child: Text('添加指令'.tr),
                    ),
                    const SizedBox(width: 4),
                    AppIconButton(
                      key: ValueKey('settings-quick-group-rename-${group.id}'),
                      semanticLabel: '重命名分组'.tr,
                      tooltip: '重命名分组'.tr,
                      density: shadcn.ButtonDensity.compact,
                      onPressed: busy
                          ? null
                          : () => unawaited(_renameGroup(group)),
                      icon: const AppIcon(AppIcons.pencil, size: 14),
                    ),
                    AppIconButton(
                      key: ValueKey('settings-quick-group-delete-${group.id}'),
                      semanticLabel: '删除分组'.tr,
                      tooltip: '删除分组'.tr,
                      density: shadcn.ButtonDensity.compact,
                      onPressed: busy
                          ? null
                          : () => unawaited(_deleteGroup(group)),
                      icon: AppIcon(
                        AppIcons.trash2,
                        size: 14,
                        color: dangerColor,
                      ),
                    ),
                  ],
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      shadcn.OutlineBadge(
                        child: Text(
                          '@count 条'.trParams({
                            'count': '${group.commands.length}',
                          }),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCommandTreeItem(
    BuildContext context,
    QuickCommandCategory group,
    QuickCommand command, {
    required bool visible,
    required bool busy,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final dangerColor = AppTheme.menuDanger(context);
    return _SortableDropSlot<_QuickCommandDrag>(
      key: ValueKey('settings-quick-cmd-slot-${command.id}'),
      canAccept: (drag) =>
          visible &&
          !busy &&
          !(drag.groupId == group.id && drag.commandId == command.id),
      onDrop: (drag, after) => unawaited(
        _moveCommand(
          drag.groupId,
          drag.commandId,
          group.id,
          targetCommandId: command.id,
          after: after,
        ),
      ),
      child: Opacity(
        opacity: _draggingCommandId == command.id ? 0.35 : 1,
        child: shadcn.TreeItem(
          key: ValueKey('settings-quick-cmd-${command.id}'),
          leading: Center(
            child: _commandDragHandle(context, group, command, busy: busy),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppIconButton(
                key: ValueKey('settings-quick-cmd-edit-${command.id}'),
                semanticLabel: '编辑指令'.tr,
                tooltip: '编辑指令'.tr,
                density: shadcn.ButtonDensity.compact,
                onPressed: busy
                    ? null
                    : () => unawaited(_editCommand(group, command)),
                icon: const AppIcon(AppIcons.pencil, size: 14),
              ),
              AppIconButton(
                key: ValueKey('settings-quick-cmd-delete-${command.id}'),
                semanticLabel: '删除指令'.tr,
                tooltip: '删除指令'.tr,
                density: shadcn.ButtonDensity.compact,
                onPressed: busy
                    ? null
                    : () => unawaited(_deleteCommand(group, command)),
                icon: AppIcon(AppIcons.trash2, size: 14, color: dangerColor),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.surface(context),
                    border: Border.all(color: AppTheme.border(context)),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      command.displayCommand,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _monoCommandStyle.copyWith(
                        color: colors.foreground,
                      ),
                    ),
                  ),
                ),
                if (command.summary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    command.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyGroupTreeItem(
    BuildContext context,
    QuickCommandCategory group, {
    required bool visible,
    required bool busy,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return DragTarget<_QuickCommandDrag>(
      key: ValueKey('settings-quick-group-empty-drop-${group.id}'),
      onWillAcceptWithDetails: (details) =>
          visible && !busy && details.data.groupId != group.id,
      onAcceptWithDetails: (details) => unawaited(
        _moveCommand(details.data.groupId, details.data.commandId, group.id),
      ),
      builder: (context, candidate, _) {
        final active = candidate.isNotEmpty;
        return shadcn.TreeItem(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: active ? colors.primary.withValues(alpha: 0.1) : null,
              border: active
                  ? Border.all(color: colors.primary.withValues(alpha: 0.6))
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              active ? '松开以将指令移入此分组'.tr : '该分组暂无指令，点击「添加指令」新增。'.tr,
              style: TextStyle(
                fontSize: 12,
                color: active ? colors.primary : colors.mutedForeground,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _groupDragHandle(
    BuildContext context,
    QuickCommandCategory group, {
    required bool busy,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final handle = MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.grab,
      child: SizedBox(
        width: 22,
        height: 24,
        child: Center(
          child: AppIcon(
            AppIcons.dragVertical,
            size: 15,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
    return shadcn.Tooltip(
      tooltip: (_) => shadcn.TooltipContainer(child: Text('拖拽排序分组'.tr)),
      child: Draggable<_QuickGroupDrag>(
        key: ValueKey('settings-quick-group-drag-${group.id}'),
        data: _QuickGroupDrag(group.id),
        maxSimultaneousDrags: busy ? 0 : 1,
        dragAnchorStrategy: (_, _, _) => _dragFeedbackAnchor,
        onDragStarted: () => setState(() => _draggingGroupId = group.id),
        onDragEnd: (_) {
          if (mounted && _draggingGroupId == group.id) {
            setState(() => _draggingGroupId = null);
          }
        },
        feedback: Opacity(
          opacity: 0.92,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: shadcn.SurfaceCard(
              theme: const shadcn.CardTheme(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.folder,
                    size: 15,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  shadcn.OutlineBadge(
                    child: Text(
                      '@count 条'.trParams({
                        'count': '${group.commands.length}',
                      }),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        child: handle,
      ),
    );
  }

  Widget _commandDragHandle(
    BuildContext context,
    QuickCommandCategory group,
    QuickCommand command, {
    required bool busy,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final handle = MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.grab,
      child: SizedBox(
        width: 22,
        height: 26,
        child: Center(
          child: AppIcon(
            AppIcons.dragVertical,
            size: 14,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
    return shadcn.Tooltip(
      tooltip: (_) => shadcn.TooltipContainer(child: Text('拖拽排序指令'.tr)),
      child: Draggable<_QuickCommandDrag>(
        key: ValueKey('settings-quick-cmd-drag-${command.id}'),
        data: _QuickCommandDrag(groupId: group.id, commandId: command.id),
        maxSimultaneousDrags: busy ? 0 : 1,
        dragAnchorStrategy: (_, _, _) => _dragFeedbackAnchor,
        onDragStarted: () => setState(() => _draggingCommandId = command.id),
        onDragEnd: (_) {
          if (mounted && _draggingCommandId == command.id) {
            setState(() => _draggingCommandId = null);
          }
        },
        feedback: Opacity(
          opacity: 0.92,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: shadcn.SurfaceCard(
              theme: const shadcn.CardTheme(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: Text(
                command.displayCommand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _monoCommandStyle.copyWith(color: colors.foreground),
              ),
            ),
          ),
        ),
        child: handle,
      ),
    );
  }
}

class _SortableDropSlot<T extends Object> extends StatefulWidget {
  const _SortableDropSlot({
    required this.canAccept,
    required this.onDrop,
    required this.child,
    super.key,
  });

  final bool Function(T data) canAccept;
  final void Function(T data, bool after) onDrop;
  final Widget child;

  @override
  State<_SortableDropSlot<T>> createState() => _SortableDropSlotState<T>();
}

class _SortableDropSlotState<T extends Object>
    extends State<_SortableDropSlot<T>> {
  bool? _dropAfter;

  bool _isAfter(DragTargetDetails<T> details) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(details.offset + _dragFeedbackAnchor);
    return local.dy >= box.size.height / 2;
  }

  void _update(DragTargetDetails<T> details) {
    if (!widget.canAccept(details.data)) {
      if (_dropAfter != null) setState(() => _dropAfter = null);
      return;
    }
    final next = _isAfter(details);
    if (_dropAfter != next) setState(() => _dropAfter = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final dropAfter = _dropAfter;
    return DragTarget<T>(
      onWillAcceptWithDetails: (details) {
        final allowed = widget.canAccept(details.data);
        if (allowed) _update(details);
        return allowed;
      },
      onMove: _update,
      onLeave: (_) {
        if (_dropAfter != null) setState(() => _dropAfter = null);
      },
      onAcceptWithDetails: (details) {
        final after = _isAfter(details);
        setState(() => _dropAfter = null);
        if (widget.canAccept(details.data)) {
          widget.onDrop(details.data, after);
        }
      },
      builder: (context, _, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (dropAfter != null)
            Positioned(
              left: 2,
              right: 2,
              top: dropAfter ? null : -1,
              bottom: dropAfter ? -1 : null,
              height: AppTheme.treeDropGuideHeight,
              child: IgnorePointer(child: ColoredBox(color: colors.primary)),
            ),
        ],
      ),
    );
  }
}

class _GroupEditDialog extends StatefulWidget {
  const _GroupEditDialog({
    required this.existingTitles,
    this.initialTitle = '',
  });

  final List<String> existingTitles;
  final String initialTitle;

  @override
  State<_GroupEditDialog> createState() => _GroupEditDialogState();
}

class _GroupEditDialogState extends State<_GroupEditDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.initialTitle);

  bool get _editing => widget.initialTitle.isNotEmpty;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    AppNavigation.closeDialog(result: _title.text.trim());
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    maxWidth: 400,
    title: Text((_editing ? '重命名分组' : '新建分组').tr),
    scrollable: true,
    content: Form(
      key: _form,
      child: AppTextFormField(
        key: const ValueKey('settings-quick-group-name-input'),
        controller: _title,
        autofocus: true,
        decoration: AppInputDecoration(
          labelText: '分组名称'.tr,
          hintText: '例如：Kubernetes、项目发布'.tr,
        ),
        validator: (value) => QuickCommandCategory.validateTitle(
          value,
          existingTitles: widget.existingTitles,
        )?.tr,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () => AppNavigation.closeDialog<String>(),
        child: Text('取消'.tr),
      ),
      shadcn.PrimaryButton(
        key: const ValueKey('settings-quick-group-save'),
        onPressed: _submit,
        child: Text('保存'.tr),
      ),
    ],
  );
}

class _CommandEditDialog extends StatefulWidget {
  const _CommandEditDialog({
    this.initialCommand = '',
    this.initialSummary = '',
  });

  final String initialCommand;
  final String initialSummary;

  @override
  State<_CommandEditDialog> createState() => _CommandEditDialogState();
}

class _CommandEditDialogState extends State<_CommandEditDialog> {
  final _form = GlobalKey<FormState>();
  late final _command = TextEditingController(text: widget.initialCommand);
  late final _summary = TextEditingController(text: widget.initialSummary);

  bool get _editing => widget.initialCommand.isNotEmpty;

  @override
  void dispose() {
    _command.dispose();
    _summary.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    AppNavigation.closeDialog<({String command, String summary})>(
      result: (
        command: QuickCommand.normalizeCommand(_command.text),
        summary: _summary.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    maxWidth: 460,
    title: Text((_editing ? '编辑指令' : '添加指令').tr),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppTextFormField(
            key: const ValueKey('settings-quick-cmd-input'),
            controller: _command,
            autofocus: true,
            smartPunctuation: false,
            autocorrect: false,
            enableSuggestions: false,
            decoration: AppInputDecoration(
              labelText: '指令内容'.tr,
              hintText: '例如：kubectl get pods -A'.tr,
              helperText: '支持保留末尾空格，点击后将填入当前聚焦终端且不会自动执行'.tr,
            ),
            validator: (value) => QuickCommand.validateCommand(value)?.tr,
          ),
          const SizedBox(height: 14),
          AppTextFormField(
            key: const ValueKey('settings-quick-cmd-summary-input'),
            controller: _summary,
            decoration: AppInputDecoration(
              labelText: '用途说明'.tr,
              hintText: '悬停时显示的功能介绍（选填）'.tr,
            ),
            validator: (value) => QuickCommand.validateSummary(value)?.tr,
            onFieldSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () =>
            AppNavigation.closeDialog<({String command, String summary})>(),
        child: Text('取消'.tr),
      ),
      shadcn.PrimaryButton(
        key: const ValueKey('settings-quick-cmd-save'),
        onPressed: _submit,
        child: Text('保存'.tr),
      ),
    ],
  );
}
