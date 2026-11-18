import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/identities/identity_controller.dart';
import '../../domain/entities/identity.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';
import 'identity_edit_dialog.dart';

/// 凭证管理：查看 / 检索 / 新建 / 编辑 / 删除可复用的登录凭证。
Future<void> showIdentityManagerDialog(BuildContext context) {
  return AppNavigation.dialog<void>(const _IdentityManagerDialog());
}

class _IdentityManagerDialog extends StatefulWidget {
  const _IdentityManagerDialog();

  @override
  State<_IdentityManagerDialog> createState() => _IdentityManagerDialogState();
}

class _IdentityManagerDialogState extends State<_IdentityManagerDialog> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocus.requestFocus();
  }

  bool _matches(Identity identity, String query) {
    if (query.isEmpty) return true;
    final lower = query.toLowerCase();
    return identity.name.toLowerCase().contains(lower) ||
        identity.username.toLowerCase().contains(lower) ||
        identity.serviceType.label.toLowerCase().contains(lower);
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<IdentityController>();
    final colors = shadcn.Theme.of(context).colorScheme;

    return AppDialog(
      title: Text('凭证管理'.tr),
      content: SizedBox(
        width: 420,
        height: 340,
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
          return ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              final query = value.text.trim();
              final filtered = identities
                  .where((item) => _matches(item, query))
                  .toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CallbackShortcuts(
                    bindings: value.text.isEmpty
                        ? const {}
                        : {
                            const SingleActivator(LogicalKeyboardKey.escape):
                                _clearSearch,
                          },
                    child: Semantics(
                      label: '搜索凭证'.tr,
                      child: AppTextFormField(
                        key: const ValueKey('identity-manager-search'),
                        controller: _searchController,
                        focusNode: _searchFocus,
                        compact: true,
                        decoration: AppInputDecoration(
                          hintText: '搜索名称、用户名或协议'.tr,
                          suffixIcon: value.text.isEmpty
                              ? const AppIcon(AppIcons.search, size: 14)
                              : SizedBox.square(
                                  dimension: 18,
                                  child: AppIconButton.text(
                                    key: const ValueKey(
                                      'identity-manager-search-clear',
                                    ),
                                    semanticLabel: '清空搜索'.tr,
                                    tooltip: '清空搜索'.tr,
                                    density: shadcn.ButtonDensity.compact,
                                    onPressed: _clearSearch,
                                    icon: const AppIcon(AppIcons.x, size: 12),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              '无匹配凭证'.tr,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.mutedForeground,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final identity = filtered[index];
                              final authLabel = switch (identity.authType) {
                                AuthType.password => '密码'.tr,
                                AuthType.privateKey => '私钥'.tr,
                                _ => '暂不支持'.tr,
                              };
                              return AppListRow(
                                leading: const AppIcon(
                                  AppIcons.fileKey,
                                  size: AppTheme.sidebarIconSize,
                                ),
                                title: Text(
                                  identity.name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: Text(
                                  '${identity.serviceType.label} · ${identity.username} · $authLabel',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.mutedForeground,
                                  ),
                                ),
                                onTap: () => showIdentityEditDialog(
                                  context,
                                  identity: identity,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AppIconButton(
                                      semanticLabel: '编辑凭证'.tr,
                                      tooltip: '编辑'.tr,
                                      icon: const AppIcon(
                                        AppIcons.pencil,
                                        size: 16,
                                      ),
                                      onPressed: () => showIdentityEditDialog(
                                        context,
                                        identity: identity,
                                      ),
                                    ),
                                    AppIconButton(
                                      semanticLabel: '删除凭证'.tr,
                                      tooltip: '删除'.tr,
                                      icon: const AppIcon(
                                        AppIcons.trash2,
                                        size: 16,
                                      ),
                                      onPressed: () => confirmDeleteIdentity(
                                        context,
                                        identity,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        }),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => showIdentityEditDialog(context),
          leading: const AppIcon(AppIcons.plus, size: 16),
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
