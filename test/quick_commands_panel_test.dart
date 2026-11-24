import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/terminal/quick_command.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_settings_repository.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:pagashell/presentation/terminal/app_terminal_view.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/fixture_terminal.dart';
import 'support/in_memory_binding.dart';

class _RecordingSession extends FakeSftpSession {
  final writes = <String>[];

  @override
  void write(String data) => writes.add(data);
}

class _RecordingSshEngine implements SshEngine {
  final sessions = <_RecordingSession>[];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    SshGateway? gateway,
    Future<bool> Function(SshHostKey key)? verifyHostKey,
    Future<void>? cancelled,
  }) async {
    final session = _RecordingSession();
    sessions.add(session);
    return session;
  }
}

const _host = Host(
  id: 'ops-1',
  name: '生产主机',
  hostname: 'ops.example.test',
  username: 'root',
);
const _credentials = SshCredentials.password('secret');

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  test('内置常用指令库数据完整且中英文翻译齐全', () {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = AppTranslations.englishLocale;

    final seenIds = <String>{};
    const properNouns = {'Docker', 'Kubernetes', 'Git'};
    expect(QuickCommandCatalog.categories.length, greaterThanOrEqualTo(10));
    var totalCommands = 0;
    for (final category in QuickCommandCatalog.categories) {
      expect(category.commands, isNotEmpty);
      if (!properNouns.contains(category.title)) {
        expect(category.title.tr, isNot(category.title));
      }
      for (final command in category.commands) {
        totalCommands++;
        expect(seenIds.add(command.id), isTrue);
        expect(command.displayCommand, isNotEmpty);
        expect(command.command.contains('\r'), isFalse);
        expect(command.command.contains('\n'), isFalse);
        expect(command.summary.tr, isNot(command.summary));
      }
    }
    expect(totalCommands, greaterThanOrEqualTo(140));

    final chineseSearch = QuickCommandCatalog.search(
      '磁盘',
      translate: (key) => key.tr,
    );
    expect(chineseSearch.any((match) => match.command.id == 'sys-df'), isTrue);
    final englishSearch = QuickCommandCatalog.search(
      'certificate',
      translate: (key) => key.tr,
    );
    expect(
      englishSearch.any((match) => match.command.id == 'web-ssl-dates'),
      isTrue,
    );
  });

  testWidgets('从底部展开常用指令，左右 Tab 切换、Badge 悬停提示、点击自动输入并支持拖拽调高', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _RecordingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(sshEngine: engine)),
    );
    await tester.pumpAndSettle();

    final controller = Get.find<SessionController>();
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();

    final terminal = controller.activeSession!.terminal!;
    terminal.writeText(List.generate(120, (i) => 'line $i\r\n').join());
    await tester.pumpAndSettle();
    final terminalViewState = tester.state<TerminalViewState>(
      find.byType(TerminalView),
    );
    final scroll = terminalViewState.widget.scrollController!;
    scroll.jumpTo(scroll.position.maxScrollExtent - 180);
    await tester.pumpAndSettle();
    final initialScrollOffset = scroll.offset;

    final toggle = find.byKey(
      const ValueKey('terminal-toolbar-quick-commands'),
    );
    final dragger = find.byKey(const ValueKey('terminal-bottom-panel-dragger'));
    final panel = find.byKey(const ValueKey('quick-commands-panel'));
    expect(toggle, findsOneWidget);
    expect(dragger, findsNothing);
    expect(panel, findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(panel, findsOneWidget);
    expect(dragger, findsOneWidget);
    expect(
      find.byKey(const ValueKey('terminal-bottom-panel-resizable')),
      findsOneWidget,
    );

    // 底部面板位于终端下方，且内部 Tab 栏与命令区域呈左右布局。
    final terminalRect = tester.getRect(find.byType(AppTerminalView));
    final panelRect = tester.getRect(panel);
    expect(panelRect.top, greaterThanOrEqualTo(terminalRect.bottom));
    final tabsRect = tester.getRect(
      find.byKey(const ValueKey('quick-commands-tabs')),
    );
    final listRect = tester.getRect(
      find.byKey(const ValueKey('quick-commands-list')),
    );
    expect(tabsRect.right, lessThanOrEqualTo(listRect.left + 1));
    final headerRect = tester.getRect(
      find.byKey(const ValueKey('quick-commands-header')),
    );
    final searchFieldRect = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('quick-commands-search')),
        matching: find.byType(shadcn.TextField),
      ),
    );
    expect(searchFieldRect.center.dy, closeTo(headerRect.center.dy, 1.5));

    // 默认显示“系统”分类下的 Badge，悬停后展示功能介绍 Tips。
    final dfBadge = find.byKey(const ValueKey('quick-command-sys-df'));
    expect(dfBadge, findsOneWidget);
    expect(tester.widget<shadcn.OutlineBadge>(dfBadge), isNotNull);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(dfBadge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(shadcn.TooltipContainer), findsOneWidget);
    expect(find.text('查看各磁盘分区容量与挂载点使用率'), findsOneWidget);

    // 点击 Badge 自动输入到聚焦终端（不附带回车），并回到底部且保持终端焦点。
    await tester.tap(dfBadge);
    await tester.pumpAndSettle();
    expect(engine.sessions.single.writes, ['df -h']);
    expect(
      tester.state<TerminalViewState>(find.byType(TerminalView)),
      same(terminalViewState),
    );
    expect(scroll.offset, greaterThan(initialScrollOffset));
    final terminalFocus = tester
        .widget<AppTerminalView>(find.byType(AppTerminalView))
        .focusNode;
    expect(terminalFocus.hasFocus, isTrue);

    // 切换到左侧 Docker 与数据库 Tab。
    await tester.tap(find.byKey(const ValueKey('quick-commands-tab-docker')));
    await tester.pumpAndSettle();
    final dockerLogsBadge = find.byKey(
      const ValueKey('quick-command-docker-logs'),
    );
    expect(dockerLogsBadge, findsOneWidget);
    await tester.tap(dockerLogsBadge);
    await tester.pumpAndSettle();
    expect(engine.sessions.single.writes.last, 'docker logs -f --tail 100 ');
    expect(terminalFocus.hasFocus, isTrue);

    final databaseTab = find.byKey(
      const ValueKey('quick-commands-tab-database'),
    );
    await tester.ensureVisible(databaseTab);
    await tester.pumpAndSettle();
    await tester.tap(databaseTab);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quick-command-db-mysql-login')),
      findsOneWidget,
    );

    // 拖拽底部分隔手柄调整高度，并在收起后重新展开保留高度。
    final initialHeight = tester.getSize(panel).height;
    await tester.dragFrom(tester.getCenter(dragger), const Offset(0, -100));
    await tester.pumpAndSettle();
    final tallerHeight = tester.getSize(panel).height;
    expect(tallerHeight, greaterThan(initialHeight + 60));

    await tester.dragFrom(tester.getCenter(dragger), const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(panel).height,
      closeTo(AppTheme.terminalQuickCommandsMinHeight, 2),
    );

    await tester.dragFrom(tester.getCenter(dragger), const Offset(0, -140));
    await tester.pumpAndSettle();
    final preferredHeight = tester.getSize(panel).height;

    // 窗口高度不足时自动隐藏，恢复高度后还原用户高度。
    tester.view.physicalSize = const Size(1280, 220);
    await tester.pumpAndSettle();
    expect(dragger, findsNothing);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, closeTo(preferredHeight, 2));

    // 收起后再展开保留首选高度，且不销毁终端实例。
    await tester.tap(find.byKey(const ValueKey('quick-commands-close')));
    await tester.pumpAndSettle();
    expect(dragger, findsNothing);
    expect(terminalFocus.hasFocus, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, closeTo(preferredHeight, 2));
    expect(
      tester.state<TerminalViewState>(find.byType(TerminalView)),
      same(terminalViewState),
    );
    expect(tester.takeException(), isNull);

    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('分屏时点击常用指令只填入当前聚焦窗格，支持跨分类搜索与断开提示', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _RecordingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(sshEngine: engine)),
    );
    await tester.pumpAndSettle();

    final controller = Get.find<SessionController>();
    final firstId = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await controller.splitTerminal(firstId, SessionSplitAxis.horizontal);
    await tester.pumpAndSettle();
    expect(engine.sessions.length, 2);

    // 展开底部常用指令面板（当前聚焦为第二个分屏窗格）。
    await tester.tap(
      find.byKey(const ValueKey('terminal-toolbar-quick-commands')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-commands-target')), findsOneWidget);

    // 跨分类搜索 Redis，无需切换 Tab 即可找到并点击输入到第二个窗格。
    await tester.enterText(
      find.byKey(const ValueKey('quick-commands-search')),
      'redis',
    );
    await tester.pumpAndSettle();
    final redisPing = find.byKey(const ValueKey('quick-command-db-redis-ping'));
    expect(redisPing, findsOneWidget);
    await tester.tap(redisPing);
    await tester.pumpAndSettle();
    expect(engine.sessions[0].writes, isEmpty);
    expect(engine.sessions[1].writes, ['redis-cli ping']);

    // 搜不到时展示空状态；点击左侧分类 Tab 自动清空搜索并切换分类。
    await tester.enterText(
      find.byKey(const ValueKey('quick-commands-search')),
      'nonexistent-cmd-xyz',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-commands-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-commands-tab-network')));
    await tester.pumpAndSettle();
    final ssBadge = find.byKey(const ValueKey('quick-command-net-ss'));
    expect(ssBadge, findsOneWidget);

    // 切换焦点到第一个分屏窗格后，点击指令输入到第一个窗格。
    controller.activate(firstId);
    await tester.pumpAndSettle();
    await tester.tap(ssBadge);
    await tester.pumpAndSettle();
    expect(engine.sessions[0].writes, ['ss -tulpn']);
    expect(engine.sessions[1].writes, ['redis-cli ping']);

    // 断开当前聚焦终端后点击指令给出友好提示而不抛异常。
    await engine.sessions[0].endShell();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(controller.activeSession!.phase, SessionPhase.closed);
    await tester.tap(ssBadge);
    await tester.pumpAndSettle();
    expect(find.text('当前终端未就绪，无法填入指令'), findsOneWidget);
    expect(engine.sessions[0].writes, ['ss -tulpn']);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  test('Drift 持久化自定义常用指令分组与指令，并校验输入与损坏数据', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftSettingsRepository(db);
    final settings = SettingsController(repository: repo);
    addTearDown(settings.onClose);

    await settings.ready;
    expect(settings.customQuickCommandGroups, isEmpty);

    final group = await settings.addQuickCommandGroup('Kubernetes');
    final cmd = await settings.addQuickCommand(
      group.id,
      command: 'kubectl logs -f ',
      summary: '实时查看 Pod 日志',
    );
    expect(cmd.command, 'kubectl logs -f ');
    expect(cmd.displayCommand, 'kubectl logs -f');
    expect(cmd.isBuiltIn, isFalse);

    await expectLater(
      settings.addQuickCommandGroup('kubernetes'),
      throwsA(isA<QuickCommandsException>()),
    );
    await expectLater(
      settings.addQuickCommand(group.id, command: 'echo 1\necho 2'),
      throwsA(isA<QuickCommandsException>()),
    );

    final persisted = await repo.readCustomQuickCommandGroups();
    expect(persisted.length, 1);
    expect(persisted.single.title, 'Kubernetes');
    expect(persisted.single.commands.single.command, 'kubectl logs -f ');
    expect(persisted.single.commands.single.summary, '实时查看 Pod 日志');

    await settings.renameQuickCommandGroup(group.id, 'K8s 集群');
    await settings.updateQuickCommand(
      group.id,
      cmd.id,
      command: 'kubectl get pods -A',
      summary: '查看全部命名空间 Pod',
    );
    final updated = await repo.readCustomQuickCommandGroups();
    expect(updated.single.title, 'K8s 集群');
    expect(updated.single.commands.single.command, 'kubectl get pods -A');

    await settings.deleteQuickCommand(group.id, cmd.id);
    expect(
      (await repo.readCustomQuickCommandGroups()).single.commands,
      isEmpty,
    );

    await settings.deleteQuickCommandGroup(group.id);
    expect(await repo.readCustomQuickCommandGroups(), isEmpty);

    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'custom_quick_commands',
            value: '{"invalid":true}',
          ),
        );
    final brokenController = SettingsController(repository: repo);
    addTearDown(brokenController.onClose);
    await brokenController.ready;
    expect(brokenController.quickCommandsLoadFailed.value, isTrue);
    await expectLater(
      brokenController.addQuickCommandGroup('新分组'),
      throwsA(isA<QuickCommandsException>()),
    );
  });

  testWidgets('设置常用指令 Tab 支持新增/重命名/删除分组与指令，并实时同步到终端底部面板', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _RecordingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(sshEngine: engine)),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    final settings = Get.find<SettingsController>();
    await sessions.open(_host, _credentials);
    await tester.pumpAndSettle();

    // 从终端底部面板快捷管理按钮直接打开设置「常用指令」Tab。
    await tester.tap(
      find.byKey(const ValueKey('terminal-toolbar-quick-commands')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-commands-manage')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-quick-commands-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-quick-commands-empty')),
      findsOneWidget,
    );

    // 新建自定义分组。
    await tester.tap(
      find.byKey(const ValueKey('settings-quick-commands-add-group')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-group-name-input')),
      '项目发布',
    );
    await tester.tap(find.byKey(const ValueKey('settings-quick-group-save')));
    await tester.pumpAndSettle();

    expect(settings.customQuickCommandGroups.length, 1);
    final groupId = settings.customQuickCommandGroups.single.id;
    expect(find.text('项目发布'), findsWidgets);

    // 尝试创建重复分组名触发校验。
    await tester.tap(
      find.byKey(const ValueKey('settings-quick-commands-add-group')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-group-name-input')),
      '项目发布',
    );
    await tester.tap(find.byKey(const ValueKey('settings-quick-group-save')));
    await tester.pumpAndSettle();
    expect(find.text('分组名称已存在'), findsOneWidget);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消').last);
    await tester.pumpAndSettle();

    // 在分组中添加自定义指令。
    await tester.tap(
      find.byKey(ValueKey('settings-quick-group-add-cmd-$groupId')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-cmd-input')),
      'kubectl get pods -n ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-cmd-summary-input')),
      '查看指定命名空间的 Pod',
    );
    await tester.tap(find.byKey(const ValueKey('settings-quick-cmd-save')));
    await tester.pumpAndSettle();

    final commandId =
        settings.customQuickCommandGroups.single.commands.single.id;
    expect(find.text('kubectl get pods -n'), findsWidgets);
    expect(find.text('查看指定命名空间的 Pod'), findsOneWidget);

    // 重命名分组并编辑指令。
    await tester.tap(
      find.byKey(ValueKey('settings-quick-group-rename-$groupId')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-group-name-input')),
      'K8s 运维',
    );
    await tester.tap(find.byKey(const ValueKey('settings-quick-group-save')));
    await tester.pumpAndSettle();
    expect(settings.customQuickCommandGroups.single.title, 'K8s 运维');

    await tester.tap(
      find.byKey(ValueKey('settings-quick-cmd-edit-$commandId')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-quick-cmd-input')),
      'kubectl get pods -A',
    );
    await tester.tap(find.byKey(const ValueKey('settings-quick-cmd-save')));
    await tester.pumpAndSettle();

    // 关闭设置弹窗后，终端底部面板立即显示自定义分组与指令，支持悬停提示和点击自动输入。
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);

    final customTab = find.byKey(ValueKey('quick-commands-tab-$groupId'));
    expect(customTab, findsOneWidget);
    await tester.tap(customTab);
    await tester.pumpAndSettle();

    final customBadge = find.byKey(ValueKey('quick-command-$commandId'));
    expect(customBadge, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(customBadge));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('查看指定命名空间的 Pod'), findsOneWidget);

    await tester.tap(customBadge);
    await tester.pumpAndSettle();
    expect(engine.sessions.single.writes, ['kubectl get pods -A']);

    // 再次打开设置删除指令和分组。
    await tester.tap(find.byKey(const ValueKey('quick-commands-manage')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('settings-quick-cmd-delete-$commandId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-quick-cmd-confirm-delete')),
    );
    await tester.pumpAndSettle();
    expect(settings.customQuickCommandGroups.single.commands, isEmpty);

    await tester.tap(
      find.byKey(ValueKey('settings-quick-group-delete-$groupId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-quick-group-confirm-delete')),
    );
    await tester.pumpAndSettle();
    expect(settings.customQuickCommandGroups, isEmpty);
    expect(
      find.byKey(const ValueKey('settings-quick-commands-empty')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();
    await tester.runAsync(sessions.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('设置常用指令支持拖拽排序分组、组内排序指令与跨分组拖入，并实时同步底部面板顺序', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = _RecordingSshEngine();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(sshEngine: engine)),
    );
    await tester.pumpAndSettle();

    final sessions = Get.find<SessionController>();
    final settings = Get.find<SettingsController>();
    await sessions.open(_host, _credentials);
    await tester.pumpAndSettle();

    final groupA = await settings.addQuickCommandGroup('分组 A');
    final groupB = await settings.addQuickCommandGroup('分组 B');
    final groupEmpty = await settings.addQuickCommandGroup('空分组 C');
    final cmd1 = await settings.addQuickCommand(
      groupA.id,
      command: 'echo first',
      summary: '第一条',
    );
    final cmd2 = await settings.addQuickCommand(
      groupA.id,
      command: 'echo second',
      summary: '第二条',
    );
    final cmd3 = await settings.addQuickCommand(
      groupB.id,
      command: 'echo third',
      summary: '第三条',
    );
    await tester.pumpAndSettle();

    // 展开底部常用指令面板并打开设置管理。
    await tester.tap(
      find.byKey(const ValueKey('terminal-toolbar-quick-commands')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-commands-manage')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-quick-commands-tree')),
      findsOneWidget,
    );

    // 验证 Tree 分组折叠与展开：点击分组折叠后子指令高度收起为 0，再次点击展开。
    final groupATreeItem = find.byKey(
      ValueKey('settings-quick-group-${groupA.id}'),
    );
    final cmd1TreeItem = find.byKey(ValueKey('settings-quick-cmd-${cmd1.id}'));
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));
    await tester.tap(
      find.descendant(of: groupATreeItem, matching: find.text('分组 A')),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(cmd1TreeItem).height, 0);
    await tester.tap(
      find.descendant(of: groupATreeItem, matching: find.text('分组 A')),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));

    // 验证全部折叠 / 全部展开按钮。
    final toggleAll = find.byKey(
      const ValueKey('settings-quick-commands-toggle-all'),
    );
    await tester.tap(toggleAll);
    await tester.pumpAndSettle();
    expect(find.text('全部展开'), findsOneWidget);
    expect(tester.getSize(cmd1TreeItem).height, 0);
    await tester.tap(toggleAll);
    await tester.pumpAndSettle();
    expect(find.text('全部折叠'), findsOneWidget);
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));

    Future<void> dragBetween(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // 1) 组内拖拽排序指令：将 cmd1 拖到 cmd2 下半区，交换顺序。
    final cmd1Handle = find.byKey(
      ValueKey('settings-quick-cmd-drag-${cmd1.id}'),
    );
    final cmd2Slot = find.byKey(ValueKey('settings-quick-cmd-slot-${cmd2.id}'));
    final cmd2Rect = tester.getRect(cmd2Slot);
    await dragBetween(
      tester.getCenter(cmd1Handle),
      Offset(cmd2Rect.center.dx, cmd2Rect.bottom - 4),
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupA.id)
          .commands
          .map((c) => c.id)
          .toList(),
      [cmd2.id, cmd1.id],
    );

    // 2) 跨分组拖拽指令到空分组：将 cmd3 拖到 groupEmpty 的空投放区。
    final cmd3Handle = find.byKey(
      ValueKey('settings-quick-cmd-drag-${cmd3.id}'),
    );
    final emptyDrop = find.byKey(
      ValueKey('settings-quick-group-empty-drop-${groupEmpty.id}'),
    );
    await dragBetween(
      tester.getCenter(cmd3Handle),
      tester.getCenter(emptyDrop),
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupB.id)
          .commands,
      isEmpty,
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupEmpty.id)
          .commands
          .map((c) => c.id)
          .toList(),
      [cmd3.id],
    );

    // 3) 拖拽排序分组：将 groupEmpty 拖到 groupA 上半区，置顶显示。
    final emptyHandle = find.byKey(
      ValueKey('settings-quick-group-drag-${groupEmpty.id}'),
    );
    final groupASlot = find.byKey(
      ValueKey('settings-quick-group-slot-${groupA.id}'),
    );
    final groupARect = tester.getRect(groupASlot);
    await dragBetween(
      tester.getCenter(emptyHandle),
      Offset(groupARect.center.dx, groupARect.top + 8),
    );
    expect(settings.customQuickCommandGroups.map((g) => g.id).toList(), [
      groupEmpty.id,
      groupA.id,
      groupB.id,
    ]);

    // 关闭设置后，底部面板的左侧 Tab 与右侧指令顺序同步更新。
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();

    final tabEmptyRect = tester.getRect(
      find.byKey(ValueKey('quick-commands-tab-${groupEmpty.id}')),
    );
    final tabARect = tester.getRect(
      find.byKey(ValueKey('quick-commands-tab-${groupA.id}')),
    );
    expect(tabEmptyRect.top, lessThan(tabARect.top));

    await tester.tap(find.byKey(ValueKey('quick-commands-tab-${groupA.id}')));
    await tester.pumpAndSettle();
    final badge2Rect = tester.getRect(
      find.byKey(ValueKey('quick-command-${cmd2.id}')),
    );
    final badge1Rect = tester.getRect(
      find.byKey(ValueKey('quick-command-${cmd1.id}')),
    );
    expect(badge2Rect.left, lessThan(badge1Rect.left));
    expect(tester.takeException(), isNull);

    await tester.runAsync(sessions.closeAll);
    await tester.pumpAndSettle();
  });
}
