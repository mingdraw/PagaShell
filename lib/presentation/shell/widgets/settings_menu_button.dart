import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../settings/settings_dialog.dart';

/// 顶部统一设置入口，打开独立的分类设置弹窗。
class SettingsMenuButton extends StatelessWidget {
  const SettingsMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AppIconButton(
      key: const ValueKey('app-settings-button'),
      semanticLabel: '设置'.tr,
      tooltip: '设置'.tr,
      icon: const AppIcon(AppIcons.settings, size: 16),
      onPressed: () => unawaited(showSettingsDialog()),
    );
  }
}
