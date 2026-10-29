import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/settings/settings_controller.dart';
import '../../theme/app_theme.dart';
import 'window_controls.dart';

/// 独立标题栏，保留侧栏开关、窗口控制与空白拖动区域。
class TitleBar extends StatelessWidget {
  const TitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final settings = Get.find<SettingsController>();
    return Obx(() {
      final sidebarVisible = settings.sidebarState.value.visible;
      return ColoredBox(
        color: AppTheme.sidebar(context),
        child: SizedBox(
          height: AppTheme.windowHeaderHeight,
          child: Row(
            children: [
              if (isMac && !sidebarVisible)
                const SizedBox(
                  width: AppTheme.macWindowControlsWidth,
                  child: WindowDragArea(),
                )
              else
                const SizedBox(width: 8),
              if (!sidebarVisible) const SidebarToggleButton(),
              const Expanded(child: WindowDragArea()),
              if (!isMac) const WindowButtons(),
            ],
          ),
        ),
      );
    });
  }
}
