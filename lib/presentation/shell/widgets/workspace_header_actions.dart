import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../configuration/configuration_transfer_dialog.dart';
import 'settings_menu_button.dart';
import 'window_controls.dart';

/// 设置、配置传输和 Agent 共用顶部按钮样式与拖窗排除区域。
class WorkspaceHeaderActions extends StatelessWidget {
  const WorkspaceHeaderActions({this.agentButton, super.key});

  final Widget? agentButton;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (agentButton case final button?) WindowHeaderButton(child: button),
      WindowHeaderButton(
        child: AppIconButton(
          key: const ValueKey('import-configuration'),
          semanticLabel: '导入配置'.tr,
          tooltip: '导入配置'.tr,
          icon: const AppIcon(AppIcons.fileImport, size: 16),
          onPressed: () => unawaited(showConfigurationImportDialog()),
        ),
      ),
      WindowHeaderButton(
        child: AppIconButton(
          key: const ValueKey('export-configuration'),
          semanticLabel: '导出配置'.tr,
          tooltip: '导出配置'.tr,
          icon: const AppIcon(AppIcons.fileExport, size: 16),
          onPressed: () => unawaited(showConfigurationExportDialog()),
        ),
      ),
      const WindowHeaderButton(child: SettingsMenuButton()),
    ],
  );
}
