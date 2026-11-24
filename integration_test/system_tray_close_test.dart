import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/tray/system_tray_controller.dart';
import 'package:pagashell/infrastructure/tray/native_system_tray.dart';
import 'package:pagashell/infrastructure/window/native_app_window.dart';

import '../test/support/in_memory_binding.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(Get.reset);

  testWidgets('开启关闭最小化到托盘后关闭窗口仅隐藏到托盘且可重新显示', (tester) async {
    final appWindow = NativeAppWindow();
    final systemTray = NativeSystemTray();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(appWindow: appWindow, systemTray: systemTray),
      ),
    );
    await tester.pumpAndSettle();

    final settings = Get.find<SettingsController>();
    final tray = Get.find<SystemTrayController>();
    await settings.setMinimizeToTrayOnClose(true);
    await tester.pumpAndSettle();

    expect(await appWindow.isVisible(), isTrue);

    await appWindow.close();
    // 等待原生异步关闭回调、隐藏窗口及 AppKit 生命周期通知全部落定。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();

    expect(tray.windowHiddenInTray.value, isTrue);
    expect(await appWindow.isVisible(), isFalse);

    await tray.handleMenuAction(SystemTrayController.actionShowWindow);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();

    expect(tray.windowHiddenInTray.value, isFalse);
    expect(await appWindow.isVisible(), isTrue);

    await tray.disposeTray();
  }, skip: !Platform.isMacOS);
}
