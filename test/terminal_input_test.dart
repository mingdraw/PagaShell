import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';

void main() {
  tearDown(Get.reset);

  testWidgets('Windows 新终端接管原有焦点并接收文本、输入法和 Enter', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(),
        platform: TargetPlatform.windows,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();

    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 'input',
        host: const Host(
          id: 'input',
          name: 'input',
          hostname: 'fixture.invalid',
        ),
        phase: SessionPhase.ready,
        terminal: terminal,
      ),
    );
    sessions.activate('input');
    await tester.pumpAndSettle();

    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.focusNode!.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    // Windows 原生输入插件拒绝缺少 viewId 的客户端；测试键盘默认不会检查。
    expect(tester.testTextInput.setClientArgs!['viewId'], tester.view.viewId);
    tester.testTextInput.enterText('echo ');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(output.join(), 'echo ');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(output.join(), 'echo 中文\r');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
