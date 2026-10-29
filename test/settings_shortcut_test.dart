import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';

void main() {
  tearDown(Get.reset);

  for (final focus in ['工作区', '搜索框', '终端']) {
    testWidgets('$focus 聚焦时设置快捷键打开通用设置且不输入逗号', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();

      final terminalOutput = <String>[];
      EditableText? searchInput;
      if (focus == '搜索框') {
        await tester.tap(find.byType(EditableText).first);
        await tester.pumpAndSettle();
        searchInput = tester.widget<EditableText>(
          find.byType(EditableText).first,
        );
        expect(searchInput.focusNode.hasFocus, isTrue);
      } else if (focus == '终端') {
        final terminal = Terminal()..onOutput = terminalOutput.add;
        final sessions = Get.find<SessionController>();
        sessions.sessions.add(
          Session(
            id: 'terminal',
            host: const Host(
              id: 'terminal',
              name: 'terminal',
              hostname: 'fixture.invalid',
            ),
            phase: SessionPhase.ready,
            terminal: terminal,
          ),
        );
        sessions.activate('terminal');
        await tester.pumpAndSettle();
        final view = tester.widget<TerminalView>(find.byType(TerminalView));
        view.focusNode!.requestFocus();
        await tester.pumpAndSettle();
        expect(view.focusNode!.hasFocus, isTrue);
      }

      Future<void> openSettings() async {
        const modifier = LogicalKeyboardKey.metaLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma, character: ',');
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      await openSettings();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(Get.isDialogOpen, isTrue);
      expect(find.text('通用'), findsOneWidget);
      expect(find.text('主题模式'), findsOneWidget);
      expect(terminalOutput, isEmpty);
      expect(searchInput?.controller.text ?? '', isEmpty);

      await openSettings();
      expect(find.byType(SettingsDialog), findsOneWidget);
      AppNavigation.closeDialog<void>();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
      await openSettings();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      AppNavigation.closeDialog<void>();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('macOS 原生设置菜单打开同一弹框，重复操作不叠加', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PagaShellApp(binding: InMemoryBinding()));
    await tester.pumpAndSettle();

    Future<void> nativeOpenSettings() async {
      const codec = StandardMethodCodec();
      final response = tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            'pagashell/window',
            codec.encodeMethodCall(const MethodCall('showSettings')),
            null,
          );
      await tester.pumpAndSettle();
      expect(codec.decodeEnvelope((await response)!), isNull);
    }

    await nativeOpenSettings();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    await nativeOpenSettings();
    expect(find.byType(SettingsDialog), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    await nativeOpenSettings();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });
}
