import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:xterm/xterm.dart';

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/server_status_fixture.dart';
import 'support/shadcn_test_app.dart';

class _Session extends FakeSftpSession implements ServerStatusSource {
  int samples = 0;
  String system = 'Linux';
  final List<(int, int)> sizes = [];

  @override
  Future<ServerStatusSample> readServerStatus() async {
    samples++;
    return statusSample(
      system: system,
      systemRelease: system == 'macOS' ? 'macOS 15.0.1' : 'Ubuntu 24.04 LTS',
      measuredCpuFraction: system == 'macOS' ? .6 : null,
      uptime: 1000 + samples * 3,
      cpu: 1000 + samples * 100,
      idle: 800 + samples * 40,
      cpuCores: {
        0: CpuCounters(1000 + samples * 100, 800 + samples * 20),
        1: CpuCounters(1000 + samples * 100, 800 + samples * 70),
      },
      read: 4096 + samples * 2048,
      write: 2048 + samples * 1024,
    );
  }

  @override
  void resizeTerminal(int width, int height) => sizes.add((width, height));
}

class _Engine implements SshEngine {
  final List<_Session> sessions = [];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final session = _Session();
    sessions.add(session);
    return session;
  }
}

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDir.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(_captureDir).create(recursive: true);
      await File('$_captureDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
      'FiraCode Nerd Font Mono':
          'assets/fonts/FiraCodeNerdFontMono-Regular.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final cjk = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (cjk.existsSync()) {
      await (FontLoader(
        'PingFang SC',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 服务状态折叠、页签切换和窗口变化暂停采样并调整终端', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _Engine();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PagaShellApp(
            binding: InMemoryBinding(sshEngine: engine),
            platform: TargetPlatform.macOS,
          ),
        ),
      );
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      final sessions = Get.find<SessionController>();
      final first = await sessions.open(
        const Host(id: 'one', name: 'Linux server', hostname: 'example.test'),
        const SshCredentials.password('test-only'),
      );
      await tester.pumpAndSettle();
      final terminal = sessions.activeSession!.terminal!;
      terminal.write('user@linux:~\$ vim example.sql\r\n');
      final fullWidth = terminal.viewWidth;
      final fullHeight = terminal.viewHeight;
      expect(engine.sessions.first.samples, 0);
      final floatingToggle = find.byKey(
        const ValueKey('server-status-floating-toggle'),
      );
      expect(floatingToggle, findsOneWidget);
      expect(tester.getSize(floatingToggle).width, lessThan(50));
      expect(
        tester
            .getRect(find.byType(TerminalView))
            .contains(tester.getCenter(floatingToggle)),
        isTrue,
      );
      await _capture(
        tester,
        key,
        'server-status-collapsed-${locale.languageCode}-1280',
      );
      await tester.tap(findAppIconButton('展开服务状态'.tr));
      await tester.pumpAndSettle();
      expect(engine.sessions.first.samples, 1);
      expect(find.text('Ubuntu 24.04 LTS'), findsOneWidget);
      expect(terminal.viewWidth, lessThan(fullWidth));
      expect(terminal.viewHeight, fullHeight);
      expect(engine.sessions.first.sizes.last.$1, terminal.viewWidth);
      expect(engine.sessions.first.sizes.last.$2, terminal.viewHeight);
      final terminalBounds = tester.getRect(find.byType(TerminalView));
      final statusBounds = tester.getRect(
        find.byKey(const ValueKey('server-status-details')),
      );
      expect(statusBounds.left, greaterThanOrEqualTo(terminalBounds.right));
      expect(statusBounds.height, greaterThanOrEqualTo(terminalBounds.height));
      expect(floatingToggle, findsNothing);
      expect(find.text('磁盘占用'.tr), findsOneWidget);
      expect(find.text('网络 I/O'.tr), findsOneWidget);
      for (final bar
          in find.byType(shadcn.LinearProgressIndicator).evaluate()) {
        expect(
          tester.getSize(find.byWidget(bar.widget)).width,
          greaterThan(100),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(engine.sessions.first.samples, 2);
      expect(find.text('60.0%'), findsOneWidget);
      await _capture(tester, key, 'server-status-${locale.languageCode}-1280');
      expect(find.text('CPU 0'), findsNothing);
      await tester.tap(findAppIconButton('展开 CPU 核心'.tr));
      await tester.pumpAndSettle();
      expect(find.text('CPU 0'), findsOneWidget);
      expect(find.text('CPU 1'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('30.0%'), findsOneWidget);
      expect(find.text('60.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        key,
        'server-status-cpu-cores-${locale.languageCode}-1280',
      );
      await tester.tap(findAppIconButton('折叠 CPU 核心'.tr));
      await tester.pumpAndSettle();
      expect(find.text('CPU 0'), findsNothing);
      await tester.tap(findAppIconButton('展开 CPU 核心'.tr));
      await tester.pumpAndSettle();
      await tester.tap(findAppIconButton('折叠服务状态'.tr));
      await tester.pumpAndSettle();
      expect(terminal.viewWidth, fullWidth);
      expect(terminal.viewHeight, fullHeight);
      expect(find.byKey(const ValueKey('server-status-details')), findsNothing);
      expect(floatingToggle, findsOneWidget);
      await _capture(
        tester,
        key,
        'server-status-collapsed-after-${locale.languageCode}-1280',
      );
      await tester.pump(const Duration(seconds: 6));
      expect(engine.sessions.first.samples, 2);
      await tester.tap(findAppIconButton('展开服务状态'.tr));
      await tester.pumpAndSettle();
      expect(engine.sessions.first.samples, 3);
      expect(find.text('CPU 0'), findsOneWidget);

      final second = await sessions.open(
        const Host(id: 'two', name: 'Other server', hostname: 'other.test'),
        const SshCredentials.password('test-only'),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(engine.sessions.first.samples, 3);
      expect(engine.sessions.last.samples, 0);
      engine.sessions.first.system = 'macOS';
      sessions.activate(first);
      await tester.pumpAndSettle();
      expect(engine.sessions.first.samples, 4);
      expect(find.text('macOS 15.0.1'), findsOneWidget);
      expect(find.text('Macintosh HD'), findsOneWidget);
      expect(find.text('/'), findsNothing);
      expect(find.text('60.0%'), findsOneWidget);
      await _capture(
        tester,
        key,
        'server-status-macos-${locale.languageCode}-1280',
      );
      expect(findAppIconButton('折叠服务状态'.tr).hitTestable(), findsOneWidget);
      // 中等窗口保留右侧面板；窄窗口自动折叠并暂停采样。
      tester.view.physicalSize = const Size(1000, 680);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'server-status-${locale.languageCode}-1000');
      tester.view.physicalSize = const Size(640, 600);
      await tester.pumpAndSettle();
      expect(floatingToggle, findsOneWidget);
      expect(find.byKey(const ValueKey('server-status-details')), findsNothing);
      await _capture(tester, key, 'server-status-${locale.languageCode}-640');
      tester.view.physicalSize = const Size(640, 360);
      await tester.pumpAndSettle();
      final before = engine.sessions.first.samples;
      await tester.pump(const Duration(seconds: 6));
      expect(engine.sessions.first.samples, before);
      expect(tester.takeException(), isNull);
      expect(find.byType(TerminalView, skipOffstage: false), findsNWidgets(2));
      tester.view.physicalSize = const Size(1000, 680);
      await tester.pumpAndSettle();
      expect(engine.sessions.first.samples, before + 1);
      expect(findAppIconButton('折叠服务状态'.tr).hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await sessions.close(first);
        await sessions.close(second);
      });
      await tester.pumpAndSettle();
    });
  }
}
