import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/shell/widgets/sidebar.dart';
import 'package:pagashell/presentation/shell/widgets/workspace.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

void main() {
  setUp(() {
    Get.locale = AppTranslations.defaultLocale;
  });
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    InMemorySettingsRepository? repository,
  }) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(settingsRepository: repository),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
  }

  shadcn.ColorScheme colors(WidgetTester tester) =>
      shadcn.Theme.of(tester.element(find.byType(Workspace))).colorScheme;

  Color shellBackground(WidgetTester tester, Type type) => tester
      .widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(type),
              matching: find.byType(ColoredBox),
            )
            .first,
      )
      .color;

  Future<void> chooseMode(WidgetTester tester, String label) async {
    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<AppThemeMode>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();
  }

  testWidgets('侧栏左下角设置打开独立分类弹窗，通用含主题和语言，入口随侧栏隐藏', (tester) async {
    await pumpApp(tester);
    final button = findAppIconButton('设置');
    expect(button, findsOneWidget);
    expect(findAppIconButton('主题模式'), findsNothing);
    expect(findAppIconButton('语言'), findsNothing);
    expect(
      find.descendant(of: find.byType(Workspace), matching: button),
      findsNothing,
    );
    expect(tester.widget<AppIconButton>(button).tooltip, '设置');
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(button).dx, lessThan(64));
    expect(tester.getTopLeft(button).dy, greaterThan(size.height - 40));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.byType(shadcn.Tabs), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('AI 设置'), findsOneWidget);
    for (final label in ['主题模式', '语言']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(find.byType(AppSelectField<AppThemeMode>), findsOneWidget);
    expect(find.byType(AppSelectField<Locale>), findsOneWidget);
    await tester.tap(find.text('AI 设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-model-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-model-id')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-model-test')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('主题模式'), findsNothing);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();
    expect(Get.find<SettingsController>().sidebarState.value.visible, isTrue);
    expect(findAppIconButton('设置'), findsOneWidget);
    await tester.tap(findAppIconButton('隐藏侧边栏'));
    await tester.pumpAndSettle();
    expect(findAppIconButton('设置'), findsNothing);
    await tester.tap(findAppIconButton('显示侧边栏'));
    await tester.pumpAndSettle();
    expect(findAppIconButton('设置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认自动模式随系统亮度变化，窗口各区域同步更新', (tester) async {
    await pumpApp(tester);
    expect(Get.find<SettingsController>().themeMode.value, AppThemeMode.system);
    expect(colors(tester).brightness, Brightness.light);
    expect(
      shellBackground(tester, Workspace),
      shadcn.ColorSchemes.lightZinc.background,
    );
    final lightSidebar = shellBackground(tester, Sidebar);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.dark);
    expect(
      shellBackground(tester, Workspace),
      shadcn.ColorSchemes.darkZinc.background,
    );
    expect(shellBackground(tester, Sidebar), isNot(lightSidebar));

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用设置可选择三种模式，手动模式不随系统改变，选择保存', (tester) async {
    final repository = InMemorySettingsRepository();
    await pumpApp(tester, repository: repository);
    await chooseMode(tester, '深色');
    expect(colors(tester).brightness, Brightness.dark);
    expect(repository.themeMode, AppThemeMode.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.dark);

    await chooseMode(tester, '浅色');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.light);
    expect(repository.themeMode, AppThemeMode.light);

    await chooseMode(tester, '自动');
    expect(colors(tester).brightness, Brightness.dark);
    expect(repository.themeMode, AppThemeMode.system);
  });

  testWidgets('读取已保存模式后再显示首帧，覆盖系统亮度', (tester) async {
    final repository = _DelayedSettingsRepository();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(settingsRepository: repository),
        platform: TargetPlatform.macOS,
      ),
    );
    expect(find.byType(shadcn.ShadcnApp), findsNothing);
    repository.saved.complete(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.dark);
  });

  testWidgets('切换主题保留主机数据、控制器和打开表单的输入', (tester) async {
    await pumpApp(tester);
    final hosts = Get.find<HostController>();
    await hosts.save(
      const Host(id: 'h1', name: '生产主机', hostname: 'example.test'),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('服务组操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '新建服务'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      '数据库-01',
    );
    await Get.find<SettingsController>().setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(Get.find<HostController>(), same(hosts));
    expect(find.text('生产主机'), findsOneWidget);
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.text('数据库-01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色外壳下终端保持可读底色，切换主题保留终端实例', (tester) async {
    await pumpApp(tester);
    final terminal = Terminal()..write('preserved output');
    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 's1',
        host: const Host(id: 'h1', name: '终端', hostname: 'example.test'),
        phase: SessionPhase.ready,
        terminal: terminal,
      ),
    );
    sessions.activeSessionId.value = 's1';
    await tester.pumpAndSettle();
    final state = tester.state<State<TerminalView>>(find.byType(TerminalView));
    expect(
      tester
          .widgetList<ColoredBox>(
            find.ancestor(
              of: find.byType(TerminalView),
              matching: find.byType(ColoredBox),
            ),
          )
          .any((box) => box.color == AppTheme.terminalBackground),
      isTrue,
    );
    await Get.find<SettingsController>().setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(
      tester.state<State<TerminalView>>(find.byType(TerminalView)),
      same(state),
    );
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
      same(terminal),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文通用设置包含 Auto、Light、Dark', (tester) async {
    Get.locale = AppTranslations.englishLocale;
    await pumpApp(tester);
    await tester.tap(findAppIconButton('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(shadcn.Select<AppThemeMode>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Auto'), findsNWidgets(2));
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(colors(tester).brightness, Brightness.dark);
  });
}

class _DelayedSettingsRepository extends InMemorySettingsRepository {
  final saved = Completer<AppThemeMode>();

  @override
  Future<AppThemeMode> readThemeMode() => saved.future;
}
