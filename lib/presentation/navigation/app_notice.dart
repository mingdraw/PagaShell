import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
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
    _show(message.tr, AppIcons.check, StatusColors.ready);
  }

  static void _show(String message, AppIcons icon, Color accent) {
    final context = Get.overlayContext;
    if (context == null) return;
    shadcn.showToast(
      context: context,
      location: shadcn.ToastLocation.bottomCenter,
      builder: (context, overlay) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: shadcn.SurfaceCard(
          borderColor: accent.withValues(alpha: 0.45),
          child: shadcn.Row(
            mainAxisSize: shadcn.MainAxisSize.min,
            children: [
              AppIcon(icon, size: 16, color: accent),
              const shadcn.SizedBox(width: 10),
              shadcn.Flexible(child: shadcn.Text(message)),
              const shadcn.SizedBox(width: 8),
              SizedBox.square(
                dimension: 20,
                child: AppIconButton.text(
                  key: const ValueKey('app-notice-close'),
                  semanticLabel: '关闭提示'.tr,
                  tooltip: '关闭'.tr,
                  density: shadcn.ButtonDensity.compact,
                  onPressed: overlay.close,
                  icon: const AppIcon(AppIcons.x, size: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
