import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../theme/app_theme.dart';

class PanelRefreshPauseButton extends StatelessWidget {
  const PanelRefreshPauseButton({
    required this.paused,
    required this.onChanged,
    super.key,
  });

  final RxBool paused;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Obx(() {
    final active = paused.value;
    final label = (active ? '恢复自动刷新' : '暂停自动刷新').tr;
    return AppIconButton(
      semanticLabel: label,
      tooltip: label,
      icon: AppIcon(
        active ? AppIcons.play : AppIcons.pause,
        size: 15,
        color: active ? AppTheme.serverStatusWarningColor : null,
      ),
      onPressed: () => onChanged(!active),
    );
  });
}
