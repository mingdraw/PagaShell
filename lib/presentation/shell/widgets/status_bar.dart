import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../core/app_info.dart';
import '../../theme/app_theme.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SessionController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 11, color: colors.mutedForeground);

    return Container(
      height: AppTheme.statusBarHeight,
      color: AppTheme.sidebar(context),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Obx(() {
              final active = controller.activeSession;
              final (label, color) = switch (active?.phase) {
                null => ('就绪'.tr, StatusColors.closed),
                SessionPhase.ready => (
                  '已连接 @address'.trParams({'address': active!.address}),
                  StatusColors.ready,
                ),
                SessionPhase.failed => ('连接失败'.tr, StatusColors.failed),
                SessionPhase.closed => ('已断开'.tr, StatusColors.closed),
                _ => (
                  '连接中 @address…'.trParams({'address': active!.address}),
                  StatusColors.connecting,
                ),
              };
              return Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(label, style: style),
                ],
              );
            }),
          ),
          Text(AppInfo.versionLabel, style: style),
        ],
      ),
    );
  }
}
