import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  testWidgets('设置弹窗包含代理 Tab，支持自动、关闭和手动设置（协议/地址/可选用户名密码）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settingsRepo = InMemorySettingsRepository();
    final binding = InMemoryBinding(settingsRepository: settingsRepo);
    await tester.pumpWidget(
      PagaShellApp(binding: binding, platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();

    expect(find.text('通用'), findsOneWidget);
    expect(find.text('代理'), findsOneWidget);
    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    await tester.tap(find.text('代理'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('proxy-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-save')), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('手动设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-address')), findsNothing);

    // 切换为关闭，未点击保存前不立即生效；点击保存后才保存。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('proxy-settings')),
        matching: find.text('关闭代理'),
      ),
    );
    await tester.pumpAndSettle();
    expect(settingsRepo.proxySettings.mode, AppProxyMode.auto);
    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();
    expect(settingsRepo.proxySettings.mode, AppProxyMode.off);
    expect(find.text('代理设置已保存'), findsOneWidget);

    // 切换为手动设置，校验必填与格式。
    await tester.tap(find.text('手动设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-address')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-username')), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-password')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();
    expect(find.text('必填'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('proxy-address')),
      '127.0.0.1',
    );
    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();
    expect(find.text('请填写包含端口的代理地址，例如 127.0.0.1:7890'), findsOneWidget);

    // 选择 SOCKS5 协议并保存，验证可选用户名和密码。
    await tester.tap(find.byType(shadcn.Select<AppProxyProtocol>));
    await tester.pumpAndSettle();
    expect(find.text('HTTP'), findsWidgets);
    expect(find.text('HTTPS'), findsOneWidget);
    expect(find.text('SOCKS5'), findsOneWidget);
    await tester.tap(find.text('SOCKS5').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('proxy-address')),
      '127.0.0.1:1080',
    );
    await tester.enterText(
      find.byKey(const ValueKey('proxy-username')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const ValueKey('proxy-password')),
      'secret-pass',
    );
    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();

    expect(find.text('代理设置已保存'), findsOneWidget);
    expect(settingsRepo.proxySettings.mode, AppProxyMode.manual);
    expect(settingsRepo.proxySettings.protocol, AppProxyProtocol.socks5);
    expect(settingsRepo.proxySettings.address, '127.0.0.1:1080');
    expect(settingsRepo.proxySettings.username, 'alice');
    expect(settingsRepo.proxySettings.hasSavedPassword, isTrue);
    expect(
      await binding.secretStore.read(
        settingsRepo.proxySettings.passwordSecretRef,
      ),
      'secret-pass',
    );
    final passwordField = tester.widget<AppTextFormField>(
      find.byKey(const ValueKey('proxy-password')),
    );
    expect(passwordField.controller.text, isEmpty);

    // 清除已保存密码并再次保存。
    await tester.tap(find.byKey(const ValueKey('proxy-password-clear')));
    await tester.pumpAndSettle();
    expect(find.text('将在保存后清除已保存密码'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();
    expect(settingsRepo.proxySettings.hasSavedPassword, isFalse);

    // 切回自动模式，同样点击保存后生效。
    await tester.tap(find.text('自动'));
    await tester.pumpAndSettle();
    expect(settingsRepo.proxySettings.mode, AppProxyMode.manual);
    await tester.tap(find.byKey(const ValueKey('proxy-save')));
    await tester.pumpAndSettle();
    expect(settingsRepo.proxySettings.mode, AppProxyMode.auto);
    expect(settingsRepo.proxySettings.address, '127.0.0.1:1080');

    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('showSettingsDialog(ai: true) 仍打开 AI 设置，英文界面正常翻译', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    unawaited(showSettingsDialog(ai: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-model-url')), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      unawaited(Get.updateLocale(AppTranslations.englishLocale));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    unawaited(showSettingsDialog(proxy: true));
    await tester.pumpAndSettle();
    expect(find.text('Proxy'), findsOneWidget);
    expect(find.text('Proxy mode'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(find.text('Proxy protocol'), findsOneWidget);
    expect(find.text('Proxy address'), findsOneWidget);
    expect(
      Get.find<SettingsController>().proxySettings.value.mode,
      AppProxyMode.auto,
    );

    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('短窗口滚动设置内容时页签保持可见，可直接切换到终端', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    unawaited(showSettingsDialog(proxy: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动设置'));
    await tester.pumpAndSettle();

    final tabs = find.byKey(const ValueKey('settings-tabs'));
    final terminal = find.descendant(of: tabs, matching: find.text('终端'));
    final before = tester.getTopLeft(tabs);
    final content = find.ancestor(
      of: find.byKey(const ValueKey('proxy-address')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(content).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tabs), before);
    await tester.tap(terminal);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('proxy-address')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
