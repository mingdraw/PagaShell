import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/rdp/rdp_resolution.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_menu.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/rdp/rdp_surface.dart';
import 'package:pagashell/presentation/shell/widgets/sidebar.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

import 'support/fake_rdp_engine.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

const _imageKey = ValueKey('rdp-desktop-image');
const _menuKey = ValueKey('rdp-resolution-menu');
const _enterKey = ValueKey('rdp-enter-fullscreen');
const _exitKey = ValueKey('rdp-exit-fullscreen');

Future<void> _frame(
  WidgetTester tester,
  FakeRdpSession session,
  int width,
  int height,
) async {
  session.output.add(
    RdpFrame(
      width: width,
      height: height,
      rgba: Uint8List.fromList(List.filled(width * height * 4, 255)),
    ),
  );
  // Start the stream event in fake time, then wait for the real image callback.
  await tester.pump();
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final image = find.byKey(_imageKey);
    if (image.evaluate().isNotEmpty) {
      final surface =
          (tester.widget<CustomPaint>(image).painter! as RdpSurfacePainter)
              .surface;
      if (surface.width == width &&
          surface.height == height &&
          find
              .text('RDP · $width × $height', skipOffstage: false)
              .evaluate()
              .isNotEmpty) {
        await tester.pump();
        return;
      }
    }
  }
  fail('No $width × $height frame was displayed');
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(_menuKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<FakeRdpSession> _panel(
  WidgetTester tester, {
  List<String>? errors,
  VoidCallback? onToggleFullscreen,
}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = FakeRdpSession();
  await tester.pumpWidget(
    ShadcnTestApp(
      home: RdpDesktopPanel(
        session: session,
        active: true,
        onError: (error) => errors?.add(error),
        onToggleFullscreen: onToggleFullscreen,
      ),
    ),
  );
  await tester.pump();
  await _frame(tester, session, 1280, 800);
  return session;
}

Future<SessionController> _shell(
  WidgetTester tester,
  TargetPlatform platform,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    PagaShellApp(binding: InMemoryBinding(), platform: platform),
  );
  await tester.pumpAndSettle();
  return Get.find<SessionController>();
}

Future<FakeRdpSession> _desktop(
  WidgetTester tester,
  SessionController sessions, {
  bool fixedResolution = true,
}) async {
  final desktop = FakeRdpSession();
  sessions.sessions.add(
    Session(
      id: 'desktop',
      host: const Host(
        id: 'w',
        name: 'Windows',
        hostname: 'windows.test',
        serviceType: ServiceType.rdp,
        port: 3389,
      ),
      kind: SessionKind.remoteDesktop,
      phase: SessionPhase.ready,
      desktopSession: desktop,
    ),
  );
  sessions.activate('desktop');
  await tester.pump();
  await _frame(tester, desktop, 1280, 800);
  // Fullscreen lifecycle fixtures keep a fixed image; automatic resizing is
  // exercised separately with explicit server frame confirmations.
  if (fixedResolution) await _choose(tester, '1280 × 800');
  return desktop;
}

class _NativeWindow {
  final requests = <bool>[];
  bool fullscreen = false;
  bool emitEvents = true;
  bool failEnter = false;
  bool failExit = false;

  void event(bool entered) {
    fullscreen = entered;
    for (final listener in windowManager.listeners) {
      if (entered) {
        listener.onWindowEnterFullScreen();
      } else {
        listener.onWindowLeaveFullScreen();
      }
    }
  }

  void install(WidgetTester tester) {
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'isFullScreen') return fullscreen;
      if (call.method == 'setFullScreen') {
        final target =
            (call.arguments as Map<Object?, Object?>)['isFullScreen']! as bool;
        requests.add(target);
        if (target ? failEnter : failExit) {
          throw PlatformException(code: 'test-window-error');
        }
        fullscreen = target;
        if (emitEvents) event(target);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  test('自适应尺寸满足协议范围、偶数宽度和客户端像素上限', () {
    expect(
      RdpResolution.fromViewport(1367.8, 767.9),
      const RdpResolution(1366, 767),
    );
    expect(RdpResolution.fromViewport(100, 100), const RdpResolution(200, 200));
    final large = RdpResolution.fromViewport(16000, 12000);
    expect(large.width.isEven, isTrue);
    expect(large.width * large.height, lessThanOrEqualTo(16777216));
    expect(large.width, inInclusiveRange(200, 8192));
    expect(large.height, inInclusiveRange(200, 8192));
    expect(RdpResolution.presets, contains(const RdpResolution(3840, 2160)));
  });

  testWidgets('分辨率菜单请求远端调整并等待实际尺寸帧，保留连接', (tester) async {
    final errors = <String>[];
    final session = await _panel(tester, errors: errors);
    await _choose(tester, '1920 × 1080');
    expect(session.resizes, [(1920, 1080)]);
    expect(find.text('RDP · 1280 × 800'), findsOneWidget);
    await _frame(tester, session, 1920, 1080);
    expect(find.text('RDP · 1920 × 1080'), findsOneWidget);
    expect(
      tester.widget<AppMenuButton<String>>(find.byKey(_menuKey)).selectedValue,
      '1920x1080',
    );
    expect(find.byType(shadcn.CircularProgressIndicator), findsNothing);
    expect(errors, isEmpty);
    expect(session.closes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持、尺寸拒绝和未确认分辨率均提示并保持桌面可操作', (tester) async {
    final errors = <String>[];
    final session = await _panel(tester, errors: errors);
    session.onResize = (_, _) async => false;
    await _choose(tester, '1920 × 1080');
    expect(find.text('远端不支持动态分辨率，已保留当前画面'), findsOneWidget);
    expect(
      tester.widget<AppMenuButton<String>>(find.byKey(_menuKey)).selectedValue,
      '1280x800',
    );
    session.onResize = (_, _) async =>
        throw const SshEngineException('远端不支持所选分辨率，请选择较小的尺寸');
    await _choose(tester, '3840 × 2160');
    expect(find.text('远端不支持所选分辨率，请选择较小的尺寸'), findsOneWidget);
    session.onResize = (_, _) async => true;
    await _choose(tester, '1920 × 1080');
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(find.text('远端未确认分辨率调整，已保留当前画面'), findsOneWidget);
    expect(find.byKey(_imageKey), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(_imageKey)));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(session.keys, contains((0x1e, true, false)));
    expect(errors, isEmpty);
    expect(session.closes, 0);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认自适应窗口合并连续变化，固定模式不跟随窗口且无发送文本入口', (tester) async {
    final session = await _panel(tester);
    expect(
      tester.widget<AppMenuButton<String>>(find.byKey(_menuKey)).selectedValue,
      'auto',
    );
    expect(find.text('自适应窗口'), findsOneWidget);
    expect(find.text('发送文本'), findsNothing);
    expect(find.text('Ctrl+Alt+Del'), findsOneWidget);
    expect(find.byKey(_enterKey), findsOneWidget);
    expect(session.resizes, isEmpty);
    await tester.pump(const Duration(milliseconds: 349));
    expect(session.resizes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(session.resizes, hasLength(1));
    var requested = session.resizes.last;
    final fitted = find
        .ancestor(of: find.byKey(_imageKey), matching: find.byType(FittedBox))
        .first;
    final viewport = tester.getSize(fitted);
    final target = RdpResolution.fromViewport(viewport.width, viewport.height);
    expect(requested, (target.width, target.height));
    await _frame(tester, session, requested.$1, requested.$2);
    for (final width in [900.0, 1000.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(session.resizes, hasLength(1));
    await tester.pump(const Duration(milliseconds: 350));
    expect(session.resizes, hasLength(2));
    requested = session.resizes.last;
    expect(requested.$1, 1200);
    await _frame(tester, session, requested.$1, requested.$2);
    await _choose(tester, '1280 × 800');
    await _frame(tester, session, 1280, 800);
    final count = session.resizes.length;
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(session.resizes, hasLength(count));
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏快捷键释放远端修饰键并截获 Enter，Esc 仍发送到远端', (tester) async {
    var toggles = 0;
    final session = await _panel(tester, onToggleFullscreen: () => toggles++);
    await tester.tapAt(tester.getCenter(find.byKey(_imageKey)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(toggles, 1);
    expect(session.keys, contains((0x1d, false, false)));
    expect(session.keys, contains((0x38, false, false)));
    expect(session.keys.where((k) => k.$1 == 0x1c), isEmpty);
    expect(session.keys, contains((0x01, true, false)));
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 远程桌面聚焦时应用快捷键生效，W 组合键交给远端', (tester) async {
      final sessions = await _shell(tester, platform);
      final desktop = await _desktop(tester, sessions);
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;

      Future<void> shortcut(LogicalKeyboardKey key) async {
        await tester.tapAt(tester.getCenter(find.byKey(_imageKey)));
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      await shortcut(LogicalKeyboardKey.keyK);
      expect(find.text('输入服务名称 / 地址，回车连接…'), findsWidgets);
      AppNavigation.closeDialog<void>();
      await tester.pumpAndSettle();
      await shortcut(LogicalKeyboardKey.keyN);
      expect(find.byType(HostEditDialog), findsOneWidget);
      AppNavigation.closeDialog<void>();
      await tester.pumpAndSettle();
      await shortcut(LogicalKeyboardKey.keyW);
      expect(sessions.sessions.map((session) => session.id), ['desktop']);
      expect(sessions.activeSessionId.value, 'desktop');
      expect(desktop.closes, 0);
      expect(
        desktop.keys,
        containsAll([(0x11, true, false), (0x11, false, false)]),
      );
      expect(
        desktop.keys.where((key) => [0x25, 0x31].contains(key.$1)),
        isEmpty,
      );
      await sessions.closeAll();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform 全屏隐藏侧栏标签，悬浮框退出且保留画面和会话', (tester) async {
      final native = _NativeWindow()..install(tester);
      final sessions = await _shell(tester, platform);
      final desktop = await _desktop(tester, sessions);
      final state = tester.state(find.byType(RdpDesktopPanel));
      final sidebar = tester.state(find.byType(Sidebar));
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-input')),
        'Preserve Agent draft',
      );
      await tester.tap(find.byKey(_enterKey));
      await tester.pumpAndSettle();
      expect(native.requests, [true]);
      expect(find.byKey(_exitKey).hitTestable(), findsOneWidget);
      expect(find.byType(shadcn.TabPane<String>), findsNothing);
      expect(find.byType(Sidebar), findsNothing);
      expect(
        find.byKey(const ValueKey('agent-panel')).hitTestable(),
        findsNothing,
      );
      expect(tester.state(find.byType(RdpDesktopPanel)), same(state));
      final fitted = find
          .ancestor(of: find.byKey(_imageKey), matching: find.byType(FittedBox))
          .first;
      expect(tester.getSize(fitted), const Size(1280, 800));
      expect(tester.widget<FittedBox>(fitted).fit, BoxFit.contain);
      await _frame(tester, desktop, 1600, 900);
      expect(tester.getSize(find.byKey(_imageKey)), const Size(1600, 900));
      await tester.tap(find.byKey(_exitKey));
      await tester.pumpAndSettle();
      expect(native.requests, [true, false]);
      expect(find.byKey(_exitKey), findsNothing);
      expect(find.byType(shadcn.TabPane<String>), findsOneWidget);
      expect(tester.state(find.byType(Sidebar)), same(sidebar));
      expect(tester.state(find.byType(RdpDesktopPanel)), same(state));
      expect(find.text('RDP · 1600 × 900'), findsOneWidget);
      expect(
        tester
            .widget<AppTextFormField>(find.byKey(const ValueKey('agent-input')))
            .controller
            .text,
        'Preserve Agent draft',
      );
      expect(desktop.closes, 0);
      await sessions.closeAll();
      await tester.pumpAndSettle();
      expect(desktop.closes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('原生全屏动画期间禁止重复请求，系统退出事件恢复页签', (tester) async {
    final native = _NativeWindow()..emitEvents = false;
    native.install(tester);
    final sessions = await _shell(tester, TargetPlatform.macOS);
    await _desktop(tester, sessions);
    await tester.tap(find.byKey(_enterKey));
    await tester.pump();
    await tester.tap(find.byKey(_exitKey));
    await tester.pump();
    expect(native.requests, [true]);
    native.event(true);
    await tester.pumpAndSettle();
    native.event(false);
    await tester.pumpAndSettle();
    expect(find.byKey(_exitKey), findsNothing);
    expect(find.byType(shadcn.TabPane<String>), findsOneWidget);
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文小窗口自适应分辨率跟随全屏进出且控件可见', (tester) async {
    final native = _NativeWindow()..install(tester);
    final sessions = await _shell(tester, TargetPlatform.windows);
    tester.view.physicalSize = const Size(800, 600);
    unawaited(Get.updateLocale(const Locale('en', 'US')));
    await tester.pumpAndSettle();
    final desktop = await _desktop(tester, sessions, fixedResolution: false);
    expect(find.text('Fit to window').hitTestable(), findsOneWidget);
    expect(find.text('Send text'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    var requested = desktop.resizes.last;
    expect(requested.$1, lessThan(800));
    expect(requested.$2, lessThan(600));
    await _frame(tester, desktop, requested.$1, requested.$2);
    await tester.tap(find.byKey(_enterKey));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktop.resizes.last, (800, 600));
    await _frame(tester, desktop, 800, 600);
    expect(find.text('Exit full screen').hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(_exitKey));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    requested = desktop.resizes.last;
    expect(requested.$1, lessThan(800));
    expect(requested.$2, lessThan(600));
    await _frame(tester, desktop, requested.$1, requested.$2);
    expect(find.text('Fit to window').hitTestable(), findsOneWidget);
    expect(native.requests, [true, false]);
    expect(desktop.resizes, hasLength(3));
    expect(desktop.closes, 0);
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏命令失败可重试，退出失败保留悬浮入口', (tester) async {
    final native = _NativeWindow()..failEnter = true;
    native.install(tester);
    final sessions = await _shell(tester, TargetPlatform.windows);
    final desktop = await _desktop(tester, sessions);
    await tester.tap(find.byKey(_enterKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_exitKey), findsNothing);
    expect(find.text('无法进入全屏，请重试'), findsOneWidget);
    native.failEnter = false;
    await tester.tap(find.byKey(_enterKey));
    await tester.pumpAndSettle();
    native.failExit = true;
    await tester.tap(find.byKey(_exitKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_exitKey).hitTestable(), findsOneWidget);
    expect(find.text('无法退出全屏，请重试'), findsOneWidget);
    native.failExit = false;
    await tester.tap(find.byKey(_exitKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_exitKey), findsNothing);
    expect(desktop.closes, 0);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final change in ['close', 'fail', 'activate']) {
    testWidgets('全屏时 $change 当前桌面自动恢复普通窗口', (tester) async {
      final native = _NativeWindow()..install(tester);
      final sessions = await _shell(tester, TargetPlatform.linux);
      await _desktop(tester, sessions);
      await tester.tap(find.byKey(_enterKey));
      await tester.pumpAndSettle();
      switch (change) {
        case 'close':
          await sessions.close('desktop');
        case 'fail':
          await sessions.desktopFailed('desktop', '远程桌面已断开，请重新连接');
        case 'activate':
          sessions.sessions.add(
            const Session(
              id: 'other',
              host: Host(id: 'ssh', name: 'SSH', hostname: 'ssh.test'),
              phase: SessionPhase.failed,
              error: 'fixture',
            ),
          );
          sessions.activate('other');
      }
      await tester.pumpAndSettle();
      expect(native.requests, [true, false]);
      expect(find.byKey(_exitKey), findsNothing);
      expect(find.byType(shadcn.TabPane<String>), findsOneWidget);
      await sessions.closeAll();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
