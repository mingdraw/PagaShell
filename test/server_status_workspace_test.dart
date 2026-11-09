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
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/terminal/server_system_logo.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/fixture_terminal.dart';
import 'support/in_memory_binding.dart';
import 'support/server_status_fixture.dart';
import 'support/shadcn_test_app.dart';

class _Session extends FakeSftpSession implements ServerStatusSource {
  int samples = 0;
  String system = 'Linux';
  String? systemRelease;
  Map<String, int>? networkDevices;
  Map<String, int>? diskDevices;
  List<DiskUsage>? storage;
  List<double> loadAverage = const [.5, .75, 1.25];
  bool showCpuCores = true;
  final List<(int, int)> sizes = [];

  @override
  Future<ServerStatusSample> readServerStatus() async {
    samples++;
    return statusSample(
      system: system,
      systemRelease:
          systemRelease ??
          (system == 'macOS' ? 'macOS 15.0.1' : 'Ubuntu 24.04 LTS'),
      measuredCpuFraction: system == 'macOS' ? .6 : null,
      uptime: 1000 + samples * 3,
      cpu: 1000 + samples * 100,
      idle: 800 + samples * 40,
      loadAverage: loadAverage,
      cpuCores: showCpuCores
          ? {
              0: CpuCounters(1000 + samples * 100, 800 + samples * 20),
              1: CpuCounters(1000 + samples * 100, 800 + samples * 70),
            }
          : const {},
      read: 4096 + samples * 2048,
      write: 2048 + samples * 1024,
      network: networkDevices?.map(
        (name, scale) =>
            MapEntry(name, IoCounters(samples * scale, samples * scale * 2)),
      ),
      disks: diskDevices?.map(
        (name, scale) =>
            MapEntry(name, IoCounters(samples * scale, samples * scale * 2)),
      ),
      storage: storage,
    );
  }

  @override
  void resizeTerminal(int width, int height) => sizes.add((width, height));
}

class _Engine implements SshEngine {
  final List<_Session> sessions = [];
  _Session? nextSession;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final session = nextSession ?? _Session();
    nextSession = null;
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
      'packages/shadcn_flutter/RadixIcons':
          'packages/shadcn_flutter/lib/icons/RadixIcons.otf',
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

  testWidgets('服务状态水平拖动调宽，折叠和切换页签保留宽度及终端滚动状态', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine();
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine),
          platform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Get.find<SettingsController>().sidebarVisible.value = false;
    await tester.pumpAndSettle();
    final sessions = Get.find<SessionController>();
    final first = await sessions.open(
      const Host(id: 'one', name: 'Linux server', hostname: 'example.test'),
      const SshCredentials.password('test-only'),
    );
    await tester.pumpAndSettle();
    final terminal = sessions.activeSession!.terminal!;
    terminal.writeText(List.generate(120, (i) => 'row $i\r\n').join());
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final scroll = state.widget.scrollController!;
    scroll.jumpTo(scroll.position.maxScrollExtent - 200);
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    final toggle = find.byKey(const ValueKey('terminal-toolbar-status'));
    final dragger = find.byKey(const ValueKey('terminal-side-panel-dragger'));
    final details = find.byKey(const ValueKey('server-status-details'));
    expect(dragger, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final width = tester.getSize(details).width;
    final columns = terminal.viewWidth;
    final grip = tester.getSize(
      find.descendant(of: dragger, matching: find.byType(Container)),
    );
    expect(grip.height, greaterThan(grip.width));
    await tester.dragFrom(tester.getCenter(dragger), const Offset(-100, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, greaterThan(width + 70));
    expect(terminal.viewWidth, lessThan(columns));
    expect(engine.sessions.first.sizes.last.$1, terminal.viewWidth);
    expect(
      tester.state<TerminalViewState>(find.byType(TerminalView)),
      same(state),
    );
    expect(scroll.offset, closeTo(offset, .001));
    await _capture(tester, capture, 'server-status-resized');

    await tester.dragFrom(tester.getCenter(dragger), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(details).width,
      closeTo(AppTheme.serverStatusMinWidth, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.dragFrom(tester.getCenter(dragger), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.dragFrom(tester.getCenter(dragger), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(details).width,
      closeTo(AppTheme.serverStatusMaxWidth, 1),
    );
    final preferred = tester.getSize(details).width;
    tester.view.physicalSize = const Size(620, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, lessThan(preferred));
    expect(
      tester.getRect(details).left -
          tester
              .getRect(
                find.byKey(const ValueKey('terminal-side-panel-resizable')),
              )
              .left,
      greaterThanOrEqualTo(AppTheme.terminalPaneMinWidth),
    );
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(480, 800);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(dragger, findsNothing);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, closeTo(preferred, 1));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(dragger, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, closeTo(preferred, 1));
    expect(
      tester.state<TerminalViewState>(find.byType(TerminalView)),
      same(state),
    );
    expect(scroll.offset, closeTo(offset, .001));

    await sessions.open(
      const Host(id: 'two', name: 'Other server', hostname: 'other.test'),
      const SshCredentials.password('test-only'),
    );
    await tester.pumpAndSettle();
    expect(dragger, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(details).width,
      closeTo(AppTheme.serverStatusDefaultWidth, 1),
    );
    sessions.activate(first);
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, closeTo(preferred, 1));
    expect(tester.takeException(), isNull);
    await tester.runAsync(sessions.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('服务面板动画可中途反向切换，保留宽度、终端和后台连接', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine();
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine),
          platform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Get.find<SettingsController>().sidebarVisible.value = false;
    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(
        id: 'animation',
        name: 'Status animation',
        hostname: 'example.test',
      ),
      const SshCredentials.password('test-only'),
    );
    await tester.pumpAndSettle();
    final terminal = find.byType(TerminalView);
    final state = tester.state<TerminalViewState>(terminal);
    final fullWidth = tester.getSize(terminal).width;
    final toggle = find.byKey(const ValueKey('terminal-toolbar-status'));
    final viewport = find.byKey(const ValueKey('terminal-side-panel-viewport'));
    final details = find.byKey(const ValueKey('server-status-details'));
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final partialWidth = tester.getSize(viewport).width;
    expect(partialWidth, greaterThan(0));
    expect(partialWidth, lessThan(AppTheme.serverStatusDefaultWidth));
    expect(tester.getSize(details).width, AppTheme.serverStatusDefaultWidth);
    expect(tester.getSize(terminal).width, lessThan(fullWidth));
    expect(tester.state<TerminalViewState>(terminal), same(state));
    expect(tester.takeException(), isNull);
    await _capture(tester, capture, 'server-status-opening');

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getSize(viewport).width, lessThan(partialWidth));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).width, AppTheme.serverStatusDefaultWidth);
    expect(engine.sessions, hasLength(2));
    final source = engine.sessions.last;
    expect(source.closes, 0);
    await tester.dragFrom(
      tester.getCenter(
        find.byKey(const ValueKey('terminal-side-panel-dragger')),
      ),
      const Offset(-80, 0),
    );
    await tester.pumpAndSettle();
    final preferredWidth = tester.getSize(viewport).width;
    expect(preferredWidth, greaterThan(AppTheme.serverStatusDefaultWidth));
    final samples = source.samples;
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(viewport).width, inExclusiveRange(0, preferredWidth));
    expect(tester.getSize(details).width, preferredWidth);
    await _capture(tester, capture, 'server-status-closing');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(source.samples, samples);
    expect(source.closes, 0);
    expect(tester.getSize(terminal).width, fullWidth);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).width, preferredWidth);
    expect(tester.state<TerminalViewState>(terminal), same(state));
    expect(engine.sessions, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.runAsync(sessions.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('系统减少动画时服务面板和内容立即展开收起', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _Engine()),
        platform: TargetPlatform.windows,
      ),
    );
    await tester.pumpAndSettle();
    Get.find<SettingsController>().sidebarVisible.value = false;
    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(
        id: 'reduced-motion',
        name: 'Status',
        hostname: 'example.test',
      ),
      const SshCredentials.password('test-only'),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('terminal-toolbar-status'));
    final details = find.byKey(const ValueKey('server-status-details'));
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.getSize(details).width, AppTheme.serverStatusDefaultWidth);
    await tester.pump();
    final memory = find.byKey(const ValueKey('server-status-memory-toggle'));
    await tester.tap(memory);
    await tester.pump();
    expect(find.text('Swap'), findsOneWidget);
    await tester.tap(memory);
    await tester.pump();
    expect(find.text('Swap'), findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(details, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(sessions.closeAll);
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 六张状态卡片支持核心和挂载展开、I/O 设备切换', (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _Engine();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: PagaShellApp(
            binding: InMemoryBinding(sshEngine: engine),
            platform: TargetPlatform.windows,
          ),
        ),
      );
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      Get.find<SettingsController>().sidebarVisible.value = false;
      final sessions = Get.find<SessionController>();
      await sessions.open(
        const Host(id: 'cards', name: 'Status cards', hostname: 'example.test'),
        const SshCredentials.password('test-only'),
      );
      await tester.pumpAndSettle();
      final source = engine.nextSession = _Session();
      source.systemRelease = 'Rocky Linux 10.2';
      source.networkDevices = {'eth0': 1024, 'ens192': 10240};
      source.diskDevices = {'nvme0n1': 3072, 'sdb': 24576};
      source.storage = const [
        DiskUsage(
          id: 'nvme0n1',
          name: 'nvme0n1',
          devices: ['nvme0n1'],
          total: 4 * 1024 * 1024 * 1024,
          used: 1024 * 1024 * 1024,
          available: 3 * 1024 * 1024 * 1024,
          filesystems: [
            FilesystemUsage(
              mount: '/',
              total: 2 * 1024 * 1024 * 1024,
              used: 512 * 1024 * 1024,
              available: 1536 * 1024 * 1024,
            ),
            FilesystemUsage(
              mount: '/data with spaces',
              total: 2 * 1024 * 1024 * 1024,
              used: 512 * 1024 * 1024,
              available: 1536 * 1024 * 1024,
            ),
          ],
        ),
        DiskUsage(
          id: 'sdb',
          name: 'Backup SSD',
          devices: ['sdb'],
          total: 2 * 1024 * 1024 * 1024,
          used: 1024 * 1024 * 1024,
          available: 1024 * 1024 * 1024,
          filesystems: [
            FilesystemUsage(
              mount: '/backup',
              total: 2 * 1024 * 1024 * 1024,
              used: 1024 * 1024 * 1024,
              available: 1024 * 1024 * 1024,
            ),
          ],
        ),
      ];
      await tester.tap(findAppIconButton('展开服务状态'.tr));
      await tester.pumpAndSettle();
      for (final id in [
        'basic',
        'cpu',
        'memory',
        'storage',
        'network',
        'disk-io',
      ]) {
        final card = find.byKey(ValueKey('server-status-card-$id'));
        expect(tester.widget(card), isA<shadcn.Card>());
        expect(
          find.descendant(
            of: card,
            matching: find.byType(id == 'basic' ? ServerSystemLogo : AppIcon),
          ),
          findsWidgets,
        );
      }
      expect(find.text('Rocky Linux 10.2'), findsOneWidget);
      expect(find.text('x86_64'), findsOneWidget);
      final loadToggle = find.byKey(
        const ValueKey('server-status-load-toggle'),
      );
      final summary = find.byKey(const ValueKey('server-status-load-summary'));
      final basic = find.byKey(const ValueKey('server-status-card-basic'));
      final collapsedLoadHeight = tester.getSize(basic).height;
      expect(summary, findsOneWidget);
      expect(find.byKey(const ValueKey('server-status-load-1')), findsNothing);
      expect(find.text('@minutes 分钟'.trParams({'minutes': '1'})), findsNothing);
      final summaryProgress = find.descendant(
        of: summary,
        matching: find.byType(shadcn.LinearProgressIndicator),
      );
      expect(
        tester.widget<shadcn.LinearProgressIndicator>(summaryProgress).value,
        .25,
      );
      expect(
        tester.getCenter(summaryProgress).dy,
        closeTo(tester.getCenter(find.text('整体负载'.tr)).dy, 1),
      );
      expect(find.byKey(const ValueKey('server-status-load-5')), findsNothing);
      expect(find.byKey(const ValueKey('server-status-load-15')), findsNothing);
      expect(find.textContaining('100% ='), findsNothing);
      await tester.tap(loadToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final expandingLoadHeight = tester.getSize(basic).height;
      expect(expandingLoadHeight, greaterThan(collapsedLoadHeight));
      await tester.pumpAndSettle();
      expect(tester.getSize(basic).height, greaterThan(expandingLoadHeight));
      expect(summary, findsNothing);
      for (final (minutes, percentage, fraction) in [
        (1, '25.0%', .25),
        (5, '37.5%', .375),
        (15, '62.5%', .625),
      ]) {
        final load = find.byKey(ValueKey('server-status-load-$minutes'));
        expect(
          find.descendant(of: load, matching: find.text(percentage)),
          findsOneWidget,
        );
        final progress = find.descendant(
          of: load,
          matching: find.byType(shadcn.LinearProgressIndicator),
        );
        expect(
          tester.widget<shadcn.LinearProgressIndicator>(progress).value,
          fraction,
        );
        expect(
          shadcn.ComponentTheme.maybeOf<shadcn.LinearProgressIndicatorTheme>(
            tester.element(progress),
          )!.color,
          AppTheme.serverStatusLoadColor,
        );
      }
      final heading = find.byKey(const ValueKey('server-status-heading'));
      final updated = find.byKey(const ValueKey('server-status-updated'));
      expect(find.descendant(of: heading, matching: updated), findsOneWidget);
      expect(
        tester.getCenter(updated).dy,
        closeTo(tester.getCenter(find.text('服务状态'.tr)).dy, 1),
      );
      expect(
        tester.getRect(basic).top,
        closeTo(tester.getRect(heading).bottom, 1),
      );
      expect(find.text('Swap'), findsNothing);
      expect(find.text('128.0 MiB / 512.0 MiB'), findsNothing);
      expect(find.text('CPU 0'), findsNothing);
      expect(find.text('/data with spaces'), findsNothing);
      await _capture(
        tester,
        capture,
        'server-status-load-expanded-${locale.languageCode}-320',
      );
      await tester.tap(loadToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey('server-status-load-5')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(summary, findsOneWidget);
      expect(find.byKey(const ValueKey('server-status-load-5')), findsNothing);
      expect(find.byKey(const ValueKey('server-status-load-15')), findsNothing);
      await _capture(
        tester,
        capture,
        'server-status-six-cards-${locale.languageCode}-320',
      );

      final memoryToggle = find.byKey(
        const ValueKey('server-status-memory-toggle'),
      );
      final memory = find.byKey(const ValueKey('server-status-card-memory'));
      final collapsedMemoryHeight = tester.getSize(memory).height;
      await tester.tap(memoryToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final expandingMemoryHeight = tester.getSize(memory).height;
      expect(expandingMemoryHeight, greaterThan(collapsedMemoryHeight));
      await tester.pumpAndSettle();
      expect(tester.getSize(memory).height, greaterThan(expandingMemoryHeight));
      expect(find.text('Swap'), findsOneWidget);
      expect(find.text('128.0 MiB / 512.0 MiB'), findsOneWidget);
      await tester.tap(memoryToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('Swap'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Swap'), findsNothing);
      expect(tester.getSize(memory).height, collapsedMemoryHeight);
      await tester.tap(memoryToggle);
      await tester.pumpAndSettle();

      final diskToggle = find.byKey(
        const ValueKey('server-status-disk-toggle-nvme0n1'),
      );
      await tester.ensureVisible(diskToggle);
      await tester.tap(diskToggle);
      await tester.pumpAndSettle();
      expect(find.text('/'), findsOneWidget);
      expect(find.text('/data with spaces'), findsOneWidget);
      expect(find.text('/backup'), findsNothing);
      final cpuToggle = find.byKey(const ValueKey('server-status-cpu-toggle'));
      await tester.ensureVisible(cpuToggle);
      await tester.tap(cpuToggle);
      await tester.pumpAndSettle();
      expect(find.text('CPU 0'), findsOneWidget);

      final network = find.byKey(
        const ValueKey('server-status-network-select'),
      );
      final disks = find.byKey(const ValueKey('server-status-disk-io-select'));
      void checkIoHeaders() {
        for (final (select, label) in [
          (network, '网络 I/O'),
          (disks, '磁盘 I/O'),
        ]) {
          final bounds = tester.getRect(select);
          final title = tester.getRect(find.text(label.tr));
          expect(bounds.center.dy, closeTo(title.center.dy, 1));
          expect(bounds.left, greaterThanOrEqualTo(title.right));
        }
      }

      void checkPopupWidth(Finder select, String id) {
        expect(
          tester.getSize(find.byKey(ValueKey('server-status-$id-popup'))).width,
          closeTo(tester.getSize(select).width, 1),
        );
      }

      checkIoHeaders();
      await tester.ensureVisible(network);
      await tester.tap(network);
      await tester.pumpAndSettle();
      checkPopupWidth(network, 'network');
      await tester.tap(find.text('ens192').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(disks);
      await tester.tap(disks);
      await tester.pumpAndSettle();
      checkPopupWidth(disks, 'disk-io');
      await tester.tap(find.text('sdb').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.widget<shadcn.Select<String>>(network).value, 'ens192');
      expect(tester.widget<shadcn.Select<String>>(disks).value, 'sdb');
      expect(find.text('3.3 KiB/s'), findsOneWidget);
      expect(find.text('8.0 KiB/s'), findsOneWidget);
      expect(find.text('CPU 0'), findsOneWidget);
      expect(find.text('/data with spaces'), findsOneWidget);
      await _capture(
        tester,
        capture,
        'server-status-io-selected-${locale.languageCode}',
      );

      final details = find.byKey(const ValueKey('server-status-details'));
      final dragger = find.byKey(const ValueKey('terminal-side-panel-dragger'));
      for (final width in [220.0, 520.0]) {
        await tester.dragFrom(
          tester.getCenter(dragger),
          Offset(tester.getSize(details).width - width, 0),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(details).width, closeTo(width, 1));
        expect(tester.widget<shadcn.Select<String>>(network).value, 'ens192');
        expect(tester.widget<shadcn.Select<String>>(disks).value, 'sdb');
        checkIoHeaders();
        expect(
          tester.getCenter(updated).dy,
          closeTo(tester.getCenter(find.text('服务状态'.tr)).dy, 1),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-status-card-basic')),
        );
        await tester.pumpAndSettle();
        await _capture(
          tester,
          capture,
          'server-status-cards-${locale.languageCode}-${width.toInt()}-top',
        );
        await tester.ensureVisible(disks);
        await tester.pumpAndSettle();
        await _capture(
          tester,
          capture,
          'server-status-cards-${locale.languageCode}-${width.toInt()}-io',
        );
        await tester.tap(network);
        await tester.pumpAndSettle();
        checkPopupWidth(network, 'network');
        expect(find.text('ens192').last.hitTestable(), findsOneWidget);
        await _capture(
          tester,
          capture,
          'server-status-cards-${locale.languageCode}-${width.toInt()}-select',
        );
        await tester.tap(find.text('ens192').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      source.networkDevices = {'eth0': 1024};
      source.diskDevices = {'nvme0n1': 3072};
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.widget<shadcn.Select<String>>(network).value, 'eth0');
      expect(tester.widget<shadcn.Select<String>>(disks).value, 'nvme0n1');
      source.networkDevices = {};
      source.diskDevices = {};
      source.storage = [];
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(network, findsNothing);
      expect(disks, findsNothing);
      expect(find.text('暂无可用数据'.tr), findsNWidgets(3));
      source.loadAverage = const [4, 0, 1];
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      final load = find.byKey(const ValueKey('server-status-load-summary'));
      expect(
        find.descendant(of: load, matching: find.text('200.0%')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<shadcn.LinearProgressIndicator>(
              find.descendant(
                of: load,
                matching: find.byType(shadcn.LinearProgressIndicator),
              ),
            )
            .value,
        1,
      );
      source.showCpuCores = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: load, matching: find.text('—')),
        findsOneWidget,
      );
      expect(find.text('未获取核心数，无法计算负载百分比'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(sessions.closeAll);
      await tester.pumpAndSettle();
    });

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
      terminal.writeText('user@linux:~\$ vim example.sql\r\n');
      final fullWidth = terminal.viewWidth;
      final fullHeight = terminal.viewHeight;
      expect(engine.sessions.first.samples, 0);
      final floatingToggle = find.byKey(
        const ValueKey('server-status-floating-toggle'),
      );
      final toolbarToggle = find.byKey(
        const ValueKey('terminal-toolbar-status'),
      );
      final toolbar = find.byKey(const ValueKey('terminal-toolbar'));
      expect(floatingToggle, findsNothing);
      expect(toolbarToggle, findsOneWidget);
      expect(
        tester.getRect(toolbar).contains(tester.getCenter(toolbarToggle)),
        isTrue,
      );
      expect(
        tester.getRect(toolbar).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(TerminalView)).top),
      );
      await _capture(
        tester,
        key,
        'server-status-collapsed-${locale.languageCode}-1280',
      );
      await tester.tap(findAppIconButton('展开服务状态'.tr));
      await tester.pumpAndSettle();
      final source = engine.sessions.last;
      expect(engine.sessions, hasLength(2));
      expect(source.shellStarts, 0);
      expect(source.samples, 1);
      expect(engine.sessions.first.samples, 0);
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
      expect(find.text('硬盘'.tr), findsOneWidget);
      expect(find.text('网络 I/O'.tr), findsOneWidget);
      final inlineLoad = find.descendant(
        of: find.byKey(const ValueKey('server-status-load-summary')),
        matching: find.byType(shadcn.LinearProgressIndicator),
      );
      expect(tester.getSize(inlineLoad).width, greaterThan(0));
      for (final bar
          in find.byType(shadcn.LinearProgressIndicator).evaluate()) {
        if (identical(bar, inlineLoad.evaluate().single)) continue;
        expect(
          tester.getSize(find.byWidget(bar.widget)).width,
          greaterThan(100),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(source.samples, 2);
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
      expect(toolbarToggle, findsOneWidget);
      expect(floatingToggle, findsNothing);
      await _capture(
        tester,
        key,
        'server-status-collapsed-after-${locale.languageCode}-1280',
      );
      await tester.pump(const Duration(seconds: 6));
      expect(source.samples, 2);
      await tester.tap(findAppIconButton('展开服务状态'.tr));
      await tester.pumpAndSettle();
      expect(source.samples, 3);
      expect(engine.sessions, hasLength(2));
      expect(find.text('CPU 0'), findsOneWidget);

      final second = await sessions.open(
        const Host(id: 'two', name: 'Other server', hostname: 'other.test'),
        const SshCredentials.password('test-only'),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(source.samples, 3);
      expect(engine.sessions.last.samples, 0);
      source.system = 'macOS';
      sessions.activate(first);
      await tester.pumpAndSettle();
      expect(source.samples, 4);
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
      expect(toolbarToggle, findsOneWidget);
      expect(floatingToggle, findsNothing);
      expect(find.byKey(const ValueKey('server-status-details')), findsNothing);
      await _capture(tester, key, 'server-status-${locale.languageCode}-640');
      tester.view.physicalSize = const Size(640, 360);
      await tester.pumpAndSettle();
      final before = source.samples;
      await tester.pump(const Duration(seconds: 6));
      expect(source.samples, before);
      expect(tester.takeException(), isNull);
      expect(find.byType(TerminalView, skipOffstage: false), findsNWidgets(2));
      tester.view.physicalSize = const Size(1000, 680);
      await tester.pumpAndSettle();
      expect(source.samples, before + 1);
      expect(findAppIconButton('折叠服务状态'.tr).hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        await sessions.close(first);
        await sessions.close(second);
      });
      await tester.pumpAndSettle();
    });
  }
}
