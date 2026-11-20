import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_endpoint.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/files/io_local_file_repository.dart';
import 'package:pagashell/presentation/components/app_list_row.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';
import 'package:pagashell/presentation/terminal/app_terminal_view.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

import 'support/fake_sftp_session.dart';
import 'support/fixture_terminal.dart' show TerminalFixtureOutput;
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _TestEngine implements SshEngine {
  final attempts = <(Host, SshCredentials)>[];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    attempts.add((host, credentials));
    return FakeSftpSession();
  }
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  test('SSH 解析区分 IPv6、端口与未支持的命令参数', () {
    expect(parseSshEndpoint('deploy@server.test:2222'), (
      hostname: 'server.test',
      username: 'deploy',
      port: 2222,
    ));
    expect(parseSshEndpoint(' ssh -p 2200 deploy@[2001:db8::1] '), (
      hostname: '2001:db8::1',
      username: 'deploy',
      port: 2200,
    ));
    expect(parseSshEndpoint('ssh deploy@::1'), (
      hostname: '::1',
      username: 'deploy',
      port: null,
    ));
    expect(parseSshEndpoint('ssh -J bastion root@host'), isNull);
    expect(parseSshEndpoint('ssh -p 2222 root@host:3000'), isNull);
    expect(parseSshEndpoint('root@host:65536'), isNull);
  });

  testWidgets('新建服务拆填 SSH 地址，保存标签色标，并连接一次', (tester) async {
    viewport(tester);
    final engine = _TestEngine();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('host-address')),
      'ssh -p 2222 deploy@[2001:db8::1]',
    );
    expect(find.text('2001:db8::1'), findsOneWidget);
    expect(find.text('deploy'), findsOneWidget);
    expect(find.text('2222'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('host-password')),
      'fake-password',
    );
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    final tags = find.byKey(const ValueKey('host-tags'));
    await tester.ensureVisible(tags);
    await tester.enterText(tags, 'prod, db，prod');
    final color = find.byKey(const ValueKey('host-color'));
    await tester.ensureVisible(color);
    await tester.pumpAndSettle();
    await tester.tap(find.text('无色标'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生产 · 红色').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-save-connect')));
    await tester.pumpAndSettle();
    final host = Get.find<HostController>().hosts.single;
    expect(host.hostname, '2001:db8::1');
    expect(host.port, 2222);
    expect(host.username, 'deploy');
    expect(host.tags, ['prod', 'db']);
    expect(host.colorValue, isNotNull);
    expect(engine.attempts.single.$1.id, host.id);
    expect(
      Get.find<SessionController>().activeSession?.phase,
      SessionPhase.ready,
    );
  });

  testWidgets('侧栏按目录和标签搜索三类记录，键盘可打开凭证并保留活动服务高亮', (tester) async {
    viewport(tester);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: _TestEngine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
    final group = await Get.find<FolderController>().create(name: 'production');
    final host = Host(
      id: 'sw',
      name: 'switch',
      hostname: 'switch.test',
      folderId: group.id,
      tags: const ['infra'],
    );
    await Get.find<HostController>().save(host);
    await Get.find<GatewayController>().save(
      const Host(
        id: 'infra-gw',
        name: 'Infra gateway',
        hostname: 'gateway.test',
      ),
    );
    await Get.find<IdentityController>().saveWithPassword(
      name: 'Infra login',
      username: 'deploy',
      password: 'fake-password',
    );
    final sessions = Get.find<SessionController>();
    await sessions.open(host, const SshCredentials.password('fake-password'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('sidebar-search'));
    await tester.enterText(search, 'production infra');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('production · root@switch.test'),
      findsOneWidget,
    );
    expect(find.text('Infra gateway'), findsNothing);

    await tester.enterText(search, 'infra');
    await tester.pumpAndSettle();
    for (final section in ['services', 'identities', 'gateways']) {
      expect(find.byKey(ValueKey('sidebar-search-$section')), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('编辑凭证'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('production'));
    await tester.pumpAndSettle();
    final row = tester.widget<AppListRow>(
      find.byKey(const ValueKey('sidebar-host-row-sw')),
    );
    expect(row.selected, isTrue);
    expect(row.subtitle, isNull);
    final tags = tester.widget<Text>(
      find.byKey(const ValueKey('sidebar-host-tags-sw')),
    );
    expect(tags.data, 'infra');
  });

  testWidgets('侧栏按协议搜索时只匹配服务或网关的实际协议', (tester) async {
    viewport(tester);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    await Get.find<HostController>().save(
      const Host(id: 'a', name: 'Linux box', hostname: 'a.test'),
    );
    await Get.find<HostController>().save(
      const Host(
        id: 'b',
        name: 'Windows box',
        hostname: 'b.test',
        serviceType: ServiceType.rdp,
      ),
    );
    await Get.find<HostController>().save(
      const Host(
        id: 'c',
        name: 'Screen share',
        hostname: 'c.test',
        serviceType: ServiceType.vnc,
      ),
    );
    await Get.find<GatewayController>().save(
      const Host(id: 'd', name: 'Bastion', hostname: 'd.test'),
    );
    await Get.find<GatewayController>().save(
      const Host(
        id: 'e',
        name: 'Site relay',
        hostname: 'e.test',
        gatewayType: GatewayType.page,
      ),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('sidebar-search'));
    await tester.enterText(search, 'ssh');
    await tester.pumpAndSettle();
    expect(find.text('Linux box'), findsOneWidget);
    expect(find.text('Bastion'), findsOneWidget);
    expect(find.text('Windows box'), findsNothing);
    expect(find.text('Screen share'), findsNothing);
    expect(find.text('Site relay'), findsNothing);
  });

  testWidgets('终端查找导航到历史匹配，新输出提示可回到底部', (tester) async {
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: AppTerminalView(terminal, focusNode: focus, active: true),
      ),
    );
    terminal.writeText(
      'match ALPHA\r\n${List.filled(90, 'log line\r\n').join()}match alpha',
    );
    await tester.pumpAndSettle();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    final position = view.scrollController!.position;
    expect(position.pixels, position.maxScrollExtent);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('terminal-find-input'));
    expect(find.text('0/0'), findsNothing);
    await tester.enterText(search, 'alpha');
    await tester.pump(const Duration(milliseconds: 170));
    for (var i = 0; i < 50 && find.text('2/2').evaluate().isEmpty; i++) {
      // The search worker runs outside the widget test clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    final editor = tester.widget<EditableText>(
      find.descendant(of: search, matching: find.byType(EditableText)),
    );
    expect(
      editor.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    const composing = TextEditingValue(
      text: 'alpha',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    tester.testTextInput.updateEditingValue(composing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
    expect(editor.focusNode.hasFocus, isTrue);
    expect(editor.controller.value, composing);
    tester.testTextInput.updateEditingValue(
      composing.copyWith(composing: TextRange.empty),
    );
    await tester.pump(const Duration(milliseconds: 170));
    for (var i = 0; i < 50 && find.text('2/2').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.text('2/2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(position.pixels, lessThan(position.maxScrollExtent));
    terminal.writeText('\r\nnew output');
    await tester.pumpAndSettle();
    expect(find.text('回到底部 · 有新输出'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-scroll-bottom')));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(focus.hasPrimaryFocus, isTrue);
    terminal.showAlternateScreen();
    await tester.pump();
    expect(find.text('1/2'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('终端链接仅在主修饰键点击时打开，忽略句末标点', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final opened = <Uri>[];
    await tester.pumpWidget(
      ShadcnTestApp(
        home: TerminalPane(
          terminal,
          focusNode: focus,
          active: true,
          onOpenLink: opened.add,
        ),
      ),
    );
    terminal.writeText('https://example.test/docs.');
    await tester.pumpAndSettle();
    final view = tester.state<TerminalViewState>(find.byType(TerminalView));
    final local =
        view.renderTerminal.getOffset(const CellOffset(5, 0)) +
        const Offset(1, 1);
    final point = view.renderTerminal.localToGlobal(local);
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    expect(opened, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(opened, [Uri.parse('https://example.test/docs')]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('文件窗格预览时外部改动会阻止保存，不会覆盖新内容', (tester) async {
    viewport(tester);
    Get.put(TransferController());
    final directory = Directory.systemTemp.createTempSync('pagashell-text-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/config.conf')
      ..writeAsStringSync('a=1\n');
    final engine = FakeSftpSession();
    addTearDown(engine.close);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 'text',
            host: const Host(
              id: 's',
              name: 'Service',
              hostname: 'service.test',
            ),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: IoLocalFileRepository(userHomeDirectory: directory.path),
        ),
      ),
    );
    for (
      var i = 0;
      i < 30 && find.text('config.conf').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.tap(find.text('config.conf'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看／编辑文本'));
    final editor = find.byKey(const ValueKey('sftp-text-editor'));
    for (var i = 0; i < 30 && editor.evaluate().isEmpty; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pumpAndSettle();
    await tester.enterText(editor, 'a=2\n');
    await tester.pump();
    file.writeAsStringSync('a=3\n');
    await tester.tap(find.byKey(const ValueKey('sftp-text-save')));
    for (
      var i = 0;
      i < 30 && find.text('文件已被修改，请重新打开').evaluate().isEmpty;
      i++
    ) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(find.text('文件已被修改，请重新打开'), findsOneWidget);
    expect(file.readAsStringSync(), 'a=3\n');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同侧拖到目录会移动文件且不覆盖目录里的重名文件', (tester) async {
    viewport(tester);
    final transfers = Get.put(TransferController());
    final root = Directory.systemTemp.createTempSync('pagashell-move-');
    addTearDown(() => root.deleteSync(recursive: true));
    final destination = Directory('${root.path}/archive')..createSync();
    final moving = File('${root.path}/config.conf')..writeAsStringSync('new');
    final source = File('${root.path}/duplicate.conf')
      ..writeAsStringSync('source');
    final existing = File('${destination.path}/duplicate.conf')
      ..writeAsStringSync('existing');
    final engine = FakeSftpSession();
    addTearDown(engine.close);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 'move',
            host: const Host(
              id: 's',
              name: 'Service',
              hostname: 'service.test',
            ),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: IoLocalFileRepository(userHomeDirectory: root.path),
        ),
      ),
    );

    Future<void> waitFor(Finder finder, {bool visible = true}) async {
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump();
        if (finder.evaluate().isNotEmpty == visible) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(finder, visible ? findsOneWidget : findsNothing);
    }

    final dir = find.text('archive');
    await waitFor(dir);
    Future<void> dropInArchive(String name) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(name)),
      );
      await gesture.moveBy(const Offset(15, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(dir));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    await dropInArchive('config.conf');
    await waitFor(find.text('config.conf'), visible: false);
    expect(moving.existsSync(), isFalse);
    expect(File('${destination.path}/config.conf').readAsStringSync(), 'new');

    await waitFor(find.text('duplicate.conf'));
    await dropInArchive('duplicate.conf');
    await waitFor(find.text('部分文件未能移动，请检查重名、目录权限或进行中的传输'));
    expect(source.readAsStringSync(), 'source');
    expect(existing.readAsStringSync(), 'existing');
    expect(transfers.tasks, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
