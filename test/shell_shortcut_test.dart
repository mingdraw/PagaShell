import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';

void main() {
  tearDown(Get.reset);

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final focus in ['工作区', '搜索框', '终端', '页面外焦点']) {
      testWidgets('$platform $focus 快速连接、新建和设置快捷键可用，W 组合键不关标签', (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          PagaShellApp(binding: InMemoryBinding(), platform: platform),
        );
        await tester.pumpAndSettle();

        final modifierLabel = platform == TargetPlatform.macOS
            ? '⌘'
            : 'Ctrl + ';
        for (final key in ['K', 'N']) {
          expect(find.text('$modifierLabel$key'), findsOneWidget);
        }
        expect(find.text('${modifierLabel}W'), findsNothing);

        final sessions = Get.find<SessionController>();
        final output = <String>[];
        final terminal = Terminal()..onOutput = output.add;
        if (focus == '终端') {
          sessions.sessions.add(_session('active', terminal: terminal));
          sessions.activate('active');
          await tester.pumpAndSettle();
        }

        Future<void> restoreFocus() async {
          if (focus == '搜索框') {
            await tester.tap(find.byType(EditableText).first);
          } else if (focus == '终端') {
            tester
                .widget<TerminalView>(find.byType(TerminalView))
                .focusNode!
                .requestFocus();
          } else if (focus == '页面外焦点') {
            FocusManager.instance.rootScope.requestFocus();
          }
          await tester.pumpAndSettle();
        }

        Future<void> shortcut(LogicalKeyboardKey key) async {
          final modifier = platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft;
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
        }

        await restoreFocus();
        await shortcut(LogicalKeyboardKey.keyK);
        expect(find.text('输入服务名称 / 地址，回车连接…'), findsWidgets);
        expect(Get.isDialogOpen, isTrue);

        // 模态弹框内不叠加新弹框，也不关闭底层会话。
        await shortcut(LogicalKeyboardKey.keyN);
        await shortcut(LogicalKeyboardKey.keyW);
        expect(find.byType(HostEditDialog), findsNothing);
        expect(sessions.sessions.length, focus == '终端' ? 1 : 0);
        AppNavigation.closeDialog<void>();
        await tester.pumpAndSettle();

        await restoreFocus();
        await shortcut(LogicalKeyboardKey.comma);
        expect(find.byType(SettingsDialog), findsOneWidget);
        AppNavigation.closeDialog<void>();
        await tester.pumpAndSettle();

        await restoreFocus();
        await shortcut(LogicalKeyboardKey.keyN);
        expect(find.byType(HostEditDialog), findsOneWidget);
        expect(Get.isDialogOpen, isTrue);
        AppNavigation.closeDialog<void>();
        await tester.pumpAndSettle();

        if (sessions.sessions.isEmpty) {
          sessions.sessions.add(_session('active', terminal: terminal));
        }
        sessions.sessions.add(_session('other'));
        sessions.activate('active');
        await tester.pumpAndSettle();
        await restoreFocus();
        expect(output, isEmpty);
        await shortcut(LogicalKeyboardKey.keyW);
        expect(sessions.sessions.map((session) => session.id), [
          'active',
          'other',
        ]);
        expect(sessions.activeSessionId.value, 'active');
        expect(Get.isDialogOpen, isFalse);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).first)
              .controller
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$platform Ctrl+W 及重复按键发送到终端，保持当前标签', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        PagaShellApp(binding: InMemoryBinding(), platform: platform),
      );
      await tester.pumpAndSettle();
      final sessions = Get.find<SessionController>();
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      sessions.sessions.addAll([
        _session('active', terminal: terminal),
        _session('other'),
      ]);
      sessions.activate('active');
      await tester.pumpAndSettle();
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      const modifier = LogicalKeyboardKey.controlLeft;

      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(sessions.sessions.map((session) => session.id), [
        'active',
        'other',
      ]);
      expect(sessions.activeSessionId.value, 'active');
      expect(output, ['\x17', '\x17', '\x17']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('macOS 原生菜单调用相同命令，弹框内不叠加或关闭底层标签', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    final sessions = Get.find<SessionController>();
    sessions.sessions.addAll([_session('active'), _session('other')]);
    sessions.activate('active');
    await tester.pumpAndSettle();

    Future<void> nativeCommand(String method) async {
      const codec = StandardMethodCodec();
      final response = tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            'pagashell/window',
            codec.encodeMethodCall(MethodCall(method)),
            null,
          );
      await tester.pumpAndSettle();
      expect(codec.decodeEnvelope((await response)!), isNull);
    }

    await nativeCommand('showQuickConnect');
    expect(find.text('输入服务名称 / 地址，回车连接…'), findsWidgets);
    await nativeCommand('newService');
    await nativeCommand('closeActiveTab');
    expect(find.byType(HostEditDialog), findsNothing);
    expect(sessions.sessions.length, 2);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
    expect(Get.isDialogOpen, isFalse);

    await nativeCommand('newService');
    expect(find.byType(HostEditDialog), findsOneWidget);
    await nativeCommand('newService');
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
    expect(Get.isDialogOpen, isFalse);
    await nativeCommand('closeActiveTab');
    expect(sessions.sessions.map((session) => session.id), ['other']);
    expect(sessions.activeSessionId.value, 'other');
    expect(tester.takeException(), isNull);
  });
}

Session _session(String id, {Terminal? terminal}) => Session(
  id: id,
  host: Host(id: id, name: id, hostname: 'fixture.invalid'),
  phase: terminal == null ? SessionPhase.failed : SessionPhase.ready,
  terminal: terminal,
);
