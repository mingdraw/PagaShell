import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/rdp/rdp_network_stats.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/rdp/rdp_network_indicator.dart';

import 'support/fake_app_window.dart';
import 'support/fake_rdp_engine.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _NetworkFakeRdpSession extends FakeRdpSession
    implements RdpNetworkSession {
  final _networkController = StreamController<RdpNetworkStats>.broadcast();
  RdpNetworkStats? _latest;
  final qualityModes = <RdpQualityMode>[];

  void emitStats(RdpNetworkStats stats) {
    _latest = stats;
    _networkController.add(stats);
  }

  @override
  RdpNetworkStats? get latestNetworkStats => _latest;

  @override
  Stream<RdpNetworkStats> get networkStats => _networkController.stream;

  @override
  Future<void> setQualityMode(RdpQualityMode mode) async {
    qualityModes.add(mode);
    final current = _latest ?? const RdpNetworkStats();
    final tier = switch (mode) {
      RdpQualityMode.high => RdpQualityTier.high,
      RdpQualityMode.balanced => RdpQualityTier.balanced,
      RdpQualityMode.low => RdpQualityTier.low,
      RdpQualityMode.auto => current.qualityTier,
    };
    emitStats(
      RdpNetworkStats(
        rttMs: current.rttMs,
        throughputKbps: current.throughputKbps,
        bandwidthKbps: current.bandwidthKbps,
        packetLossPermille: current.packetLossPermille,
        fps: current.fps,
        signalLevel: current.signalLevel,
        qualityTier: tier,
        qualityMode: mode,
        transport: current.transport,
      ),
    );
  }

  @override
  Future<void> close() async {
    unawaited(_networkController.close());
    await super.close();
  }
}

Future<void> _sendFrame(
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
  await tester.pump();
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find
        .text('RDP · $width × $height', skipOffstage: false)
        .evaluate()
        .isNotEmpty) {
      return;
    }
  }
  fail('No $width × $height frame was displayed');
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  test('RdpNetworkStats 格式化延迟、速率、丢包与自适应状态', () {
    const empty = RdpNetworkStats();
    expect(empty.formattedLatency, '-- ms');
    expect(empty.compactLatency, '--');
    expect(empty.formattedThroughput, '0 Kbps');
    expect(empty.formattedPacketLoss, '--');
    expect(empty.isAutoAdapted, isFalse);

    const adapted = RdpNetworkStats(
      rttMs: 165,
      throughputKbps: 1850,
      bandwidthKbps: 12500,
      packetLossPermille: 24,
      fps: 28,
      signalLevel: 2,
      qualityTier: RdpQualityTier.balanced,
      qualityMode: RdpQualityMode.auto,
      transport: RdpTransportKind.udp,
    );
    expect(adapted.formattedLatency, '165 ms');
    expect(adapted.compactLatency, '165ms');
    expect(adapted.formattedThroughput, '1.85 Mbps');
    expect(adapted.formattedBandwidth, '12.5 Mbps');
    expect(adapted.formattedPacketLoss, '2.4%');
    expect(adapted.isAutoAdapted, isTrue);
  });

  testWidgets('RDP 标题工具栏显示信号图标、延迟与自动降质状态，并可切换画质策略', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = _NetworkFakeRdpSession();
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(session: session, active: true, onError: (_) {}),
      ),
    );
    await tester.pump();
    await _sendFrame(tester, session, 1280, 800);

    expect(find.byKey(const ValueKey('rdp-network-badge')), findsOneWidget);
    expect(find.text('-- ms'), findsOneWidget);

    session.emitStats(
      const RdpNetworkStats(
        rttMs: 24,
        throughputKbps: 3200,
        bandwidthKbps: 20000,
        packetLossPermille: 0,
        fps: 59,
        signalLevel: 4,
        qualityTier: RdpQualityTier.high,
        qualityMode: RdpQualityMode.auto,
        transport: RdpTransportKind.tcp,
      ),
    );
    await tester.pump();

    expect(find.text('24 ms'), findsOneWidget);
    expect(find.byType(RdpSignalIcon), findsOneWidget);
    expect(find.byKey(const ValueKey('rdp-network-quality-tag')), findsNothing);

    // High RTT & packet loss triggers auto quality downgrade badge.
    session.emitStats(
      const RdpNetworkStats(
        rttMs: 235,
        throughputKbps: 720,
        bandwidthKbps: 900,
        packetLossPermille: 42,
        fps: 20,
        signalLevel: 1,
        qualityTier: RdpQualityTier.low,
        qualityMode: RdpQualityMode.auto,
        transport: RdpTransportKind.udp,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('235 ms'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('rdp-network-quality-tag')),
      findsOneWidget,
    );
    expect(find.text('· 流畅'), findsOneWidget);

    // Selecting a manual quality mode forwards to the session.
    await tester.tap(find.byKey(const ValueKey('rdp-network-badge')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('画质：高画质').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.qualityModes, [RdpQualityMode.high]);
    expect(find.byKey(const ValueKey('rdp-network-quality-tag')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口标签标题栏与全屏固定栏均显示 RDP 信号图标与延迟', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final native = FakeAppWindow();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(appWindow: native),
        platform: TargetPlatform.windows,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    final desktop = _NetworkFakeRdpSession();
    desktop.emitStats(
      const RdpNetworkStats(
        rttMs: 38,
        throughputKbps: 4200,
        bandwidthKbps: 25000,
        packetLossPermille: 2,
        fps: 60,
        signalLevel: 4,
        qualityTier: RdpQualityTier.high,
        qualityMode: RdpQualityMode.auto,
        transport: RdpTransportKind.tcp,
      ),
    );
    sessions.sessions.add(
      Session(
        id: 'rdp-net',
        host: const Host(
          id: 'h-rdp',
          name: 'WinServer',
          hostname: 'win.test',
          serviceType: ServiceType.rdp,
          port: 3389,
        ),
        kind: SessionKind.remoteDesktop,
        phase: SessionPhase.ready,
        desktopSession: desktop,
      ),
    );
    sessions.activate('rdp-net');
    await tester.pump();
    await _sendFrame(tester, desktop, 1280, 800);

    // Tab title shows compact signal + latency, and RDP header bar shows full badge.
    expect(
      find.byKey(const ValueKey('rdp-tab-network-indicator')),
      findsOneWidget,
    );
    expect(find.text('38ms'), findsOneWidget);
    expect(find.text('38 ms'), findsOneWidget);

    // Enter fullscreen: fullscreen pinned toolbar displays signal + latency.
    await tester.tap(find.byKey(const ValueKey('rdp-enter-fullscreen')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rdp-fullscreen-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rdp-network-badge')), findsOneWidget);
    expect(find.text('38 ms'), findsOneWidget);

    // Pin toolbar so it stays visible past the auto-hide timeout.
    await tester.tap(find.byKey(const ValueKey('rdp-fullscreen-pin')));
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey('rdp-fullscreen-toolbar')),
      findsOneWidget,
    );
    expect(find.text('38 ms'), findsOneWidget);

    // Unpin and let it auto-hide: collapsed reveal handle keeps original minimal style.
    await tester.tap(find.byKey(const ValueKey('rdp-fullscreen-pin')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('rdp-fullscreen-reveal')), findsOneWidget);
    expect(find.byKey(const ValueKey('rdp-network-badge')), findsNothing);
    expect(find.text('38ms'), findsNothing);
    expect(find.text('38 ms'), findsNothing);

    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('英文模式下网络提示与画质标签完整本地化', () {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = const Locale('en', 'US');
    const stats = RdpNetworkStats(
      rttMs: 130,
      throughputKbps: 1500,
      bandwidthKbps: 2000,
      packetLossPermille: 18,
      fps: 30,
      signalLevel: 2,
      qualityTier: RdpQualityTier.balanced,
      qualityMode: RdpQualityMode.auto,
      transport: RdpTransportKind.udp,
    );
    final tooltip = rdpNetworkTooltip(stats);
    expect(tooltip, contains('Fair signal · UDP'));
    expect(tooltip, contains('Latency: 130 ms · Loss: 1.8%'));
    expect(tooltip, contains('Speed: 1.50 Mbps / 2.00 Mbps'));
    expect(tooltip, isNot(contains('Frame rate')));
    expect(tooltip, isNot(contains('30 FPS')));
    expect(
      tooltip,
      contains('Quality: Balanced (Auto-adapted for stable FPS)'),
    );

    // Idle screen displays clear Idle state + peak bandwidth without FPS.
    const idleWithPeak = RdpNetworkStats(
      rttMs: 12,
      throughputKbps: 0,
      bandwidthKbps: 14500,
      packetLossPermille: 0,
      fps: 0,
      signalLevel: 4,
      qualityTier: RdpQualityTier.high,
      qualityMode: RdpQualityMode.auto,
      transport: RdpTransportKind.tcp,
    );
    final enIdle = rdpNetworkTooltip(idleWithPeak);
    expect(enIdle, contains('Latency: 12 ms · Loss: 0.0%'));
    expect(enIdle, contains('Speed: Idle (peak 14.5 Mbps)'));
    expect(enIdle, isNot(contains('Frame rate')));

    Get.locale = const Locale('zh', 'CN');
    final zhIdle = rdpNetworkTooltip(idleWithPeak);
    expect(zhIdle, contains('延迟：12 ms · 丢包：0.0%'));
    expect(zhIdle, contains('速率：空闲（峰值 14.5 Mbps）'));
    expect(zhIdle, isNot(contains('帧率')));
  });
}
