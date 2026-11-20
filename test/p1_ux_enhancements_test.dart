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
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/proxy/dynamic_proxy_engine.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/components/app_list_row.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/sftp/file_browser_pane.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';
import 'package:pagashell/presentation/shell/command_palette.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/fixture_terminal.dart' show TerminalFixtureOutput;
import 'support/in_memory_binding.dart';
import 'support/in_memory_local_file_repository.dart';
import 'support/shadcn_test_app.dart';

class _RecordingSshSession extends FakeSftpSession {
  final written = <String>[];

  @override
  void write(String data) => written.add(data);
}

class _CountingSshEngine implements SshEngine, DynamicProxyEngine {
  final sessions = <_RecordingSshSession>[];
  final proxies = <_FakeDynamicProxySession>[];
  int connectCalls = 0;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    connectCalls++;
    final session = _RecordingSshSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<DynamicProxySession> startProxy(
    ProxyConfig config, {
    SshGateway? gateway,
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  }) async {
    final proxy = _FakeDynamicProxySession();
    proxies.add(proxy);
    return proxy;
  }
}

class _FakeDynamicProxySession implements DynamicProxySession {
  final ended = Completer<void>();

  @override
  Future<void> get done => ended.future;

  @override
  Future<void> close() async {
    if (!ended.isCompleted) ended.complete();
  }
}

class _MockClipboard {
  String? text;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return text == null ? null : <String, dynamic>{'text': text};
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
  }
}

class _FailRestoreLease implements SystemProxyLease {
  bool shouldFail = true;
  int restoreCalls = 0;

  @override
  Future<void> enable() async {}

  @override
  Future<void> restore() async {
    restoreCalls++;
    if (shouldFail) {
      throw const SystemProxyException('恢复系统代理失败');
    }
  }
}

class _FakeSystemProxy implements SystemProxy {
  _FakeSystemProxy(this.lease);
  final _FailRestoreLease lease;

  @override
  SystemProxyLease createLease(ProxyConfig config) => lease;
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  testWidgets('终端多行粘贴确认框支持取消、去除末尾换行与本次会话不再提示', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final clipboard = _MockClipboard()..install(tester);
    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(id: 'h1', name: 'web-01', hostname: '10.0.0.1'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    final ssh = engine.sessions.single;
    tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();

    Future<void> triggerPaste() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    // 单行无换行内容直接粘贴，不弹确认框。
    clipboard.text = 'echo ok';
    await triggerPaste();
    expect(find.text('确认粘贴多行内容'), findsNothing);
    expect(ssh.written, ['echo ok']);
    ssh.written.clear();

    // 多行且带末尾换行：取消后不写入。
    clipboard.text = 'ls -la\npwd\n';
    await triggerPaste();
    expect(find.text('确认粘贴多行内容'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('terminal-paste-trim-newline')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('terminal-paste-cancel')));
    await tester.pumpAndSettle();
    expect(ssh.written, isEmpty);

    // 去除末尾换行粘贴 + 勾选本次会话不再提示。
    await triggerPaste();
    await tester.tap(find.byKey(const ValueKey('terminal-paste-skip-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-paste-trim-newline')));
    await tester.pumpAndSettle();
    expect(ssh.written, ['ls -la\npwd']);
    ssh.written.clear();

    // 本次会话再次多行粘贴不再弹窗，直接写入。
    clipboard.text = 'uname -a\nid\n';
    await triggerPaste();
    expect(find.text('确认粘贴多行内容'), findsNothing);
    expect(ssh.written, ['uname -a\nid\n']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('终端右键菜单支持清屏、分屏与文件传输，快捷键支持字号缩放与重置', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(id: 'h1', name: 'app-01', hostname: '10.0.0.1'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    // 右键终端弹出上下文菜单并点击清屏。
    await tester.tap(find.byType(TerminalView), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('清屏'), findsOneWidget);
    expect(find.text('左右分屏'), findsOneWidget);
    await tester.tap(find.text('清屏'));
    await tester.pumpAndSettle();
    expect(engine.sessions.single.written, ['\x0c']);

    // ⌘= 放大字号、⌘- 缩小、⌘0 重置。
    final settings = Get.find<SettingsController>();
    expect(settings.terminalFontSize.value, 13);

    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    await chord(LogicalKeyboardKey.equal);
    await chord(LogicalKeyboardKey.equal);
    expect(settings.terminalFontSize.value, 15);
    expect(
      tester.widget<TerminalPane>(find.byType(TerminalPane)).textStyle.fontSize,
      15,
    );

    await chord(LogicalKeyboardKey.minus);
    expect(settings.terminalFontSize.value, 14);

    await chord(LogicalKeyboardKey.digit0);
    expect(settings.terminalFontSize.value, 13);

    engine.sessions.single.emitShellOutput('disk is 82% full');
    await tester.pumpAndSettle();
    tester.state<TerminalPaneState>(find.byType(TerminalPane)).selectAll();
    await tester.tap(find.byType(TerminalView), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用选区到 Agent'));
    await tester.pumpAndSettle();
    final input = tester.widget<AppTextFormField>(
      find.byKey(const ValueKey('agent-input')),
    );
    expect(input.controller.text, '> disk is 82% full\n\n');
    expect(Get.find<AgentController>().entries, isEmpty);
  });

  testWidgets('终端处于已断开状态时保留输出并展示内联重连条，点击重新连接可恢复会话', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    final id = await sessions.open(
      const Host(id: 'h1', name: 'srv-01', hostname: '10.0.0.1'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();
    expect(engine.connectCalls, 1);

    final connection = engine.sessions.single;
    final terminal = sessions.sessions.single.terminal!;
    connection.emitShellOutput('last output');
    await tester.pumpAndSettle();
    await connection.endShell();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(sessions.sessions.single.terminal, same(terminal));
    expect(terminal.lines[0].getText(), 'last output');
    expect(connection.closes, 1);
    expect(
      find.byKey(const ValueKey('terminal-disconnected-banner')),
      findsOneWidget,
    );
    expect(find.text('连接已断开，已保留历史输出'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('terminal-disconnected-reconnect')),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(engine.connectCalls, 2);
    expect(terminal.isDisposed, isTrue);
    expect(connection.closes, 1);
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(
      find.byKey(const ValueKey('terminal-disconnected-banner')),
      findsNothing,
    );
    expect(sessions.sessions.single.id, id);

    tester.view.physicalSize = const Size(800, 600);
    await sessions.splitTerminal(id, SessionSplitAxis.horizontal);
    await sessions.splitTerminal(id, SessionSplitAxis.horizontal);
    await tester.pumpAndSettle();
    await engine.sessions[1].endShell();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final reconnect = find.byKey(
      const ValueKey('terminal-disconnected-reconnect'),
    );
    expect(reconnect.hitTestable(), findsOneWidget);
    expect(tester.widget(reconnect), isA<AppIconButton>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agent 多行填入只写入当前终端，且要求括号粘贴', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(id: 'h1', name: 'draft-target', hostname: '10.0.0.1'),
      SshCredentials.password('secret'),
    );
    await sessions.open(
      const Host(id: 'h2', name: 'active-target', hostname: '10.0.0.2'),
      SshCredentials.password('secret'),
    );
    final agent = Get.find<AgentController>();
    agent.setReferencedSessions([sessions.sessions.first]);
    agent.entries.add(
      AgentEntry(AgentEntryKind.assistant, '```sh\npwd\nls\n```'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();

    final insert = find.byKey(const ValueKey('code-insert-terminal'));
    await tester.tap(insert);
    await tester.pumpAndSettle();
    expect(engine.sessions.expand((s) => s.written), isEmpty);
    expect(find.text('当前终端未启用括号粘贴，请复制后分行检查并粘贴'), findsOneWidget);

    sessions.sessions.last.terminal!.setBracketedPaste(true);
    await tester.pump();
    await tester.tap(insert);
    await tester.pumpAndSettle();
    expect(engine.sessions.first.written, isEmpty);
    expect(engine.sessions.last.written, ['\x1b[200~pwd\nls\x1b[201~']);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('Agent 代码块支持填入终端（不自动回车），高风险命令展示警示徽章，完全访问高亮，空输入禁用发送并支持重试与去重错误', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    await Get.find<AiSettingsController>().saveApi(
      format: AiApiFormat.anthropic,
      baseUrl: 'https://api.example.test/v1',
      defaultModel: 'claude-test',
      apiKey: 'sk-test',
    );
    final sessions = Get.find<SessionController>();
    await sessions.open(
      const Host(id: 'h1', name: 'prod-1', hostname: '10.0.0.8'),
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();

    // 空输入时发送按钮禁用。
    final sendButton = tester.widget<shadcn.PrimaryButton>(
      find.byKey(const ValueKey('agent-send')),
    );
    expect(sendButton.onPressed, isNull);

    // 切换完全访问模式，按钮显示警示色。
    final agent = Get.find<AgentController>();
    agent.selectAccessMode(AgentAccessMode.fullAccess);
    await tester.pumpAndSettle();
    final shieldIcon = tester.widget<AppIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('agent-access-select')),
        matching: findAppIcon(AppIcons.shieldOff),
      ),
    );
    expect(shieldIcon.color, AppTheme.serverStatusWarningColor);

    // 模拟助手回复含代码块 + 高风险命令卡片 + 失败用户消息。
    final target = sessions.sessions.single;
    final failedUser = AgentEntry(
      AgentEntryKind.user,
      '检查磁盘',
      requestState: AgentRequestState.failed,
      requestError: '网络超时',
    );
    final proposal = AgentCommandProposal(
      command: 'rm -rf /tmp/old-cache',
      purpose: '清理临时目录',
      target: target,
      generation: 0,
    );
    agent.error.value = '网络超时';
    agent.entries.assignAll([
      failedUser,
      AgentEntry(AgentEntryKind.assistant, '```sh\ndf -h\n```'),
      AgentEntry(AgentEntryKind.command, '清理临时目录', command: proposal),
    ]);
    await tester.pumpAndSettle();

    // 最新错误固定在输入区上方，历史消息保留自己的重试入口。
    expect(
      find.byKey(const ValueKey('agent-error')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('agent-error-retry')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('agent-entry-retry')), findsOneWidget);

    // 高风险命令卡片展示目标主机+地址和高风险徽章。
    expect(find.text('目标：prod-1 · root@10.0.0.8'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-command-risk-badge')),
      findsOneWidget,
    );

    // 点击 Markdown 代码块的「填入终端」，写入不含回车的命令。
    await tester.tap(find.byKey(const ValueKey('code-insert-terminal')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(engine.sessions.single.written, ['df -h']);
    engine.sessions.single.written.clear();

    // 点击命令卡片的「填入终端」，同样写入不含回车。
    await tester.tap(find.byKey(const ValueKey('agent-command-insert')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(engine.sessions.single.written, ['rm -rf /tmp/old-cache']);

    // 清理 toast 定时器。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('Agent 小幅向上滚动后保留阅读位置，新输出不抢滚', (tester) async {
    tester.view.physicalSize = const Size(1280, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();

    final agent = Get.find<AgentController>();
    agent.entries.assignAll([
      for (var i = 0; i < 26; i++)
        AgentEntry(
          i.isEven ? AgentEntryKind.user : AgentEntryKind.assistant,
          '第 $i 条消息内容，用于撑高列表高度以测试滚动行为。',
        ),
    ]);
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('agent-messages'));
    final position = tester.widget<ListView>(list).controller!.position;
    final initialBottom = position.maxScrollExtent;
    expect(position.pixels, initialBottom);

    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(list),
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
    }

    await wheel(-12);
    expect(position.pixels, lessThan(initialBottom));

    final returnButton = find.byKey(const ValueKey('agent-scroll-bottom'));
    expect(returnButton, findsOneWidget);
    final readingOffset = position.pixels;
    final last = agent.entries.last;
    agent.entries[agent.entries.length - 1] = AgentEntry(
      AgentEntryKind.assistant,
      '${last.text}\n\n这条回复还在继续输出。',
    );
    await tester.pumpAndSettle();
    expect(position.pixels, readingOffset);

    agent.entries.add(AgentEntry(AgentEntryKind.assistant, '新的回复'));
    await tester.pumpAndSettle();
    expect(position.pixels, readingOffset);

    await tester.tap(returnButton);
    await tester.pumpAndSettle();
    expect(returnButton, findsNothing);
    expect(position.pixels, position.maxScrollExtent);
    expect(find.text('新的回复').hitTestable(), findsOneWidget);

    await wheel(-12);
    await wheel(12);
    expect(returnButton, findsNothing);
    position.jumpTo(position.maxScrollExtent - 0.5);
    await tester.pumpAndSettle();
    expect(returnButton, findsNothing);
    agent.entries.add(AgentEntry(AgentEntryKind.assistant, '继续跟随这条回复'));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('SFTP 传输条折叠态展示失败与排队计数，运行中展示百分比、速率与剩余时间', (tester) async {
    tester.view.physicalSize = const Size(1200, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = Get.put(TransferController());
    final running =
        TransferTask(
            id: 'run-1',
            sessionId: 's1',
            kind: TransferKind.upload,
            fileName: 'archive.tar.gz',
            localPath: '/local/archive.tar.gz',
            remotePath: '/remote/archive.tar.gz',
          )
          ..status.value = TransferStatus.running
          ..transferred.value = 512 * 1024
          ..total.value = 1024 * 1024
          ..bytesPerSecond.value = 256 * 1024;
    final queued = TransferTask(
      id: 'queue-1',
      sessionId: 's1',
      kind: TransferKind.upload,
      fileName: 'next.bin',
      localPath: '/local/next.bin',
      remotePath: '/remote/next.bin',
    )..status.value = TransferStatus.queued;
    final failed =
        TransferTask(
            id: 'fail-1',
            sessionId: 's1',
            kind: TransferKind.download,
            fileName: 'broken.log',
            localPath: '/local/broken.log',
            remotePath: '/remote/broken.log',
          )
          ..status.value = TransferStatus.failed
          ..error.value = '连接中断';
    controller.tasks.assignAll([running, queued, failed]);

    final engine = FakeSftpSession();
    addTearDown(engine.close);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 's1',
            host: const Host(id: 'h1', name: 'srv', hostname: '10.0.0.1'),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: InMemoryLocalFileRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 折叠态即可看到排队数、失败红标、全部取消按钮。
    expect(
      find.byKey(const ValueKey('sftp-transfer-queued-badge')),
      findsOneWidget,
    );
    expect(find.text('排队 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sftp-transfer-failed-badge')),
      findsOneWidget,
    );
    expect(find.text('失败 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sftp-transfer-cancel-all')),
      findsOneWidget,
    );

    // 上方显示总大小，已传大小和剩余时间在副行更新。
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    final totalSize = find.byKey(const ValueKey('sftp-transfer-label-run-1'));
    final detail = find.byKey(const ValueKey('sftp-transfer-detail-run-1'));
    expect(tester.widget<Text>(totalSize).data, '1.0 MB');
    expect(
      tester.widget<Text>(detail).data,
      contains('512.0 KB / 1.0 MB (50%)'),
    );
    expect(tester.widget<Text>(detail).data, contains('256.0 KB/s'));
    expect(tester.widget<Text>(detail).data, contains('剩余 2s'));
    expect(find.text('总速率 256.0 KB/s'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('sftp-transfer-label-fail-1')),
          )
          .data,
      '—',
    );

    running.transferred.value = 768 * 1024;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(totalSize).data, '1.0 MB');
    expect(
      tester.widget<Text>(detail).data,
      contains('768.0 KB / 1.0 MB (75%)'),
    );
  });

  testWidgets('SFTP 文件列表默认按名称升序，支持目录内筛选、快捷键、工具栏传输与路径空白点击编辑', (tester) async {
    final clipboard = _MockClipboard()..install(tester);
    var refreshed = 0;
    var renameCount = 0;
    FileBrowserEntry? renamed;
    List<FileBrowserEntry>? transferred;
    List<FileBrowserEntry>? deleted;

    final entries = [
      const FileBrowserEntry(
        name: 'zebra.log',
        path: '/work/zebra.log',
        isDir: false,
        size: 120,
      ),
      const FileBrowserEntry(
        name: 'alpha.txt',
        path: '/work/alpha.txt',
        isDir: false,
        size: 80,
      ),
    ];

    await tester.pumpWidget(
      ShadcnTestApp(
        home: SizedBox(
          width: 600,
          height: 440,
          child: FileBrowserPane(
            sessionId: 's1',
            side: FileBrowserSide.local,
            cwd: '/work',
            entries: entries,
            loading: false,
            error: null,
            onNavigate: (_) {},
            onRefresh: () => refreshed++,
            onOpen: (_) {},
            onTransfer: (items) => transferred = items,
            onDrop: (_, _) {},
            onRename: (entry) {
              renamed = entry;
              renameCount++;
            },
            onDelete: (items) => deleted = items,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认按名称升序：alpha.txt 在 zebra.log 之前。
    expect(
      tester.getTopLeft(find.text('alpha.txt')).dy,
      lessThan(tester.getTopLeft(find.text('zebra.log')).dy),
    );

    // 在有焦点的窗格中用 ⌘F 打开筛选。
    await tester.tap(
      find.byKey(const ValueKey('sftp-local-row-/work/alpha.txt')),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sftp-local-filter')),
      'ZEBRA',
    );
    await tester.pumpAndSettle();
    expect(find.text('alpha.txt'), findsNothing);
    expect(find.text('zebra.log'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(transferred?.single.name, 'zebra.log');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-local-filter')), findsNothing);
    expect(find.text('alpha.txt'), findsOneWidget);

    // 选中 alpha.txt，支持 F2 重命名、工具栏传输、F5 刷新和 Delete 删除。
    await tester.tap(
      find.byKey(const ValueKey('sftp-local-row-/work/alpha.txt')),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(renamed?.name, 'alpha.txt');
    expect(renameCount, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(refreshed, 1);

    await tester.tap(
      find.byKey(const ValueKey('sftp-local-transfer-selected')),
    );
    await tester.pumpAndSettle();
    expect(transferred?.single.name, 'alpha.txt');

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(deleted?.single.name, 'alpha.txt');

    // 右键文件支持复制路径。
    await tester.tap(
      find.byKey(const ValueKey('sftp-local-row-/work/alpha.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制路径'));
    await tester.pumpAndSettle();
    expect(clipboard.text, '/work/alpha.txt');

    // 点击面包屑空白区进入路径编辑模式。
    await tester.tap(find.byKey(const ValueKey('sftp-path-empty-local')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-local-path-input')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sftp-path-current-local')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-local-path-input')), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('SFTP 远程窗格用键盘隐藏点文件并按页选中', (tester) async {
    Get.put(TransferController());
    final engine = FakeSftpSession();
    addTearDown(engine.close);
    engine.fs['/home/test']!.addAll([
      const SftpDirEntry(name: '.env', isDir: false, size: 0),
      for (var i = 0; i < 35; i++)
        SftpDirEntry(name: 'file-$i.txt', isDir: false, size: 0),
    ]);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 's1',
            host: const Host(id: 'h1', name: 'srv', hostname: '10.0.0.1'),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: InMemoryLocalFileRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('.env'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('sftp-remote-row-/home/test/logs')),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('.env'), findsNothing);

    final remoteList = find.descendant(
      of: find.byKey(const ValueKey('sftp-remote-pane')),
      matching: find.byType(ListView),
    );
    final position = tester.widget<ListView>(remoteList).controller!.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('端口转发与动态代理支持一键复制地址/代理命令、动态更新网关名、无规则提示与系统代理恢复重试', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final clipboard = _MockClipboard()..install(tester);
    final engine = _CountingSshEngine();
    final lease = _FailRestoreLease();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          sshEngine: engine,
          systemProxy: _FakeSystemProxy(lease),
        ),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final gateways = Get.find<GatewayController>();
    const gateway = Host(
      id: 'gw-1',
      name: 'old-gw',
      hostname: '10.0.0.5',
      forwardPorts: [
        ForwardPort(localPort: 5432, targetHost: '127.0.0.1', targetPort: 5432),
      ],
      proxyConfig: ProxyConfig(
        mode: ProxyMode.rule,
        httpEnabled: true,
        httpPort: 18080,
        httpsEnabled: true,
        httpsPort: 18080,
        socks5Enabled: true,
        socks5Port: 1080,
        autoSystemProxy: true,
      ),
    );
    await gateways.save(gateway);
    final sessions = Get.find<SessionController>();

    // 端口转发复制本地地址。
    final fwdId = sessions.openForward(gateway);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forward-copy-5432')));
    await tester.pump();
    expect(clipboard.text, '127.0.0.1:5432');
    await tester.pump(const Duration(seconds: 2));
    await sessions.close(fwdId);
    await tester.pumpAndSettle();

    // 动态代理面板：网关名响应更新、无规则提示、复制协议地址与终端代理命令。
    final proxyId = sessions.openProxy(gateway);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('proxy-empty-rules-hint')),
      findsOneWidget,
    );

    await gateways.save(gateway.copyWith(name: 'renamed-gw'));
    await tester.pumpAndSettle();
    expect(find.text('关联网关：renamed-gw'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('proxy-copy-http')));
    await tester.pump();
    expect(clipboard.text, 'http://127.0.0.1:18080');
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byKey(const ValueKey('proxy-copy-env')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      clipboard.text,
      'export http_proxy=http://127.0.0.1:18080 https_proxy=http://127.0.0.1:18080 all_proxy=socks5h://127.0.0.1:1080',
    );
    await tester.pump(const Duration(seconds: 6));

    // 启动后监听异常中断且恢复系统代理失败 -> 面板展示显式「重试恢复系统代理」按钮。
    final renamedGateway = gateway.copyWith(name: 'renamed-gw');
    await sessions.startProxy(
      proxyId,
      renamedGateway,
      gateway: SshGateway(
        host: renamedGateway,
        credentials: SshCredentials.password('secret'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-locked-hint')), findsOneWidget);

    engine.proxies.single.ended.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-retry-cleanup')), findsOneWidget);

    lease.shouldFail = false;
    await tester.tap(find.byKey(const ValueKey('proxy-retry-cleanup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-retry-cleanup')), findsNothing);
    expect(lease.restoreCalls, 2);
  });

  testWidgets('命令面板支持多词模糊匹配、分组标题、工作区操作与键盘滚动跟随', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _CountingSshEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final hosts = Get.find<HostController>();
    const production = Host(
      id: 'h-prod',
      name: 'api-gateway',
      hostname: '10.10.1.20',
      port: 2222,
      note: '上海核心节点',
    );
    await hosts.save(production);
    for (var i = 0; i < 20; i++) {
      await hosts.save(
        Host(id: 'h-$i', name: 'worker-$i', hostname: 'worker-$i.test'),
      );
    }
    await Get.find<SessionController>().open(
      production,
      SshCredentials.password('secret'),
    );
    await tester.pumpAndSettle();

    unawaited(showCommandPalette(tester.element(find.byType(PagaShellApp))));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('palette-section-hosts')), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-section-tabs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('palette-section-actions')),
      findsOneWidget,
    );

    final first = find.byKey(const ValueKey('palette-host-h-prod'));
    final second = find.byKey(const ValueKey('palette-host-h-0'));
    final last = find.byKey(const ValueKey('palette-action-open-settings'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(first));
    await tester.pump();
    expect(last.hitTestable(), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(last.hitTestable(), findsOneWidget);
    expect(tester.widget<AppListRow>(last).selected, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(first.hitTestable(), findsOneWidget);
    expect(tester.widget<AppListRow>(first).selected, isTrue);

    await mouse.moveTo(tester.getCenter(second));
    await tester.pump();
    expect(tester.widget<AppListRow>(second).selected, isTrue);
    await mouse.removePointer();

    // 多词跨字段匹配（端口 + 备注）。
    await tester.enterText(find.byType(shadcn.TextField).last, '2222 上海');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('palette-host-h-prod')), findsOneWidget);

    // 执行「切换侧边栏」工作区操作。
    await tester.enterText(find.byType(shadcn.TextField).last, '切换侧边栏');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('palette-action-toggle-sidebar')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('palette-action-toggle-sidebar')),
    );
    await tester.pumpAndSettle();
    expect(Get.find<SettingsController>().sidebarVisible.value, isFalse);
  });

  testWidgets('标签右键菜单支持复制地址、编辑服务与关闭右侧标签，分屏标签聚合错误状态，失败页支持编辑与复制错误', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final clipboard = _MockClipboard()..install(tester);
    final engine = _CountingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();

    final hosts = Get.find<HostController>();
    const host1 = Host(id: 'h1', name: 'web-a', hostname: '10.0.0.1');
    const host2 = Host(id: 'h2', name: 'web-b', hostname: '10.0.0.2');
    await hosts.save(host1);
    await hosts.save(host2);

    final sessions = Get.find<SessionController>();
    final id1 = await sessions.open(host1, SshCredentials.password('p1'));
    final id2 = await sessions.open(host2, SshCredentials.password('p2'));
    await tester.pumpAndSettle();

    // 在标签 1 上分屏并把第二窗格置为失败，标签图标聚合为失败色。
    final splitId = await sessions.splitTerminal(
      id1,
      SessionSplitAxis.horizontal,
    );
    await tester.pumpAndSettle();
    final splitIndex = sessions.sessions.indexWhere((s) => s.id == splitId);
    sessions.sessions[splitIndex] = sessions.sessions[splitIndex].copyWith(
      phase: SessionPhase.failed,
      error: '远端拒绝连接',
    );
    await tester.pumpAndSettle();

    // 失败页展示编辑服务与复制错误信息按钮。
    expect(find.byKey(const ValueKey('failed-edit-host')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('failed-copy-error')));
    await tester.pump();
    expect(clipboard.text, '远端拒绝连接');
    await tester.pump(const Duration(seconds: 2));

    // 分屏标签图标色应体现失败状态（而非仅看选中窗格）。
    sessions.activate(id1);
    await tester.pumpAndSettle();
    final tab1Id = sessions.tabForSession(id1)!.id;
    final tab1Finder = find.byWidgetPredicate(
      (widget) =>
          widget is shadcn.KeyedTabItem<String> && widget.tabKey == tab1Id,
    );
    final tabIcon = tester.widget<AppIcon>(
      find.descendant(of: tab1Finder, matching: findAppIcon(AppIcons.terminal)),
    );
    expect(tabIcon.color, StatusColors.failed);

    // 右键标签 1：复制地址、编辑服务、关闭右侧标签。
    await tester.tap(tab1Finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('文件传输'), findsOneWidget);
    expect(find.text('复制地址'), findsOneWidget);
    expect(find.widgetWithText(shadcn.MenuButton, '编辑服务'), findsOneWidget);
    expect(find.text('关闭右侧标签'), findsOneWidget);
    await tester.tap(find.text('复制地址'));
    await tester.pumpAndSettle();
    expect(clipboard.text, 'root@10.0.0.1');

    await tester.tap(tab1Finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '编辑服务'));
    await tester.pumpAndSettle();
    expect(find.byType(HostEditDialog), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();

    await tester.tap(tab1Finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭右侧标签'));
    await tester.pumpAndSettle();
    expect(sessions.sessions.any((s) => s.id == id2), isFalse);

    final oldTerminal = sessions.sessions
        .firstWhere((s) => s.id == id1)
        .terminal!;
    await tester.tap(tab1Finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '重新连接'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(oldTerminal.isDisposed, isTrue);
    expect(sessions.tabForSession(id1)!.id, tab1Id);
    expect(
      sessions.sessions.firstWhere((s) => s.id == id1).phase,
      SessionPhase.ready,
    );

    await tester.tap(tab1Finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();
    final duplicate = sessions.activeSession!;
    expect(duplicate.id, isNot(id1));
    expect(sessions.tabForSession(duplicate.id)!.id, isNot(tab1Id));
    expect(duplicate.host.id, host1.id);
    expect(duplicate.phase, SessionPhase.ready);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
