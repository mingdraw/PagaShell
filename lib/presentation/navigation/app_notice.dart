import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon.dart';
import '../localization/app_translations.dart';

/// shadcn 提示条；调用方只传经过脱敏的用户文案。
abstract final class AppNotice {
  static void error(String message) {
    _show(AppTranslations.error(message), AppIcons.circleAlert);
  }

  static void success(String message) {
    _show(message, AppIcons.check);
  }

  static void _show(String message, AppIcons icon) {
    final context = Get.overlayContext;
    if (context == null) return;
    shadcn.showToast(
      context: context,
      builder: (context, overlay) => shadcn.SurfaceCard(
        child: shadcn.Row(
          mainAxisSize: shadcn.MainAxisSize.min,
          children: [
            AppIcon(icon, size: 16),
            const shadcn.SizedBox(width: 10),
            shadcn.Flexible(child: shadcn.Text(message)),
          ],
        ),
      ),
    );
  }
}
