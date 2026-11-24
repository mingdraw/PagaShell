import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_list_row.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';

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

  testWidgets('侧栏搜索可清空，服务悬停或获得焦点时单行显示标签', (tester) async {
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

    final hosts = Get.find<HostController>();
    await hosts.save(
      const Host(
        id: 'h1',
        name: 'web-prod',
        hostname: '10.0.0.10',
        username: 'deploy',
        tags: ['prod', 'payments-api-blue-green-canary'],
      ),
    );
    await hosts.save(
      const Host(
        id: 'h2',
        name: 'db-prod',
        hostname: '10.0.0.11',
        username: 'postgres',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar-search-clear')), findsNothing);
    await tester.enterText(find.byType(shadcn.TextField), 'web');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar-search-clear')), findsOneWidget);
    expect(find.text('web-prod'), findsOneWidget);
    expect(find.text('db-prod'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hosts.searchQuery.value, isEmpty);
    expect(find.byKey(const ValueKey('sidebar-search-clear')), findsNothing);
    expect(find.text('db-prod'), findsOneWidget);

    await tester.enterText(find.byType(shadcn.TextField), 'db');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-search-clear')));
    await tester.pumpAndSettle();
    expect(hosts.searchQuery.value, isEmpty);
    expect(find.text('web-prod'), findsOneWidget);

    expect(find.byKey(const ValueKey('host-quick-edit-h1')), findsNothing);
    expect(find.byKey(const ValueKey('host-quick-sftp-h1')), findsNothing);
    final tags = find.byKey(const ValueKey('sidebar-host-tags-h1'));
    expect(tags, findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('web-prod')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('host-quick-edit-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-quick-sftp-h1')), findsOneWidget);
    expect(find.text('deploy@10.0.0.10'), findsNothing);
    expect(
      tester.widget<Text>(tags).data,
      'prod · payments-api-blue-green-canary',
    );

    await tester.tap(find.byKey(const ValueKey('host-quick-edit-h1')));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await mouse.moveTo(tester.getCenter(find.text('db-prod')));
    await tester.pumpAndSettle();
    expect(tags, findsNothing);
    expect(find.byKey(const ValueKey('sidebar-host-tags-h2')), findsNothing);

    final detector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('sidebar-host-row-h1')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    detector.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(tags, findsOneWidget);
  });

  testWidgets('欢迎页展示最近连接卡片，点击后直接打开会话', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settingsRepo = InMemorySettingsRepository()
      ..sidebarState = SidebarState(recentHostIds: const ['h1']);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          settingsRepository: settingsRepo,
          sshEngine: _FakeEngine(),
        ),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final hosts = Get.find<HostController>();
    await hosts.save(
      const Host(
        id: 'h1',
        name: 'recent-app',
        hostname: '10.0.0.20',
        username: 'ubuntu',
      ),
    );
    await hosts.savePassword('h1', 'secret');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('welcome-recent-hosts')), findsOneWidget);
    final card = find.byKey(const ValueKey('welcome-host-h1'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('ubuntu@10.0.0.20')),
      findsOneWidget,
    );

    await tester.tap(card);
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    expect(sessions.sessions, hasLength(1));
    expect(sessions.sessions.single.host.id, 'h1');
    expect(sessions.sessions.single.kind, SessionKind.terminal);
  });

  testWidgets('侧边栏凭证与网关悬停展示对应快捷操作', (tester) async {
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

    final identity = await Get.find<IdentityController>().saveWithPassword(
      name: 'prod-key',
      username: 'root',
      password: 'secret',
    );
    await Get.find<GatewayController>().save(
      const Host(id: 'gw1', name: 'bastion', hostname: 'bastion.example.test'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('identity-quick-edit-${identity.id}')),
      findsNothing,
    );
    expect(find.byKey(ValueKey('identity-type-${identity.id}')), findsNothing);
    expect(find.byKey(const ValueKey('gateway-type-gw1')), findsNothing);
    expect(find.text('SSH'), findsNothing);
    expect(
      find.byKey(const ValueKey('gateway-quick-forward-gw1')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('gateway-quick-proxy-gw1')), findsNothing);
    expect(find.byKey(const ValueKey('host-quick-edit-gw1')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.text('prod-key')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('identity-type-${identity.id}')),
      findsOneWidget,
    );
    expect(find.text('SSH'), findsOneWidget);
    final identityEdit = find.byKey(
      ValueKey('identity-quick-edit-${identity.id}'),
    );
    expect(identityEdit, findsOneWidget);
    await tester.tap(identityEdit);
    await tester.pumpAndSettle();
    expect(find.text('编辑凭证'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await mouse.moveTo(tester.getCenter(find.text('bastion')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gateway-type-gw1')), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);
    final gwForward = find.byKey(const ValueKey('gateway-quick-forward-gw1'));
    final gwProxy = find.byKey(const ValueKey('gateway-quick-proxy-gw1'));
    final gwEdit = find.byKey(const ValueKey('host-quick-edit-gw1'));
    expect(gwForward, findsOneWidget);
    expect(gwProxy, findsOneWidget);
    expect(gwEdit, findsOneWidget);
    final gatewayRow = find.byKey(const ValueKey('sidebar-host-row-gw1'));
    expect(tester.widget<AppListRow>(gatewayRow).subtitle, isNull);

    await tester.tap(gwForward);
    await tester.pumpAndSettle();
    await tester.tap(gwProxy);
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    expect(sessions.sessions.map((s) => s.kind).toList(), [
      SessionKind.portForward,
      SessionKind.dynamicProxy,
    ]);
    final activeGateway = tester.widget<AppListRow>(gatewayRow);
    expect(activeGateway.selected, isTrue);
    expect(activeGateway.subtitle, isNull);

    await tester.tap(gwEdit);
    await tester.pumpAndSettle();
    expect(find.byType(HostEditDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('命令面板支持行内快捷操作、已打开标签切换与命令搜索，侧边栏显示在线状态点与会话数', (tester) async {
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

    final hosts = Get.find<HostController>();
    const host1 = Host(
      id: 'h1',
      name: 'alpha-srv',
      hostname: '10.0.0.1',
      username: 'root',
    );
    const host2 = Host(
      id: 'h2',
      name: 'beta-srv',
      hostname: '10.0.0.2',
      username: 'admin',
    );
    await hosts.save(host1);
    await hosts.savePassword('h1', 'pw1');
    await hosts.save(host2);
    await hosts.savePassword('h2', 'pw2');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('host-status-dot-h1')), findsNothing);

    final sessions = Get.find<SessionController>();
    final s1 = await sessions.open(host1, SshCredentials.password('pw1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-status-dot-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-session-count-h1')), findsNothing);

    await sessions.open(host1, SshCredentials.password('pw1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-session-count-h1')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('command-palette-shortcuts')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('palette-sftp-h2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('palette-sftp-h2')));
    await tester.pumpAndSettle();

    expect(
      sessions.sessions.any(
        (s) => s.host.id == 'h2' && s.kind == SessionKind.fileTransfer,
      ),
      isTrue,
    );

    final firstTabId = sessions.tabForSession(s1)!.id;
    expect(sessions.activeTabId, isNot(firstTabId));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('palette-tab-$firstTabId')));
    await tester.pumpAndSettle();
    expect(sessions.activeTabId, firstTabId);
  });

  testWidgets('Agent 欢迎态展示结构化提示卡片，点击填入输入框，模型标识点击打开 AI 设置', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();

    final promptCard = find.byKey(const ValueKey('agent-welcome-prompt-1'));
    expect(promptCard, findsOneWidget);
    await tester.tap(promptCard);
    await tester.pumpAndSettle();

    final input = tester.widget<AppTextFormField>(
      find.byKey(const ValueKey('agent-input')),
    );
    expect(input.controller.text, '排查 SSH 服务或端口异常');

    await tester.tap(find.byKey(const ValueKey('agent-model-select')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('命令面板在组词及无结果时保持打开，小键盘回车可聚焦匹配的副窗格', (tester) async {
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
    const credentials = SshCredentials.password('fixture');
    final primary = await sessions.open(
      const Host(id: 'root', name: 'Primary', hostname: 'primary.test'),
      credentials,
    );
    final secondary = await sessions.splitToHost(
      primary,
      const Host(id: 'side', name: 'Secondary', hostname: 'secondary.test'),
      credentials,
      edge: SessionSplitEdge.right,
      temporary: true,
    );
    expect(secondary, isNotNull);
    sessions.activate(primary);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('command-palette-input'));
    await tester.enterText(input, 'no results fixture');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    expect(find.text('没有匹配的服务'), findsOneWidget);

    await tester.enterText(input, 'ssh');
    await tester.pumpAndSettle();
    expect(find.text('Primary · 窗格 1/2'), findsOneWidget);
    expect(find.text('Secondary · 窗格 2/2'), findsOneWidget);

    const query = 'secondary ssh';
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
        composing: TextRange(start: 0, end: query.length),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('回车聚焦窗格'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    expect(sessions.activeSessionId.value, primary);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(input, findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(sessions.activeSessionId.value, secondary);
    expect(sessions.activeTabId, sessions.tabForSession(primary)!.id);
  });

  testWidgets('在窄窗中从命令面板恢复被 Agent 临时遮起的侧栏', (tester) async {
    tester.view.physicalSize = const Size(860, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('sidebar-viewport'));
    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-input')),
      '切换侧边栏',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, greaterThan(0));
    expect(
      find.byKey(const ValueKey('agent-panel')).hitTestable(),
      findsNothing,
    );
  });

  testWidgets('侧栏宽度可保存，目录内新建服务保留归属，页签可中键关闭', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settingsRepo = InMemorySettingsRepository();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          settingsRepository: settingsRepo,
          sshEngine: _FakeEngine(),
        ),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('sidebar-viewport'));
    final sidebarToggle = find.byKey(const ValueKey('sidebar-toggle'));
    expect(tester.getSize(viewport).width, AppTheme.sidebarWidth);
    expect(tester.getRect(sidebarToggle).left, AppTheme.macWindowControlsWidth);

    await tester.drag(
      find.byKey(const ValueKey('sidebar-resize-handle')),
      const Offset(48, 0),
    );
    await tester.pumpAndSettle();
    final settings = Get.find<SettingsController>();
    await settings.sidebarSaved;
    final newWidth = tester.getSize(viewport).width;
    expect(newWidth, greaterThan(AppTheme.sidebarWidth));
    expect(settingsRepo.sidebarState.width, newWidth);
    expect(tester.getRect(sidebarToggle).left, AppTheme.macWindowControlsWidth);

    final folder = await Get.find<FolderController>().create(name: '核心集群');
    await tester.pumpAndSettle();

    await tester.tap(find.text('核心集群'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('在此新建服务'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'clustered-node',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      '10.0.0.99',
    );
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('所属目录'), findsNothing);
    final gateway = find.byKey(const ValueKey('gateway-select-null'));
    final color = find.byKey(const ValueKey('host-color'));
    expect(
      tester.getTopLeft(gateway).dy,
      greaterThan(tester.getBottomLeft(color).dy),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final savedHost = Get.find<HostController>().hosts.single;
    expect(savedHost.name, 'clustered-node');
    expect(savedHost.folderId, folder.id);

    final sessions = Get.find<SessionController>();
    final s1 = await sessions.open(
      savedHost,
      SshCredentials.password('secret'),
    );
    final s2 = await sessions.open(
      const Host(id: 'h2', name: 'second-node', hostname: '10.0.0.100'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    final tab1Close = find.byKey(ValueKey('session-tab-close-$s1'));
    final tab2Close = find.byKey(ValueKey('session-tab-close-$s2'));
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: tab1Close, matching: find.byType(Opacity)).first,
          )
          .opacity,
      0.0,
    );
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: tab2Close, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1.0,
    );

    final tabLabel = find.descendant(
      of: find.byType(shadcn.TabPane<String>),
      matching: find.text('clustered-node'),
    );
    final mouse = await tester.startGesture(
      tester.getCenter(tabLabel),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await mouse.moveBy(const Offset(0, 45));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(sessions.tabs.map((t) => t.id), [s1, s2]);

    await tester.tap(tabLabel, buttons: kMiddleMouseButton);
    await tester.pumpAndSettle();
    expect(sessions.tabs.map((t) => t.id), [s2]);
  });
}
