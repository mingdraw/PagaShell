import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/identities/identity_controller.dart';
import '../../application/identities/identity_folder_controller.dart';
import '../../application/identities/identity_tree_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../components/app_select_field.dart';
import '../components/app_tree_select_popup.dart';
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

  bool _supported(Identity identity) =>
      identity.supports(serviceType) &&
      (identity.authType == AuthType.password ||
          (!passwordOnly && identity.authType == AuthType.privateKey));

  @override
  Widget build(BuildContext context) => Obx(() {
    final identities = Get.find<IdentityController>().identities
        .where(_supported)
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
          popupBuilder: (_) {
            final folders = Get.find<IdentityFolderController>();
            return AppTreeSelectPopup(
              keyPrefix: 'identity',
              folderIcon: shadcn.LucideIcons.folderKey,
              initialExpanded: folders.expanded,
              selectedFolderId: Get.find<IdentityController>()
                  .byId(selected)
                  ?.folderId,
              parentOfFolder: (id) => folders.byId(id)?.parentId,
              childrenOf: (parent) => [
                for (final node
                    in Get.find<IdentityTreeController>().snapshot.childrenOf(
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
                  else if (_supported(node.identity!))
                    AppTreeSelectNode(
                      id: node.identity!.id,
                      child: _IdentityLabel(identity: node.identity!),
                    ),
              ],
            );
          },
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
