import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../components/app_icon_button.dart';
import '../../settings/settings_dialog.dart';
import '../../theme/app_theme.dart';

/// 侧栏左下角统一设置入口，打开独立的分类设置弹窗。
class SettingsMenuButton extends StatelessWidget {
  const SettingsMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AppIconButton.ghost(
      key: const ValueKey('app-settings-button'),
      semanticLabel: '设置'.tr,
      tooltip: '设置'.tr,
      icon: const Icon(
        shadcn.LucideIcons.settings,
        size: AppTheme.toolbarIconSize,
      ),
      onPressed: () => unawaited(showSettingsDialog()),
    );
  }
}
