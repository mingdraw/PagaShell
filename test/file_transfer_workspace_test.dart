import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:xterm/xterm.dart';

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/in_memory_local_file_repository.dart';
import 'support/shadcn_test_app.dart';

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

class _Engine implements SshEngine {
  _Engine(this.localFiles);

  final InMemoryLocalFileRepository localFiles;
  final sessions = <FakeSftpSession>[];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final session = FakeSftpSession(localFiles: localFiles);
    sessions.add(session);
    return session;
  }
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key, [
  String name = 'sftp-workspace',
]) async {
  if (_captureDir.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(_captureDir).createSync(recursive: true);
      File('$_captureDir/$name.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
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
  tearDown(Get.reset);

  Future<(_Engine, GlobalKey)> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final localFiles = InMemoryLocalFileRepository();
    final engine = _Engine(localFiles);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine, localFiles: localFiles),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    final identity = await Get.find<IdentityController>().saveWithPassword(
      name: 'test',
      username: 'test',
      password: 'secret',
    );
    await Get.find<HostController>().save(
      Host(
        id: 'h1',
        name: 'web-01',
        hostname: 'example.test',
        identityId: identity.id,
      ),
    );
    await tester.pumpAndSettle();
    return (engine, key);
  }

  Future<void> menuAction(
    WidgetTester tester,
    String action, {
    String hostName = 'web-01',
  }) async {
    await tester.tap(find.text(hostName).first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  Future<void> tabMenuAction(
    WidgetTester tester,
    String id,
    String action,
  ) async {
    final controller = Get.find<SessionController>();
    final activeBefore = controller.activeSessionId.value;
    final tab = find.byWidgetPredicate(
      (widget) => widget is shadcn.KeyedTabItem<String> && widget.tabKey == id,
    );
    // 标签内侧留白同样支持右键。
    await tester.tapAt(
      tester.getTopLeft(tab) + Offset(4, tester.getSize(tab).height / 2),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, activeBefore);
    expect(find.text('关闭当前标签'), findsOneWidget);
    expect(find.text('关闭其他标签'), findsOneWidget);
    expect(find.text('关闭全部标签'), findsOneWidget);
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Finder sessionTab(String id) => find.descendant(
    of: find.descendant(
      of: find.byType(shadcn.TabPane<String>),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
    ),
    matching: find.byWidgetPredicate(
      (widget) => widget is shadcn.KeyedTabItem<String> && widget.tabKey == id,
    ),
  );

  Future<void> dragTab(
    WidgetTester tester,
    String id,
    String targetId, {
    required bool after,
  }) async {
    final source = tester.getRect(sessionTab(id));
    final target = tester.getRect(sessionTab(targetId));
    final start = source.centerLeft + const Offset(32, 0);
    final end = Offset(
      target.left + target.width * (after ? 0.75 : 0.25),
      target.center.dy,
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(end.dx > start.dx ? 24 : -24, 0));
    await tester.pump();
    // 拖动副本和原标签同时挂载时也不能重复使用 GlobalKey。
    expect(tester.takeException(), isNull);
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('服务右键文件传输菜单创建双栏标签，重复操作聚焦原标签', (tester) async {
    final (engine, key) = await pumpApp(tester);
    await menuAction(tester, '文件传输');
    final controller = Get.find<SessionController>();
    final transfer = controller.activeSessionId.value;
    expect(controller.sessions.single.kind, SessionKind.fileTransfer);
    expect(engine.sessions.single.shellStarts, 0);
    expect(
      find.descendant(
        of: find.byType(shadcn.KeyedTabItem<String>),
        matching: find.text('web-01'),
      ),
      findsOneWidget,
    );
    expect(find.byType(TerminalView), findsNothing);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('远程文件'), findsOneWidget);
    await _capture(tester, key);
    final transferState = tester.state(find.byType(SftpPanel));
    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(SftpPanel)), same(transferState));
    expect(
      tester.getSize(find.byType(SftpPanel)).width,
      greaterThanOrEqualTo(AppTheme.agentMinWorkspaceWidth - 2),
    );
    expect(
      tester.getRect(find.byType(SftpPanel)).right,
      lessThan(tester.getRect(find.byKey(const ValueKey('agent-panel'))).left),
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'sftp-independent-agent-small');
    await tester.tap(findAppIconButton('收起 Agent'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    await menuAction(tester, '文件传输');
    expect(controller.sessions, hasLength(1));
    expect(controller.activeSessionId.value, transfer);
    expect(engine.sessions, hasLength(1));
    expect(engine.sessions.single.shellStarts, 0);
    expect(tester.takeException(), isNull);
    await controller.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('从终端右键打开已有传输标签保留目录，关闭终端不影响文件传输', (tester) async {
    final (engine, key) = await pumpApp(tester);
    await menuAction(tester, '文件传输');
    await tester.tap(find.text('downloads'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('downloads'));
    await tester.pumpAndSettle();
    await menuAction(tester, '新建会话');
    expect(
      tester
          .widget<shadcn.TabPane<String>>(find.byType(shadcn.TabPane<String>))
          .focused,
      1,
    );
    await _capture(tester, key, 'ssh-sftp-tab-pane');
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(SftpPanel), findsNothing);
    expect(find.byType(SftpPanel, skipOffstage: false), findsOneWidget);
    expect(engine.sessions.last.shellStarts, 1);
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    expect(controller.sessions, hasLength(2));
    expect(engine.sessions, hasLength(2));
    expect(controller.activeSession!.kind, SessionKind.fileTransfer);
    expect(
      find.byKey(const ValueKey('sftp-path-/local/downloads')),
      findsOneWidget,
    );
    await tester.tap(findAppIconButton('关闭标签').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(controller.sessions.single.kind, SessionKind.fileTransfer);
    expect(engine.sessions.first.closes, 0);
    expect(engine.sessions.last.closes, 1);
    expect(find.byType(SftpPanel), findsOneWidget);
    await controller.closeActive();
    await tester.pumpAndSettle();
    expect(engine.sessions.first.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签支持向左右拖到邻项前后，保持选中项及终端和传输页面状态', (tester) async {
    final (engine, key) = await pumpApp(tester);
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    final transfer = controller.activeSessionId.value!;
    await tester.tap(find.text('downloads'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('downloads'));
    await tester.pumpAndSettle();
    final transferState = tester.state(find.byType(SftpPanel));
    await menuAction(tester, '新建会话');
    final first = controller.activeSessionId.value!;
    final terminal = controller.activeSession!.terminal!;
    final terminalView = find.byWidgetPredicate(
      (widget) =>
          widget is TerminalView && identical(widget.terminal, terminal),
      skipOffstage: false,
    );
    final terminalState = tester.state(terminalView);
    await menuAction(tester, '新建会话');
    final second = controller.activeSessionId.value!;

    void expectOrder(List<String> ids, String activeId) {
      expect(controller.sessions.map((session) => session.id), ids);
      expect(controller.activeSessionId.value, activeId);
      expect(
        tester
            .widget<shadcn.TabPane<String>>(find.byType(shadcn.TabPane<String>))
            .focused,
        ids.indexOf(activeId),
      );
    }

    // 向右放在目标前方，官方回调中的旧索引不能激活相邻标签。
    await dragTab(tester, transfer, second, after: false);
    expectOrder([first, transfer, second], transfer);
    await dragTab(tester, transfer, second, after: true);
    expectOrder([first, second, transfer], transfer);
    // 向左放在目标后方时同样按会话 ID 保留选中项。
    await dragTab(tester, transfer, first, after: true);
    expectOrder([first, transfer, second], transfer);
    expect(tester.state(find.byType(SftpPanel)), same(transferState));
    expect(
      find.byKey(const ValueKey('sftp-path-/local/downloads')),
      findsOneWidget,
    );
    await _capture(tester, key, 'reordered-session-tabs');
    await dragTab(tester, second, first, after: false);
    expectOrder([second, first, transfer], second);

    expect(tester.state(terminalView), same(terminalState));
    expect(controller.sessions[1].terminal, same(terminal));
    expect(engine.sessions, hasLength(3));
    expect(engine.sessions.map((session) => session.shellStarts), [0, 1, 1]);
    expect(engine.sessions.every((session) => session.closes == 0), isTrue);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('各类标签拖动中刷新仍能排序，后续可选中和右键关闭', (tester) async {
    await pumpApp(tester);
    tester.view.physicalSize = const Size(1600, 800);
    final controller = Get.find<SessionController>();
    final ids = [for (final kind in SessionKind.values) kind.name];
    controller.sessions.addAll([
      for (final kind in SessionKind.values)
        Session(
          id: kind.name,
          host: Host(id: kind.name, name: kind.name, hostname: 'test'),
          kind: kind,
          phase: SessionPhase.failed,
          error: 'fixture',
        ),
    ]);
    controller.activate(ids.last);
    await tester.pumpAndSettle();
    final source = tester.getRect(sessionTab(ids.first));
    final target = tester.getRect(sessionTab(ids.last));
    expect(sessionTab(ids.first).hitTestable(), findsOneWidget);
    expect(sessionTab(ids.last).hitTestable(), findsOneWidget);
    final gesture = await tester.startGesture(
      source.centerLeft + const Offset(32, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(controller.activeSessionId.value, ids.first);
    final updated = controller.sessions.first.copyWith(
      host: controller.sessions.first.host.copyWith(name: 'updated'),
    );
    controller.sessions[0] = updated;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await gesture.moveTo(
      Offset(target.left + target.width * 0.75, target.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.sessions.map((session) => session.id), [
      ...ids.skip(1),
      ids.first,
    ]);
    expect(controller.sessions.last, same(updated));
    expect(controller.activeSessionId.value, ids.first);
    await tester.tap(sessionTab(ids.last));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, ids.last);
    await tabMenuAction(tester, ids.first, '关闭当前标签');
    expect(controller.sessions.map((session) => session.id), ids.skip(1));
    expect(controller.activeSessionId.value, ids.last);
    expect(tester.takeException(), isNull);
    await controller.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('按服务区分传输标签，关闭后再打开才创建新标签', (tester) async {
    final (engine, _) = await pumpApp(tester);
    final hosts = Get.find<HostController>();
    final firstHost = hosts.hosts.single;
    await hosts.save(
      Host(
        id: 'h2',
        name: 'web-02',
        hostname: firstHost.hostname,
        identityId: firstHost.identityId,
      ),
    );
    await tester.pumpAndSettle();
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    final first = controller.activeSessionId.value!;
    await menuAction(tester, '文件传输', hostName: 'web-02');
    final second = controller.activeSessionId.value!;
    expect(second, isNot(first));
    expect(controller.activeSession!.host.id, 'h2');
    await menuAction(tester, '文件传输');
    expect(controller.activeSessionId.value, first);
    expect(controller.sessions, hasLength(2));
    expect(engine.sessions, hasLength(2));
    await controller.close(first);
    await tester.pumpAndSettle();
    await menuAction(tester, '文件传输');
    expect(controller.activeSessionId.value, isNot(first));
    expect(controller.activeSession!.host.id, 'h1');
    expect(controller.sessions, hasLength(2));
    expect(engine.sessions, hasLength(3));
    expect(engine.sessions.first.closes, 1);
    expect(engine.sessions[1].closes, 0);
    await controller.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('同时准备文件传输连接只创建一个标签和连接', (tester) async {
    final (engine, _) = await pumpApp(tester);
    final host = Get.find<HostController>().hosts.single;
    final context = tester.element(find.text('web-01'));
    await Future.wait([
      connectToHost(context, host, kind: SessionKind.fileTransfer),
      connectToHost(context, host, kind: SessionKind.fileTransfer),
    ]);
    await tester.pumpAndSettle();
    final controller = Get.find<SessionController>();
    expect(controller.sessions, hasLength(1));
    expect(engine.sessions, hasLength(1));
    await controller.closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签右键关闭当前仅关闭右键目标，保留当前激活会话', (tester) async {
    final (engine, _) = await pumpApp(tester);
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    final transfer = controller.activeSessionId.value!;
    await menuAction(tester, '新建会话');
    final terminal = controller.activeSessionId.value;

    await tabMenuAction(tester, transfer, '关闭当前标签');

    expect(controller.sessions.single.id, terminal);
    expect(controller.activeSessionId.value, terminal);
    expect(engine.sessions.first.closes, 1);
    expect(engine.sessions.last.closes, 0);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('标签右键关闭其他保留目标传输标签及其目录状态', (tester) async {
    final (engine, _) = await pumpApp(tester);
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    final transfer = controller.activeSessionId.value!;
    await tester.tap(find.text('downloads'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('downloads'));
    await tester.pumpAndSettle();
    await menuAction(tester, '新建会话');
    await menuAction(tester, '新建会话');
    expect(controller.activeSessionId.value, isNot(transfer));

    await tabMenuAction(tester, transfer, '关闭其他标签');

    expect(controller.sessions.single.id, transfer);
    expect(controller.activeSessionId.value, transfer);
    expect(engine.sessions.map((session) => session.closes), [0, 1, 1]);
    expect(find.byType(SftpPanel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sftp-path-/local/downloads')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('标签右键关闭全部释放连接并回到空工作区，保留标签栏', (tester) async {
    final (engine, _) = await pumpApp(tester);
    final controller = Get.find<SessionController>();
    await menuAction(tester, '文件传输');
    await menuAction(tester, '新建会话');

    await tabMenuAction(tester, controller.activeSessionId.value!, '关闭全部标签');

    expect(controller.sessions, isEmpty);
    expect(controller.activeSessionId.value, isNull);
    expect(engine.sessions.every((session) => session.closes == 1), isTrue);
    expect(find.byType(shadcn.KeyedTabItem<String>), findsNothing);
    expect(find.byType(shadcn.TabPane<String>), findsOneWidget);
    expect(find.text('连接你的下一台服务器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口从列表切换标签会自动完整展示，关闭标签保留其他会话', (tester) async {
    final (_, key) = await pumpApp(tester);
    tester.view.physicalSize = const Size(800, 600);
    await menuAction(tester, '文件传输');
    final controller = Get.find<SessionController>();
    final transferId = controller.activeSessionId.value;
    for (var index = 0; index < 8; index++) {
      controller.sessions.add(
        Session(
          id: 'overflow-$index',
          host: Host(
            id: 'host-$index',
            name: 'production-server-with-long-name-$index',
            hostname: 'example.test',
          ),
          phase: SessionPhase.failed,
          error: '连接失败',
        ),
      );
    }
    await tester.pumpAndSettle();
    await _capture(tester, key, 'narrow-tab-pane');
    expect(tester.takeException(), isNull);
    await tester.tap(findAppIconButton('会话列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('production-server-with-long-name-7 · 终端'));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, 'overflow-7');

    final tabList = find.descendant(
      of: find.byType(shadcn.TabPane<String>),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
    );
    void expectTabVisible(String title) {
      final tab = find.widgetWithText(shadcn.KeyedTabItem<String>, title);
      expect(tab, findsOneWidget);
      final viewport = tester.getRect(tabList);
      final bounds = tester.getRect(tab);
      expect(bounds.left, greaterThanOrEqualTo(viewport.left));
      expect(bounds.right, lessThanOrEqualTo(viewport.right));
    }

    expectTabVisible('production-server-with-long-name-7');

    // 从右端再切回左侧不可见项，确认两个方向都能自动定位。
    await tester.tap(findAppIconButton('会话列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('production-server-with-long-name-1 · 终端'));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, 'overflow-1');
    expectTabVisible('production-server-with-long-name-1');

    // 快捷键等通过控制器切换标签时，也需要展示当前标签。
    controller.activate('overflow-7');
    await tester.pumpAndSettle();
    expectTabVisible('production-server-with-long-name-7');
    final lastTab = find.widgetWithText(
      shadcn.KeyedTabItem<String>,
      'production-server-with-long-name-7',
    );
    expect(lastTab, findsOneWidget);
    await tester.tap(
      find.descendant(of: lastTab, matching: findAppIconButton('关闭标签')),
    );
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, 'overflow-6');
    expectTabVisible('production-server-with-long-name-6');

    tester.view.physicalSize = const Size(720, 600);
    await tester.pumpAndSettle();
    expectTabVisible('production-server-with-long-name-6');

    // 手动浏览其他标签后，连接状态等刷新不应把滚动位置拉回选中项。
    final tabScroll = tester.state<ScrollableState>(
      find.descendant(of: tabList, matching: find.byType(Scrollable)),
    );
    tabScroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    controller.sessions.refresh();
    await tester.pumpAndSettle();
    expect(tabScroll.position.pixels, 0);

    // 再次从菜单选择当前会话，也要能找回手动滚出视口的当前标签。
    await tester.tap(findAppIconButton('会话列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('production-server-with-long-name-6 · 终端'));
    await tester.pumpAndSettle();
    expectTabVisible('production-server-with-long-name-6');
    expect(
      controller.sessions.any((session) => session.id == transferId),
      isTrue,
    );
    expect(find.byType(SftpPanel, skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final session in controller.sessions.toList()) {
      await controller.close(session.id);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('大量长短标签混排时切换到远处标签仍完整可见', (tester) async {
    await pumpApp(tester);
    tester.view.physicalSize = const Size(800, 600);
    final controller = Get.find<SessionController>();
    controller.sessions.addAll([
      for (var index = 0; index < 60; index++)
        Session(
          id: 'mixed-$index',
          host: Host(
            id: 'mixed-host-$index',
            name: index % 3 == 0 ? 'production-server-$index' : 's$index',
            hostname: 'example.test',
          ),
          phase: SessionPhase.failed,
          error: '连接失败',
        ),
    ]);
    controller.activate('mixed-0');
    await tester.pumpAndSettle();

    final tabList = find.descendant(
      of: find.byType(shadcn.TabPane<String>),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
    );
    for (final index in [45, 12, 59, 0, 31]) {
      controller.activate('mixed-$index');
      await tester.pumpAndSettle();
      final tab = find.descendant(
        of: tabList,
        matching: find.byKey(ValueKey('mixed-$index')),
      );
      expect(tab, findsOneWidget);
      final viewport = tester.getRect(tabList);
      final bounds = tester.getRect(tab);
      expect(bounds.left, greaterThanOrEqualTo(viewport.left));
      expect(bounds.right, lessThanOrEqualTo(viewport.right));
    }

    // 前一次定位尚在动画中时切换，最终仍展示最新选中的标签。
    controller.activate('mixed-32');
    await tester.pump();
    controller.activate('mixed-2');
    await tester.pumpAndSettle();
    final viewport = tester.getRect(tabList);
    final bounds = tester.getRect(
      find.descendant(
        of: tabList,
        matching: find.byKey(const ValueKey('mixed-2')),
      ),
    );
    expect(bounds.left, greaterThanOrEqualTo(viewport.left));
    expect(bounds.right, lessThanOrEqualTo(viewport.right));
    expect(tester.takeException(), isNull);
  });
}
