import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../configuration/configuration_transfer_dialog.dart';
import '../../theme/app_theme.dart';
import 'window_controls.dart';

/// 与侧栏开关相邻的配置导入和导出按钮。
class WorkspaceHeaderActions extends StatelessWidget {
  const WorkspaceHeaderActions({super.key});

  static double width(BuildContext context) =>
      AppTheme.windowHeaderControlSize(context) * 2;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
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
    ],
  );
}

/// 窗口顶部按钮与主工作区重叠的宽度，随两侧栏实际占用的空间变化。
class WorkspaceHeaderInsets extends InheritedWidget {
  const WorkspaceHeaderInsets({
    required this.insets,
    required super.child,
    super.key,
  });

  final EdgeInsets insets;

  static EdgeInsets? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WorkspaceHeaderInsets>()
      ?.insets;

  @override
  bool updateShouldNotify(WorkspaceHeaderInsets oldWidget) =>
      oldWidget.insets != insets;
}
