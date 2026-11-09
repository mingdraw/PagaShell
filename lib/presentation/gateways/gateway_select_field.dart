import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../domain/entities/host.dart';
import '../components/app_icon.dart';
import '../components/app_select_field.dart';
import '../components/app_tree_select_popup.dart';
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
      popupBuilder: (_) {
        final folders = Get.find<GatewayFolderController>();
        return AppTreeSelectPopup(
          keyPrefix: 'gateway',
          folderIcon: AppIcons.folder,
          initialExpanded: folders.expanded,
          selectedFolderId: Get.find<GatewayController>().hosts
              .where((gateway) => gateway.id == value)
              .firstOrNull
              ?.folderId,
          parentOfFolder: (id) => folders.byId(id)?.parentId,
          childrenOf: (parent) => [
            for (final node
                in Get.find<GatewayTreeController>().snapshot.childrenOf(
                  parent,
                ))
              if (node.isFolder)
                AppTreeSelectNode(
                  id: node.folder!.id,
                  isFolder: true,
                  child: Text(
                    node.folder!.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                AppTreeSelectNode(
                  id: node.host!.id,
                  child: _GatewayLabel(gateway: node.host!),
                ),
          ],
          leadingBuilder: () => [
            if (value != null &&
                !Get.find<GatewayController>().hosts.any(
                  (gateway) => gateway.id == value,
                ))
              // 再次选择失效值，通过 canUnselect 清除绑定。
              shadcn.SelectItemButton<String>(
                key: const ValueKey('gateway-clear-unavailable'),
                value: value!,
                child: Text('取消网关绑定（直接连接）'.tr),
              ),
          ],
        );
      },
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
      const AppIcon(AppIcons.network, size: AppTheme.sidebarIconSize),
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
