import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/identities/identity_controller.dart';
import '../../domain/entities/identity.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';
import 'identity_edit_dialog.dart';

/// 凭证管理：查看 / 新建 / 删除可复用的登录凭证。
Future<void> showIdentityManagerDialog(BuildContext context) {
  return AppNavigation.dialog<void>(const _IdentityManagerDialog());
}

class _IdentityManagerDialog extends StatelessWidget {
  const _IdentityManagerDialog();

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<IdentityController>();
    final colors = shadcn.Theme.of(context).colorScheme;

    return AppDialog(
      title: Text('凭证管理'.tr),
      content: SizedBox(
        width: 420,
        height: 320,
        child: Obx(() {
          final identities = controller.sorted;
          if (identities.isEmpty) {
            return Center(
              child: Text(
                '还没有保存的凭证\n连接服务时勾选「保存为凭证」，或点击下方新建'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.mutedForeground),
              ),
            );
          }
          return ListView.builder(
            itemCount: identities.length,
            itemBuilder: (context, index) {
              final identity = identities[index];
              final authLabel = switch (identity.authType) {
                AuthType.password => '密码'.tr,
                AuthType.privateKey => '私钥'.tr,
                _ => '暂不支持'.tr,
              };
              return AppListRow(
                leading: const Icon(
                  shadcn.LucideIcons.fileKey,
                  size: AppTheme.sidebarIconSize,
                ),
                title: Text(
                  identity.name,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${identity.serviceType.label} · ${identity.username} · $authLabel',
                  style: TextStyle(fontSize: 11, color: colors.mutedForeground),
                ),
                onTap: () =>
                    showIdentityEditDialog(context, identity: identity),
                trailing: AppIconButton(
                  semanticLabel: '删除凭证'.tr,
                  icon: const Icon(shadcn.LucideIcons.trash2, size: 18),
                  onPressed: () => confirmDeleteIdentity(context, identity),
                ),
              );
            },
          );
        }),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => showIdentityEditDialog(context),
          leading: const Icon(shadcn.LucideIcons.plus, size: 16),
          child: Text('新建凭证'.tr),
        ),
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<void>(),
          child: Text('关闭'.tr),
        ),
      ],
    );
  }
}
