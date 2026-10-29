import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../domain/entities/folder.dart';
import '../../domain/entities/host.dart';
import '../../domain/services/host_tree.dart';
import '../components/app_select_field.dart';
import '../theme/app_theme.dart';

/// 只保存网关 ID；空值表示直接连接，弹层展开状态与侧栏独立。
class GatewaySelectField extends StatelessWidget {
  const GatewaySelectField({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String? value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) => Obx(() {
    final gateways = Get.find<GatewayController>().hosts;
    final exists =
        value == null || gateways.any((gateway) => gateway.id == value);
    return AppSelectField<String>(
      key: ValueKey('gateway-select-$value'),
      initialValue: value,
      canUnselect: true,
      label: '网关'.tr,
      items: [
        for (final gateway in gateways)
          AppSelectOption(
            value: gateway.id,
            child: _GatewayLabel(gateway: gateway),
          ),
        if (!exists) AppSelectOption(value: value!, child: Text('所选网关已不存在'.tr)),
      ],
      popupBuilder: (_) => shadcn.SelectPopup<String>.noVirtualization(
        items: shadcn.SelectItemList(
          children: [_GatewayTreeRows(selected: value)],
        ),
      ),
      onChanged: onChanged,
      validator: (_) => exists ? null : '所选网关已不存在'.tr,
    );
  });
}

class _GatewayLabel extends StatelessWidget {
  const _GatewayLabel({required this.gateway});
  final Host gateway;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(shadcn.LucideIcons.network, size: AppTheme.sidebarIconSize),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          '${gateway.name} (${gateway.gatewayType.label} · ${gateway.hostname}:${gateway.port})',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

class _GatewayTreeRows extends StatefulWidget {
  const _GatewayTreeRows({required this.selected});
  final String? selected;

  @override
  State<_GatewayTreeRows> createState() => _GatewayTreeRowsState();
}

class _GatewayTreeRowsState extends State<_GatewayTreeRows> {
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    final folders = Get.find<GatewayFolderController>();
    _expanded = folders.expanded.toSet();
    var parent = Get.find<GatewayController>().hosts
        .where((gateway) => gateway.id == widget.selected)
        .firstOrNull
        ?.folderId;
    final visited = <String>{};
    while (parent != null && visited.add(parent)) {
      _expanded.add(parent);
      parent = folders.byId(parent)?.parentId;
    }
  }

  void _toggle(String id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  List<Widget> _rows(HostTreeSnapshot snapshot, String? parent, int depth) {
    final rows = <Widget>[];
    for (final node in snapshot.childrenOf(parent)) {
      if (node.isFolder) {
        final folder = node.folder!;
        final expanded = _expanded.contains(folder.id);
        rows.add(
          _FolderOption(
            key: ValueKey('gateway-folder-${folder.id}'),
            folder: folder,
            depth: depth,
            expanded: expanded,
            onToggle: () => _toggle(folder.id),
          ),
        );
        if (expanded) rows.addAll(_rows(snapshot, folder.id, depth + 1));
      } else {
        final gateway = node.host!;
        rows.add(
          shadcn.SelectItemButton<String>(
            key: ValueKey('gateway-option-${gateway.id}'),
            value: gateway.id,
            child: Padding(
              padding: EdgeInsets.only(left: 18 + depth * 14.0),
              child: _GatewayLabel(gateway: gateway),
            ),
          ),
        );
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final selected = widget.selected;
    final gateways = Get.find<GatewayController>().hosts;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected != null && !gateways.any((g) => g.id == selected))
          // Selecting the unavailable value explicitly clears it via canUnselect.
          shadcn.SelectItemButton<String>(
            key: const ValueKey('gateway-clear-unavailable'),
            value: selected,
            child: Text('取消网关绑定（直接连接）'.tr),
          ),
        ..._rows(Get.find<GatewayTreeController>().snapshot, null, 0),
      ],
    );
  });
}

/// 文件夹只展开，不参与值选择；保持与凭证选择器一致的键盘操作。
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
                    shadcn.LucideIcons.folder,
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
