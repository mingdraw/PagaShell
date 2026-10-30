import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/rdp/rdp_clipboard.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';

import 'support/fake_rdp_clipboard.dart';
import 'support/shadcn_test_app.dart';

void main() {
  setUp(() => Get.testMode = true);
  tearDown(() {
    Get.reset();
  });

  Future<(FakeClipboardSession, FakeLocalClipboard)> panel(
    WidgetTester tester,
  ) async {
    final local = FakeLocalClipboard();
    final session = FakeClipboardSession();
    Get.put<LocalClipboard>(local);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(
          session: session,
          active: true,
          dynamicResolution: false,
          onError: (error) => fail(error),
        ),
      ),
    );
    await tester.pump();
    session.operations.clear();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await session.close();
    });
    return (session, local);
  }

  testWidgets('macOS Command+V 先同步剪贴板，再完整发送 Ctrl+V', (tester) async {
    final (session, local) = await panel(tester);
    final copied = Completer<void>();
    session.onClipboardUpdate = (_) => copied.future;
    local.copy(const ClipboardContent(text: 'just copied'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(session.operations, ['clipboard']);
    copied.complete();
    await tester.pump();
    expect(session.operations, [
      'clipboard',
      'key:29:true:false',
      'key:47:true:false',
      'key:47:false:false',
      'key:29:false:false',
    ]);
    expect(session.clipboardChanges.last.text, 'just copied');
    expect(session.keys.any((key) => key.$3), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS Command+C/X 映射复制剪切，普通 Command 组合仍转发', (tester) async {
    final (session, _) = await panel(tester);
    for (final key in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyX]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    }
    await tester.pump();
    expect(session.keys, [
      (0x1d, true, false),
      (0x2e, true, false),
      (0x2e, false, false),
      (0x1d, false, false),
      (0x1d, true, false),
      (0x2d, true, false),
      (0x2d, false, false),
      (0x1d, false, false),
    ]);
    session.keys.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(session.keys, [
      (0x5b, true, true),
      (0x13, true, false),
      (0x13, false, false),
      (0x5b, false, true),
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'Windows/Linux Ctrl+V 在按键松开后仍等待最新剪贴板',
    (tester) async {
      final (session, local) = await panel(tester);
      local.copy(const ClipboardContent(files: ['/tmp/new.txt']));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(session.operations, [
        'key:29:true:false',
        'clipboard',
        'key:47:true:false',
        'key:47:false:false',
        'key:29:false:false',
      ]);
      expect(session.clipboardChanges.last.files, ['/tmp/new.txt']);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets('切到本机应用后仍接收延迟返回的远端文字和文件', (tester) async {
    final (session, local) = await panel(tester);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    session.clipboardOutput.add(
      const RdpClipboardEvent(kind: RdpClipboardEventKind.receiving),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'delayed gateway text'),
      ),
    );
    await tester.pump();
    expect(local.current.content.text, 'delayed gateway text');
    expect(session.clipboardActive, [true]);
    // Covering/minimizing the window can produce hidden after inactive.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(kind: RdpClipboardEventKind.receiving, total: 20),
    );
    await tester.pump(const Duration(seconds: 2));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.files,
        content: ClipboardContent(files: ['/tmp/cache/delayed.txt']),
      ),
    );
    await tester.pump();
    expect(local.current.content.files, ['/tmp/cache/delayed.txt']);
    expect(session.clipboardChanges, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.clipboardChanges, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('挂起应用会停用通道，恢复后重新激活', (tester) async {
    final (session, local) = await panel(tester);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(session.clipboardActive, [true, false]);
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'hidden remote'),
      ),
    );
    await tester.pump();
    expect(local.current.content.text, 'initial');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.clipboardActive, [true, false, true]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('传输进度覆盖桌面而不改变视口，取消保持会话', (tester) async {
    final (session, _) = await panel(tester);
    session.output.add(
      RdpFrame(width: 64, height: 32, rgba: Uint8List(64 * 32 * 4)),
    );
    await tester.pump();
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(FittedBox).evaluate().isNotEmpty) break;
    }
    final viewport = tester.getSize(find.byType(FittedBox));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.receiving,
        transferred: 25,
        total: 100,
      ),
    );
    await tester.pump();
    expect(find.text('正在接收剪贴板文件（25%）'), findsOneWidget);
    expect(tester.getSize(find.byType(FittedBox)), viewport);
    await tester.tap(find.byKey(const ValueKey('rdp-clipboard-cancel')));
    await tester.pump();
    expect(find.text('正在接收剪贴板文件（25%）'), findsNothing);
    expect(session.cancelledTransfers, 1);
    expect(session.closes, 0);
    expect(find.text('发送文本'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
