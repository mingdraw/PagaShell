import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

abstract final class AppNavigation {
  /// Get.generalDialog 保留 GetX 路由跟踪，不读取 Material 主题或本地化。
  static Future<T?> dialog<T>(
    Widget child, {
    Color barrierColor = const Color(0x99000000),
    bool barrierDismissible = true,
  }) => Get.generalDialog<T>(
    navigatorKey: Get.key,
    barrierLabel: '关闭'.tr,
    barrierColor: barrierColor,
    barrierDismissible: barrierDismissible,
    pageBuilder: (_, _, _) => SafeArea(child: child),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );

  /// 提示条不占用 Navigator，关闭弹窗只返回当前模态的结果。
  static void closeDialog<T>({T? result}) {
    if (Get.isDialogOpen == true) Get.key.currentState?.pop<T>(result);
  }
}
