import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/identities/identity_controller.dart';
import '../../application/identities/identity_folder_controller.dart';
import '../../application/identities/identity_tree_controller.dart';
import '../../domain/entities/folder.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/services/identity_tree.dart';
import '../components/app_select_field.dart';
import '../theme/app_theme.dart';

/// 表单只保存凭证 ID；弹层的展开状态与侧栏独立。
class IdentitySelectField extends StatelessWidget {
  const IdentitySelectField({
    required this.value,
    required this.onChanged,
    this.passwordOnly = false,
    this.serviceType = ServiceType.ssh,
    super.key,
  });

  final String? value;
  final ValueChanged<String?>? onChanged;
  final bool passwordOnly;
  final ServiceType serviceType;

  @override
  Widget build(BuildContext context) => Obx(() {
    final identities = Get.find<IdentityController>().identities
        .where(
          (identity) =>
              identity.supports(serviceType) &&
              _supported(identity, passwordOnly: passwordOnly),
        )
        .toList();
    final selected = identities.any((identity) => identity.id == value)
        ? value
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSelectField<String>(
          key: ValueKey(selected),
          initialValue: selected,
          label: '凭证'.tr,
          items: [
            for (final identity in identities)
              AppSelectOption(
                value: identity.id,
                child: _IdentityLabel(identity: identity),
              ),
          ],
          popupBuilder: (_) => _IdentityTreePopup(
            selected: selected,
            passwordOnly: passwordOnly,
            serviceType: serviceType,
          ),
          onChanged: onChanged,
          validator: (id) => identities.any((identity) => identity.id == id)
              ? null
              : '请选择凭证'.tr,
        ),
        if (identities.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '还没有凭证，可在侧边栏「凭证」组新建'.tr,
              style: TextStyle(
                fontSize: 12,
                color: shadcn.Theme.of(context).colorScheme.mutedForeground,
              ),
            ),
          ),
      ],
    );
  });
}

bool _supported(Identity identity, {bool passwordOnly = false}) =>
    identity.authType == AuthType.password ||
    (!passwordOnly && identity.authType == AuthType.privateKey);

class _IdentityLabel extends StatelessWidget {
  const _IdentityLabel({required this.identity});
  final Identity identity;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(shadcn.LucideIcons.fileKey, size: AppTheme.sidebarIconSize),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          identity.serviceType == ServiceType.vnc
              ? identity.name
              : '@name（@username）'.trParams({
                  'name': identity.name,
                  'username': identity.username,
                }),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

class _IdentityTreePopup extends StatelessWidget {
  const _IdentityTreePopup({
    required this.selected,
    required this.passwordOnly,
    required this.serviceType,
  });
  final String? selected;
  final bool passwordOnly;
  final ServiceType serviceType;

  @override
  Widget build(BuildContext context) =>
      shadcn.SelectPopup<String>.noVirtualization(
        items: shadcn.SelectItemList(
          children: [
            _IdentityTreeRows(
              selected: selected,
              passwordOnly: passwordOnly,
              serviceType: serviceType,
            ),
          ],
        ),
      );
}

/// 展开状态放在弹层内部，避免 SelectPopup 对选项 delegate 的缓存影响更新。
class _IdentityTreeRows extends StatefulWidget {
  const _IdentityTreeRows({
    required this.selected,
    required this.passwordOnly,
    required this.serviceType,
  });
  final String? selected;
  final bool passwordOnly;
  final ServiceType serviceType;

  @override
  State<_IdentityTreeRows> createState() => _IdentityTreeRowsState();
}

class _IdentityTreeRowsState extends State<_IdentityTreeRows> {
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    final folders = Get.find<IdentityFolderController>();
    _expanded = folders.expanded.toSet();
    var parent = Get.find<IdentityController>().byId(widget.selected)?.folderId;
    final visited = <String>{};
    while (parent != null && visited.add(parent)) {
      _expanded.add(parent);
      parent = folders.byId(parent)?.parentId;
    }
  }

  void _toggle(String id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  List<Widget> _rows(IdentityTreeSnapshot snapshot, String? parent, int depth) {
    final rows = <Widget>[];
    for (final node in snapshot.childrenOf(parent)) {
      if (node.isFolder) {
        final folder = node.folder!;
        final expanded = _expanded.contains(folder.id);
        rows.add(
          _FolderOption(
            key: ValueKey('identity-folder-${folder.id}'),
            folder: folder,
            depth: depth,
            expanded: expanded,
            onToggle: () => _toggle(folder.id),
          ),
        );
        if (expanded) rows.addAll(_rows(snapshot, folder.id, depth + 1));
      } else if (node.identity!.supports(widget.serviceType) &&
          _supported(node.identity!, passwordOnly: widget.passwordOnly)) {
        final identity = node.identity!;
        rows.add(
          shadcn.SelectItemButton<String>(
            key: ValueKey('identity-option-${identity.id}'),
            value: identity.id,
            child: Padding(
              padding: EdgeInsets.only(left: 18 + depth * 14.0),
              child: _IdentityLabel(identity: identity),
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
      children: _rows(Get.find<IdentityTreeController>().snapshot, null, 0),
    ),
  );
}

/// 文件夹只展开，不进入 Select 的值选择路径；Enter 与鼠标使用同一操作。
class _FolderOption extends StatelessWidget {
  const _FolderOption({
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    super.key,
  });
  final Folder folder;
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
                  const Icon(
                    shadcn.LucideIcons.folderKey,
                    size: AppTheme.sidebarIconSize,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(folder.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
