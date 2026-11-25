import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/presentation/ai/agent_history_dialog.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/identities/identity_manager_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/navigation/app_notice.dart';
import 'package:pagashell/presentation/rdp/rdp_certificate_prompt.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/rdp/rdp_input_queue.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:pagashell/presentation/sftp/file_browser_pane.dart';
import 'package:pagashell/presentation/terminal/docker_manager_panel.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_rdp_engine.dart';
import 'support/fixture_terminal.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _SingleComposeSource
    implements DockerManagerSource, DockerComposeActions {
  @override
  Future<List<DockerResource>> readDockerResources(
    DockerResourceKind kind,
  ) async {
    if (kind != DockerResourceKind.compose) return const [];
    return [
      DockerResource(
        kind: DockerResourceKind.compose,
        id: 'app-stack',
        name: 'app-stack',
        fields: const {
          DockerField.state: 'running',
          DockerField.status: 'running(1)',
        },
      ),
    ];
  }

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async =>
      DockerDetails(resource);

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) async => const DockerActionResult();
}

Future<void> _emitRdpFrame(
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
    if (find.byKey(const ValueKey('rdp-desktop-image')).evaluate().isNotEmpty) {
      await tester.pump();
      return;
    }
  }
  fail('RDP frame $width x $height was not rendered');
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  testWidgets('Windows 终端内单 Ctrl 组合键（A/K/N/V）直达远端，不被壳层和终端默认快捷键劫持', (
    tester,
  ) async {
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

    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 'term-1',
        host: const Host(id: 'h1', name: 'linux-box', hostname: '10.0.0.10'),
        phase: SessionPhase.ready,
        terminal: terminal,
      ),
    );
    sessions.activate('term-1');
    await tester.pumpAndSettle();

    tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();

    Future<void> sendCtrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await sendCtrl(LogicalKeyboardKey.keyA);
    await sendCtrl(LogicalKeyboardKey.keyK);
    await sendCtrl(LogicalKeyboardKey.keyN);
    await sendCtrl(LogicalKeyboardKey.keyV);

    expect(Get.isDialogOpen, isFalse);
    expect(find.byType(HostEditDialog), findsNothing);
    expect(output, ['\x01', '\x0b', '\x0e', '\x16']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('RDP 全屏模式下全局快捷键不劫持远端输入', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final rdpSession = FakeRdpSession();
    addTearDown(rdpSession.close);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 'rdp-1',
        host: const Host(
          id: 'rdp-host',
          name: 'win-box',
          hostname: '10.0.0.20',
          port: 3389,
          serviceType: ServiceType.rdp,
        ),
        kind: SessionKind.remoteDesktop,
        phase: SessionPhase.ready,
        desktopSession: rdpSession,
      ),
    );
    sessions.activate('rdp-1');
    await tester.pump();
    await _emitRdpFrame(tester, rdpSession, 400, 300);

    // 进入全屏模式。
    await tester.tap(find.byKey(const ValueKey('rdp-enter-fullscreen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-exit-fullscreen')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(Get.isDialogOpen, isFalse);
    expect(find.byType(HostEditDialog), findsNothing);
    expect(find.byType(SettingsDialog), findsNothing);

    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  test('RdpInputQueue 慢链路下合并连续滚轮事件，不因队列溢出断连', () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final errors = <Object>[];
    final queue = RdpInputQueue(
      onError: errors.add,
      sendBatch: (_) async => fail('wheel coalescing should call its sender'),
    );

    queue.add(() async {
      sent.add('first');
      await gate.future;
    });
    for (var i = 0; i < 600; i++) {
      queue.addWheel(1, 2, (dx, dy) async => sent.add('wheel-$dx/$dy'));
    }
    queue.add(() async => sent.add('key'));

    gate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(errors, isEmpty);
    expect(sent, ['first', 'wheel-600/1200', 'key']);
  });

  testWidgets('RdpDesktopPanel 合并高频滚轮并在 16ms 后批量发送，不触发超时错误', (tester) async {
    final session = FakeRdpSession();
    addTearDown(session.close);
    final errors = <String>[];

    await tester.pumpWidget(
      ShadcnTestApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: RdpDesktopPanel(
            session: session,
            active: true,
            onError: errors.add,
          ),
        ),
      ),
    );
    await tester.pump();
    await _emitRdpFrame(tester, session, 400, 300);

    final center = tester.getCenter(
      find.byKey(const ValueKey('rdp-desktop-image')),
    );
    for (var i = 0; i < 20; i++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(3, 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(errors, isEmpty);
    final wheelEvents = session.pointers
        .where((event) => event.$4 != 0)
        .toList();
    expect(wheelEvents.map((event) => (event.$3, event.$4)), [
      (0x0300, 255),
      (0x0300, 145),
      (0x0500, 60),
    ]);
  });

  testWidgets('AI 设置页异步同步已保存协议并保持取消在左、保存在右的按钮顺序', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final aiSettings = Get.find<AiSettingsController>();
    await aiSettings.saveApi(
      format: AiApiFormat.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      defaultModel: 'claude-3-7',
      apiKey: 'sk-ant-test',
    );
    await tester.pumpAndSettle();

    unawaited(showSettingsDialog(ai: true));
    await tester.pumpAndSettle();

    expect(find.text(AiApiFormat.anthropic.label), findsOneWidget);
    final closeCenter = tester.getCenter(find.text('关闭'));
    final saveCenter = tester.getCenter(
      find.byKey(const ValueKey('ai-model-save')),
    );
    expect(closeCenter.dx, lessThan(saveCenter.dx));

    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('侧边栏删除服务与网关需二次确认，取消保留、确认删除', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final hosts = Get.find<HostController>();
    await hosts.save(
      const Host(id: 'h-del', name: 'prod-api', hostname: '10.0.1.8'),
    );
    final gateways = Get.find<GatewayController>();
    await gateways.save(
      const Host(id: 'g-del', name: 'bastion-gw', hostname: '10.0.1.9'),
    );
    await tester.pumpAndSettle();

    // 删除服务先取消再确认。
    await tester.tap(find.text('prod-api'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除服务「prod-api」？'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-confirm-delete')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(hosts.hosts.any((h) => h.id == 'h-del'), isTrue);

    await tester.tap(find.text('prod-api'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-confirm-delete')));
    await tester.pumpAndSettle();
    expect(hosts.hosts.any((h) => h.id == 'h-del'), isFalse);

    // 删除网关确认。
    await tester.tap(find.text('bastion-gw'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除网关「bastion-gw」？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-confirm-delete')));
    await tester.pumpAndSettle();
    expect(gateways.hosts.any((g) => g.id == 'g-del'), isFalse);
  });

  testWidgets('SFTP 文件列表在窄窗格下响应式隐藏更新时间和大小列，无布局溢出', (tester) async {
    final entries = [
      FileBrowserEntry(
        name: 'very-long-production-configuration-file.yaml',
        path: '/etc/very-long-production-configuration-file.yaml',
        isDir: false,
        size: 2048,
        modified: DateTime(2026, 11, 18, 10, 30),
      ),
    ];

    Widget buildAtWidth(double width) => ShadcnTestApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: 360,
          child: FileBrowserPane(
            sessionId: 's1',
            side: FileBrowserSide.remote,
            cwd: '/etc',
            entries: entries,
            loading: false,
            error: null,
            onNavigate: (_) {},
            onRefresh: () {},
            onOpen: (_) {},
            onTransfer: (_) {},
            onDrop: (_, _) {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildAtWidth(420));
    await tester.pumpAndSettle();
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('更新时间'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(buildAtWidth(300));
    await tester.pumpAndSettle();
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('更新时间'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(buildAtWidth(200));
    await tester.pumpAndSettle();
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('大小'), findsNothing);
    expect(find.text('更新时间'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('540px 最小窗口高度下历史对话与凭证管理弹窗不溢出，VNC 凭证副标题不出现多余分隔符', (tester) async {
    tester.view.physicalSize = const Size(800, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final identities = Get.find<IdentityController>();
    await identities.saveWithPassword(
      name: 'office-vnc',
      username: '',
      password: 'secret',
      serviceType: ServiceType.vnc,
    );
    await tester.pumpAndSettle();

    unawaited(showIdentityManagerDialog(tester.element(find.text('凭证'))));
    await tester.pumpAndSettle();
    expect(find.text('VNC · 密码'), findsOneWidget);
    expect(find.textContaining('VNC ·  ·'), findsNothing);
    expect(tester.takeException(), isNull);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();

    final agent = Get.find<AgentController>();
    final now = DateTime(2026, 11, 18, 12, 0);
    agent.conversations.assignAll([
      AgentConversationSummary(
        id: '00000000000000000000000000000010',
        title: '小窗高度测试对话',
        createdAt: now,
        updatedAt: now,
        model: 'gpt-4o',
        messageCount: 1,
      ),
    ]);
    unawaited(showAgentHistory(agent));
    await tester.pumpAndSettle();
    expect(find.text('小窗高度测试对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('RDP 证书变更弹窗默认折叠指纹且继续连接按钮为 DestructiveButton', (tester) async {
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpCertificateDialog(
          review: const HostKeyReview(
            presented: SshHostKey(
              hostname: 'win.test',
              port: 3389,
              keyType: 'X.509 SHA-256',
              fingerprint: 'SHA256:presented-fp',
              protocol: ServerIdentityProtocol.rdp,
            ),
            trusted: SshHostKey(
              hostname: 'win.test',
              port: 3389,
              keyType: 'X.509 SHA-256',
              fingerprint: 'SHA256:trusted-fp',
              protocol: ServerIdentityProtocol.rdp,
            ),
          ),
          onDecision: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('显示证书'), findsOneWidget);
    expect(find.text('SHA256:trusted-fp'), findsNothing);
    expect(find.text('SHA256:presented-fp'), findsNothing);
    expect(
      find.widgetWithText(shadcn.DestructiveButton, '继续连接'),
      findsOneWidget,
    );
  });

  testWidgets('折叠左侧服务栏时 ExcludeFocus 生效', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
    await tester.pumpAndSettle();

    final excludeFocus = tester.widget<ExcludeFocus>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sidebar-viewport')),
            matching: find.byType(ExcludeFocus),
          )
          .first,
    );
    expect(excludeFocus.excluding, isTrue);
  });

  testWidgets('AppNotice.success 在英文界面自动翻译并支持手动关闭按钮', (tester) async {
    Get.locale = const Locale('en', 'US');
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    AppNotice.success('命令已发送，正在读取会话输出');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Command sent. Reading terminal output.'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-notice-close')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-notice-close')));
    await tester.pumpAndSettle();
    expect(find.text('Command sent. Reading terminal output.'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('Docker Compose 更多菜单删除项包含分割线、垃圾桶图标和危险色', (tester) async {
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SizedBox(
          width: 340,
          height: 500,
          child: DockerManagerPanel(
            source: _SingleComposeSource(),
            active: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('docker-tab-compose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(
      find.byKey(const ValueKey('docker-more-compose:app-stack')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(shadcn.MenuDivider), findsOneWidget);
    expect(findAppIcon(AppIcons.trash2), findsOneWidget);
    expect(findAppIcon(AppIcons.rotateCw), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('DynamicProxyPanel 取消勾选协议后清空其端口不阻断另一启用协议的保存', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final gateways = Get.find<GatewayController>();
    const gateway = Host(
      id: 'gw-proxy',
      name: 'proxy-gw',
      hostname: '10.0.0.5',
      proxyConfig: ProxyConfig(
        httpEnabled: true,
        httpPort: 18080,
        httpsEnabled: true,
        httpsPort: 18080,
        socks5Enabled: true,
        socks5Port: 1080,
      ),
    );
    await gateways.save(gateway);
    final sessions = Get.find<SessionController>();
    sessions.openProxy(gateway);
    await tester.pumpAndSettle();

    // 清空 SOCKS5 端口后取消勾选 SOCKS5，修改 HTTP 端口仍应顺利保存。
    await tester.enterText(find.byKey(const ValueKey('proxy-SOCKS5-port')), '');
    await tester.tap(find.text('SOCKS5'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('proxy-HTTP(S)-port')),
      '18888',
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(find.text('1-65535'), findsNothing);
    final saved = gateways.hosts.singleWhere((h) => h.id == 'gw-proxy');
    expect(saved.proxyConfig.httpPort, 18888);
    expect(saved.proxyConfig.socks5Enabled, isFalse);
    expect(saved.proxyConfig.socks5Port, 1080);
  });
}
