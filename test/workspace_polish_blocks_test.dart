import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_markdown.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/identities/identity_manager_dialog.dart';
import 'package:pagashell/presentation/navigation/app_notice.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
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

void main() {
  tearDown(Get.reset);

  testWidgets('通用设置终端字号持久化并实时应用到终端视图', (tester) async {
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
    await tester.tap(find.text('13 px'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16 px').last);
    await tester.pumpAndSettle();

    expect(Get.find<SettingsController>().terminalFontSize.value, 16);
    expect(settingsRepo.sidebarState.terminalFontSize, 16);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TerminalPane>(find.byType(TerminalPane)).textStyle.fontSize,
      16,
    );
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

  testWidgets('AppNotice 按成功和错误类型应用语义颜色', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _FakeEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    AppNotice.error('连接失败');
    await tester.pump();
    final errCard = tester.widget<shadcn.SurfaceCard>(
      find.ancestor(
        of: find.text('连接失败'),
        matching: find.byType(shadcn.SurfaceCard),
      ),
    );
    expect(errCard.borderColor, StatusColors.failed.withValues(alpha: 0.45));
    expect(
      tester.widget<AppIcon>(findAppIcon(AppIcons.circleAlert)).color,
      StatusColors.failed,
    );

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    AppNotice.success('保存成功');
    await tester.pump();
    final okCard = tester.widget<shadcn.SurfaceCard>(
      find.ancestor(
        of: find.text('保存成功'),
        matching: find.byType(shadcn.SurfaceCard),
      ),
    );
    expect(okCard.borderColor, StatusColors.ready.withValues(alpha: 0.45));
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
}
