import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/shell/widgets/workspace.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

import '../test/support/fake_rdp_engine.dart';
import '../test/support/in_memory_binding.dart';

RdpFrame _frame(int width, int height) => RdpFrame(
  width: width,
  height: height,
  rgba: Uint8List.fromList(List.filled(width * height * 4, 255)),
);

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['PAGASHELL_RDP_DISPLAY_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('rdp-display-preview')),
  );
  final image = await boundary.toImage();
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/pagashell-rdp-display-$name.png',
    );
    await file.writeAsBytes(png!.buffer.asUint8List());
    debugPrint('RDP_DISPLAY_CAPTURE: ${file.path}');
  } finally {
    image.dispose();
  }
}

Future<void> _waitForWindow(WidgetTester tester, bool fullscreen) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final panel = tester.widget<RdpDesktopPanel>(find.byType(RdpDesktopPanel));
    if (await windowManager.isFullScreen() == fullscreen &&
        panel.fullscreen == fullscreen &&
        !panel.fullscreenBusy) {
      return;
    }
  }
  fail('Native full screen state was not confirmed: $fullscreen');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('原生桌面窗口全屏、悬浮退出与快捷键保持同一 RDP 会话', (tester) async {
    await windowManager.ensureInitialized();
    final originalFullscreen = await windowManager.isFullScreen();
    final originalSize = await windowManager.getSize();
    final desktop = FakeRdpSession();
    SessionController? sessions;
    try {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.show();
      await windowManager.focus();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('rdp-display-preview'),
          child: PagaShellApp(binding: InMemoryBinding()),
        ),
      );
      await tester.pumpAndSettle();
      sessions = Get.find<SessionController>();
      sessions.sessions.add(
        Session(
          id: 'desktop-fixture',
          host: const Host(
            id: 'fixture',
            name: 'Windows display test',
            hostname: 'display.test',
            serviceType: ServiceType.rdp,
            port: 3389,
          ),
          kind: SessionKind.remoteDesktop,
          phase: SessionPhase.ready,
          desktopSession: desktop,
        ),
      );
      sessions.activate('desktop-fixture');
      await tester.pump();
      desktop.output.add(_frame(1280, 800));
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byKey(const ValueKey('rdp-desktop-image'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('rdp-desktop-image')), findsOneWidget);
      await _capture(tester, 'window');
      final state = tester.state(find.byType(RdpDesktopPanel));
      await tester.tap(find.byKey(const ValueKey('rdp-enter-fullscreen')));
      await _waitForWindow(tester, true);
      expect(find.byType(shadcn.TabPane<Session>), findsNothing);
      expect(tester.getTopLeft(find.byType(Workspace)), Offset.zero);
      expect(tester.state(find.byType(RdpDesktopPanel)), same(state));
      await _capture(tester, 'fullscreen');
      await tester.tap(find.byKey(const ValueKey('rdp-exit-fullscreen')));
      await _waitForWindow(tester, false);
      expect(find.byType(shadcn.TabPane<Session>), findsOneWidget);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('rdp-desktop-image'))),
      );
      for (final expected in [true, false]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _waitForWindow(tester, expected);
      }
      expect(tester.state(find.byType(RdpDesktopPanel)), same(state));
      expect(desktop.keys.where((k) => k.$1 == 0x1c), isEmpty);
      expect(desktop.closes, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await sessions?.closeAll();
      await windowManager.setFullScreen(originalFullscreen);
      await tester.pumpAndSettle();
      if (!originalFullscreen) await windowManager.setSize(originalSize);
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
    }
  }, skip: !(Platform.isMacOS || Platform.isWindows || Platform.isLinux));
}
