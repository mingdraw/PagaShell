import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/ai/agent_history_dialog.dart';
import 'package:pagashell/presentation/components/app_markdown.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/identities/identity_manager_dialog.dart';
import 'package:pagashell/presentation/navigation/app_notice.dart';
import 'package:pagashell/presentation/rdp/rdp_certificate_prompt.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:pagashell/presentation/ssh/host_key_confirmation.dart';
import 'package:pagashell/presentation/terminal/docker_details_dialog.dart';
import 'package:pagashell/presentation/terminal/process_details_dialog.dart';
import 'package:pagashell/presentation/terminal/terminal_search_field.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_rdp_engine.dart';
import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

class _FakeEngine implements SshEngine {
  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async => FakeSftpSession();
}

class _PendingEngine implements SshEngine {
  final completer = Completer<SshEngineSession>();

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => completer.future;
}

void main() {
  tearDown(Get.reset);

  testWidgets('终端标签设置字号和断开行为，保存后实时生效', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settingsRepo = InMemorySettingsRepository();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          sshEngine: _FakeEngine(),
          settingsRepository: settingsRepo,
        ),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(id: 'h1', name: 'term-host', hostname: '10.0.0.1'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TerminalPane>(find.byType(TerminalPane)).textStyle.fontSize,
      13,
    );

    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    expect(find.text('终端字号'), findsNothing);
    await tester.tap(find.widgetWithText(shadcn.TabItem, '终端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('13 px'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16 px').last);
    await tester.pumpAndSettle();

    expect(Get.find<SettingsController>().terminalFontSize.value, 16);
    expect(settingsRepo.sidebarState.terminalFontSize, 16);
    final closeOnDisconnect = find.byKey(
      const ValueKey('close-terminal-on-disconnect'),
    );
    expect(tester.widget<shadcn.Switch>(closeOnDisconnect).value, isFalse);
    await tester.tap(closeOnDisconnect);
    await tester.pumpAndSettle();
    expect(tester.widget<shadcn.Switch>(closeOnDisconnect).value, isTrue);
    expect(settingsRepo.closeTerminalOnDisconnect, isTrue);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TerminalPane>(find.byType(TerminalPane)).textStyle.fontSize,
      16,
    );

    final connection =
        sessions.activeSession!.engineSession! as FakeSftpSession;
    await connection.endShell();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(sessions.tabs, isEmpty);
    expect(connection.closes, 1);
    expect(find.text('连接已断开，已保留历史输出'), findsNothing);
  });

  testWidgets('TerminalSearchField 支持一键清除和 Esc 清空', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 240,
            child: TerminalSearchField(
              fieldKey: const ValueKey('ops-search'),
              clearKey: const ValueKey('ops-search-clear'),
              controller: controller,
              semanticLabel: '搜索测试',
              hintText: '输入关键词',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ops-search-clear')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('ops-search')), 'nginx');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ops-search-clear')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(find.byKey(const ValueKey('ops-search-clear')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('ops-search')), 'redis');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ops-search-clear')));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
  });

  testWidgets('提示按类型显示颜色、根据内容调整宽度并合并重复消息', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    AppNotice.error('连接失败');
    AppNotice.error('连接失败');
    await tester.pumpAndSettle();
    final shortNotice = find.ancestor(
      of: find.text('连接失败'),
      matching: find.byType(shadcn.SurfaceCard),
    );
    expect(find.text('连接失败'), findsOneWidget);
    expect(tester.getSize(shortNotice).width, lessThan(320));
    final errCard = tester.widget<shadcn.SurfaceCard>(shortNotice);
    expect(errCard.borderColor, StatusColors.failed.withValues(alpha: 0.45));
    expect(
      tester.widget<AppIcon>(findAppIcon(AppIcons.circleAlert)).color,
      StatusColors.failed,
    );

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    final message = 'This notification contains additional detail. ' * 4;
    AppNotice.success(message);
    await tester.pump();
    final okCard = tester.widget<shadcn.SurfaceCard>(
      find.ancestor(
        of: find.text(message),
        matching: find.byType(shadcn.SurfaceCard),
      ),
    );
    expect(okCard.borderColor, StatusColors.ready.withValues(alpha: 0.45));
    expect(tester.getSize(find.byWidget(okCard)).width, greaterThan(320));
    expect(tester.getSize(find.byWidget(okCard)).width, lessThanOrEqualTo(400));
    expect(
      tester.widget<AppIcon>(findAppIcon(AppIcons.check)).color,
      StatusColors.ready,
    );

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('凭证管理弹窗支持搜索过滤、无匹配提示以及显式编辑按钮', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final identities = Get.find<IdentityController>();
    await identities.saveWithPassword(
      name: 'alpha-ssh',
      username: 'ops',
      password: 'p1',
    );
    await identities.saveWithPassword(
      name: 'beta-rdp',
      username: 'administrator',
      password: 'p2',
      serviceType: ServiceType.rdp,
    );
    await tester.pumpAndSettle();

    unawaited(showIdentityManagerDialog(tester.element(find.text('凭证'))));
    await tester.pumpAndSettle();

    final dialogBody = find.ancestor(
      of: find.byKey(const ValueKey('identity-manager-search')),
      matching: find.byType(SizedBox),
    );
    expect(
      find.descendant(of: dialogBody, matching: find.text('alpha-ssh')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogBody, matching: find.text('beta-rdp')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('identity-manager-search')),
      'rdp',
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialogBody, matching: find.text('alpha-ssh')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialogBody, matching: find.text('beta-rdp')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('identity-manager-search')),
      'not-found',
    );
    await tester.pumpAndSettle();
    expect(find.text('无匹配凭证'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('identity-manager-search-clear')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialogBody, matching: find.text('alpha-ssh')),
      findsOneWidget,
    );

    await tester.tap(findAppIconButton('编辑凭证').first);
    await tester.pumpAndSettle();
    expect(find.text('编辑凭证'), findsOneWidget);
    expect(find.widgetWithText(AppTextFormField, 'alpha-ssh'), findsOneWidget);
  });

  testWidgets('端口转发与动态代理状态徽章展示语义颜色圆点', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    const gateway = Host(id: 'gw-1', name: 'bastion', hostname: '10.0.0.2');
    sessions.openForward(gateway);
    await tester.pumpAndSettle();

    final forwardDot = tester.widget<Container>(
      find.byKey(const ValueKey('forward-status-dot')),
    );
    expect(
      (forwardDot.decoration! as BoxDecoration).color,
      StatusColors.closed,
    );

    sessions.openProxy(gateway);
    await tester.pumpAndSettle();

    final proxyDot = tester.widget<Container>(
      find.byKey(const ValueKey('proxy-status-dot')),
    );
    expect((proxyDot.decoration! as BoxDecoration).color, StatusColors.closed);
  });

  testWidgets('代码块支持复制反馈并短暂切换为对勾', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const ShadcnTestApp(
        home: Center(
          child: AppMarkdownCodeBlock(code: 'echo hello', language: 'sh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(findAppIconButton('复制'));
    await tester.pump();
    expect(copied, 'echo hello');
    expect(findAppIcon(AppIcons.check), findsOneWidget);
    expect(
      tester.widget<AppIcon>(findAppIcon(AppIcons.check)).color,
      StatusColors.ready,
    );

    await tester.pump(const Duration(milliseconds: 1600));
    expect(findAppIcon(AppIcons.copy), findsOneWidget);
  });

  testWidgets('Agent 回复标题栏支持一键复制', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();

    final agent = Get.find<AgentController>();
    agent.entries.addAll([
      AgentEntry(AgentEntryKind.user, '查看负载'),
      AgentEntry(AgentEntryKind.assistant, '当前负载正常'),
    ]);
    await tester.pumpAndSettle();

    expect(findAppIconButton('复制回复'), findsOneWidget);
    await tester.tap(findAppIconButton('复制回复'));
    await tester.pump();
    expect(copied, '当前负载正常');
  });

  testWidgets('RDP 工具栏拥有表面底色分隔线且等待画面时展示加载提示文案', (tester) async {
    final session = FakeRdpSession();
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(session: session, active: true, onError: (_) {}),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('rdp-toolbar')), findsOneWidget);
    expect(find.text('正在等待远程桌面画面…'), findsOneWidget);
    final toolbar = tester.widget<Container>(
      find.byKey(const ValueKey('rdp-toolbar')),
    );
    expect(toolbar.decoration, isA<BoxDecoration>());
    await session.close();
  });

  testWidgets('连接中视图展示目标地址并支持直接取消连接，会话标签支持悬停详情提示', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pending = _PendingEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: pending),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    unawaited(
      sessions.open(
        const Host(id: 'h-pending', name: 'slow-srv', hostname: '10.0.0.99'),
        SshCredentials.password('secret'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('connecting-status-text')),
      findsOneWidget,
    );
    expect(find.text('正在连接到 root@10.0.0.99…'), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(
        find.descendant(
          of: find.byType(shadcn.KeyedTabItem<String>),
          matching: find.text('slow-srv'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('slow-srv · root@10.0.0.99 · 终端（正在连接）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connecting-cancel')));
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
  });

  testWidgets('Agent 历史对话弹窗支持搜索过滤与当前对话胶囊标识', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final agent = Get.find<AgentController>();
    unawaited(showAgentHistory(agent));
    await tester.pumpAndSettle();

    final now = DateTime(2026, 11, 18, 12, 0);
    agent.conversations.assignAll([
      AgentConversation(
        id: '00000000000000000000000000000001',
        title: 'Nginx 502 排查',
        createdAt: now,
        updatedAt: now,
        model: 'gpt-4o',
        messages: const [AgentMessage(AgentEntryKind.user, '排查 502')],
        turns: const [],
      ),
      AgentConversation(
        id: '00000000000000000000000000000002',
        title: 'Docker 磁盘清理',
        createdAt: now,
        updatedAt: now,
        model: 'claude-3-7',
        messages: const [AgentMessage(AgentEntryKind.user, '清理镜像')],
        turns: const [],
      ),
    ]);
    agent.currentConversationId.value = '00000000000000000000000000000001';
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey(
          'agent-history-current-00000000000000000000000000000001',
        ),
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('agent-history-search')),
      'claude',
    );
    await tester.pumpAndSettle();
    expect(find.text('Nginx 502 排查'), findsNothing);
    expect(find.text('Docker 磁盘清理'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('agent-history-search')),
      'nonexistent',
    );
    await tester.pumpAndSettle();
    expect(find.text('无匹配对话'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-history-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Nginx 502 排查'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('进程详情、Docker 详情、SSH 指纹及 RDP 证书支持关键字段一键复制', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const process = RemoteProcess(
      pid: 4242,
      user: 'root',
      name: '/usr/sbin/nginx',
      startedAt: 'Mon Nov 18 10:00:00 2026',
      cpuSeconds: 12,
      cpuPercent: 1.5,
      memoryBytes: 1048576,
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        home: ProcessDetailsDialog(
          process: process,
          readDetails: (_) async => const ProcessDetails(
            process: process,
            parentPid: 1,
            state: 'S',
            nice: 0,
            elapsed: '01:00',
            memoryPercent: 0.5,
            virtualMemoryBytes: 4096000,
            executablePath: '/usr/sbin/nginx',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('process-details-copy-pid')));
    await tester.pump();
    expect(copied, '4242');
    await tester.tap(find.byKey(const ValueKey('process-details-copy-path')));
    await tester.pump();
    expect(copied, '/usr/sbin/nginx');
    await tester.pump(const Duration(milliseconds: 1600));

    final container = DockerResource(
      kind: DockerResourceKind.container,
      id: 'sha256:abcdef1234567890',
      name: 'web-nginx',
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        home: DockerDetailsDialog(
          resource: container,
          readDetails: (_) async => DockerDetails(container),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('docker-detail-copy-id')));
    await tester.pump();
    expect(copied, 'sha256:abcdef1234567890');
    await tester.pump(const Duration(milliseconds: 1600));

    const sshKey = SshHostKey(
      hostname: '10.0.0.1',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:ssh-fp-test',
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        home: HostKeyConfirmation(
          review: const HostKeyReview(presented: sshKey),
          onDecision: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-key-copy-fingerprint')));
    await tester.pump();
    expect(copied, 'SHA256:ssh-fp-test');
    await tester.pump(const Duration(milliseconds: 1600));

    const rdpKey = SshHostKey(
      hostname: '10.0.0.2',
      port: 3389,
      keyType: 'rdp-tls',
      fingerprint: 'SHA256:rdp-fp-test',
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpCertificateDialog(
          review: const HostKeyReview(presented: rdpKey),
          onDecision: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示证书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rdp-cert-copy-fingerprint')));
    await tester.pump();
    expect(copied, 'SHA256:rdp-fp-test');
    await tester.pump(const Duration(milliseconds: 1600));
  });
}
