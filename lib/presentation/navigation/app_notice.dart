import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';

/// shadcn 提示条；调用方只传经过脱敏的用户文案。
abstract final class AppNotice {
  static void error(String message) {
    _show(
      AppTranslations.error(message),
      AppIcons.circleAlert,
      StatusColors.failed,
    );
  }

  static void success(String message) {
    _show(message, AppIcons.check, StatusColors.ready);
  }

  static void _show(String message, AppIcons icon, Color accent) {
    final context = Get.overlayContext;
    if (context == null) return;
    shadcn.showToast(
      context: context,
      builder: (context, overlay) => shadcn.SurfaceCard(
        borderColor: accent.withValues(alpha: 0.45),
        child: shadcn.Row(
          mainAxisSize: shadcn.MainAxisSize.min,
          children: [
            AppIcon(icon, size: 16, color: accent),
            const shadcn.SizedBox(width: 10),
            shadcn.Flexible(child: shadcn.Text(message)),
          ],
        ),
      ),
    );
  }
}
