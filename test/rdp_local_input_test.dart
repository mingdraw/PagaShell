import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';

import 'support/fake_rdp_engine.dart';
import 'support/shadcn_test_app.dart';

void main() {
  testWidgets('本机输入法仅发送提交文字，远端快捷键和释放按键保留', (tester) async {
    final session = FakeRdpSession();
    final errors = <String>[];
    Widget app({required bool active}) => ShadcnTestApp(
      home: RdpDesktopPanel(
        session: session,
        active: active,
        onError: errors.add,
      ),
    );
    await tester.pumpWidget(app(active: true));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await tester.tap(find.byKey(const ValueKey('rdp-keyboard-mode')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('本机输入法').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.testTextInput.hasAnyClients, isTrue);

    // Part of a modifier chord reached the remote before composition began.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(session.texts, isEmpty);
    expect(session.keys, [(0x2a, true, false), (0x2a, false, false)]);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中a',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(session.texts, ['中', 'a']);
    expect(session.keys, hasLength(2));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(session.keys.skip(2), [
      (0x1d, true, false),
      (0x1e, true, false),
      (0x1e, false, false),
      (0x1d, false, false),
      (0x0e, true, false),
      (0x0e, false, false),
    ]);
    expect(session.texts, ['中', 'a']);

    await tester.pumpWidget(app(active: false));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('Windows 全屏捕获转发组合键，退出后丢弃旧事件并释放修饰键', (tester) async {
    const channel = MethodChannel('pagashell/rdpKeyboard');
    final messenger = tester.binding.defaultBinaryMessenger;
    int? captureId;
    final stopped = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'captureStart') {
        captureId = call.arguments as int;
        return true;
      }
      if (call.method == 'captureStop') stopped.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final session = FakeRdpSession();
    var exits = 0;
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(
          session: session,
          active: true,
          fullscreen: true,
          onError: fail,
          onToggleFullscreen: () => exits++,
        ),
      ),
    );
    await tester.pump();
    expect(captureId, isNotNull);
    Future<void> send(int scan, bool down) async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('captureKey', [captureId, scan, down]),
        ),
        null,
      );
    }

    await send(0x15b, true); // Win+Space
    await send(0x39, true);
    await send(0x39, false);
    await send(0x15b, false);
    await send(0x1d, true); // Ctrl+Alt+Enter is handled locally.
    await send(0x38, true);
    await send(0x1c, true);
    await send(0x30, true); // Queued for an activation that has already ended.
    await tester.pump();
    expect(exits, 1);
    expect(stopped, [captureId]);
    expect(session.keys, [
      (0x5b, true, true),
      (0x39, true, false),
      (0x39, false, false),
      (0x5b, false, true),
      (0x1d, true, false),
      (0x38, true, false),
      (0x1d, false, false),
      (0x38, false, false),
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
