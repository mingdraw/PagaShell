import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/forward/forward_session_panel.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _Secrets extends InMemorySecretStore {
  int reads = 0;
  @override
  Future<String?> read(String ref) {
    reads++;
    return super.read(ref);
  }
}

class _ForwardSession implements SshEngineSession, PortForwardSession {
  bool closed = false;
  int shellStarts = 0;
  List<ForwardPort>? ports;
  Completer<void>? closeGate;
  final events = StreamController<PortForwardEvent>();
  final shell = StreamController<String>();

  @override
  Stream<PortForwardEvent> startPortForwards(List<ForwardPort> ports) async* {
    this.ports = ports;
    events.add(const PortForwardEvent(kind: 'ready'));
    // 与 Rust 适配器一致：空闲时正等待下一条 native 事件。
    await for (final event in events.stream) {
      yield event;
    }
  }

  @override
  Stream<String> startShell({required int cols, required int rows}) {
    shellStarts++;
    return shell.stream;
  }

  @override
  void write(String data) {}
  @override
  void resizeTerminal(int width, int height) {}
  @override
  Future<String> canonicalize(String path) async => '/home/root';
  @override
  Future<List<SftpDirEntry>> listDir(String path) async => [];

  @override
  Future<void> close() async {
    final gate = closeGate;
    if (gate != null) await gate.future;
    closed = true;
    unawaited(events.close());
    unawaited(shell.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ForwardEngine implements SshEngine, GatewayForwardEngine {
  final sessions = <_ForwardSession>[];
  final hosts = <Host>[];
  final credentials = <SshCredentials>[];
  final gateways = <SshGateway?>[];
  Completer<void>? connectGate;
  int ordinaryConnects = 0;

  @override
  Future<PortForwardSession> connectForward(
    SshGateway gateway, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  }) => _create(gateway.host, gateway.credentials, gateway);

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    ordinaryConnects++;
    return _create(host, credentials, gateway);
  }

  Future<_ForwardSession> _create(
    Host host,
    SshCredentials credentials,
    SshGateway? gateway,
  ) async {
    hosts.add(host);
    this.credentials.add(credentials);
    gateways.add(gateway);
    final session = _ForwardSession();
    sessions.add(session);
    final gate = connectGate;
    if (gate != null) await gate.future;
    return session;
  }
}

class _DelayedTree extends InMemoryHostTreeRepository {
  _DelayedTree({required super.folders, required super.hosts});
  Completer<void>? saveGate;
  final writes = <List<ForwardPort>>[];

  @override
  Future<Host> saveForwardPorts(String hostId, List<ForwardPort> ports) async {
    writes.add(ports);
    await saveGate?.future;
    return super.saveForwardPorts(hostId, ports);
  }
}

const _ports = [
  ForwardPort(localPort: 13306, targetPort: 3306),
  ForwardPort(localPort: 16379, targetPort: 6379),
];
const _service = Host(
  id: 'service',
  name: 'Database server',
  hostname: 'internal.example.test',
  gatewayId: 'gateway',
);
const _gateway = Host(
  id: 'gateway',
  name: 'Operations gateway',
  hostname: 'jump.example.test',
  forwardPorts: _ports,
);

void main() {
  setUpAll(() async {
    if (Platform.environment['PAGASHELL_FORWARD_CAPTURE_DIR'] == null) return;
    for (final font in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
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
  });

  Future<(_ForwardEngine, _Secrets)> pump(
    WidgetTester tester, {
    Host gateway = _gateway,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _ForwardEngine();
    final secrets = _Secrets();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('forward-capture'),
        child: PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine, secretStore: secrets),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await Get.find<GatewayController>().save(gateway);
    await Get.find<GatewayController>().savePassword(
      gateway.id,
      'gateway-test-only',
    );
    await Get.find<HostController>().save(_service);
    await Get.find<HostController>().savePassword(
      _service.id,
      'service-test-only',
    );
    await tester.pumpAndSettle();
    secrets.reads = 0;
    return (engine, secrets);
  }

  Future<void> field(
    WidgetTester tester,
    String label,
    String value, {
    int index = 0,
  }) async {
    final target = find.widgetWithText(AppTextFormField, label).at(index);
    await tester.ensureVisible(target);
    await tester.enterText(target, value);
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['PAGASHELL_FORWARD_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('forward-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settleCleanup(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }

  Future<String> open(WidgetTester tester, {Host gateway = _gateway}) async {
    final id = Get.find<SessionController>().openForward(gateway);
    await tester.pumpAndSettle();
    return id;
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('启动转发'));
    await tester.pumpAndSettle();
  }

  Future<void> autoSave(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  void expectMappings(WidgetTester tester, List<ForwardPort> ports) {
    final locals = tester.widgetList<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '本地端口'),
    );
    final targets = tester.widgetList<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '目标端口'),
    );
    final hosts = tester.widgetList<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '目标地址'),
    );
    expect(hosts.map((f) => f.controller.text), ports.map((p) => p.targetHost));
    expect(
      locals.map((f) => f.controller.text),
      ports.map((p) => p.localPort.toString()),
    );
    expect(
      targets.map((f) => f.controller.text),
      ports.map((p) => p.targetPort.toString()),
    );
  }

  testWidgets('服务无转发菜单，网关右键只打开一个未启用页签且不读取密文', (tester) async {
    final (engine, secrets) = await pump(tester);
    await Get.find<HostController>().clearPassword(_service.id);
    await Get.find<GatewayController>().clearPassword(_gateway.id);
    await tester.tap(find.text(_service.name), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(shadcn.MenuButton, '端口转发'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text(_gateway.name), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('新建端口转换'), findsNothing);
    expect(find.text('停止转发'), findsNothing);
    expect(
      find.descendant(
        of: find.widgetWithText(shadcn.MenuButton, '端口转发'),
        matching: find.byIcon(shadcn.LucideIcons.arrowLeftRight),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('端口转发'));
    await tester.pumpAndSettle();
    final sessions = Get.find<SessionController>();
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(sessions.openForward(_gateway), sessions.sessions.single.id);
    expect(sessions.sessions, hasLength(1));
    expect(secrets.reads, 0);
    expect(engine.sessions, isEmpty);
    expect(find.text('未启用'), findsOneWidget);
    expectMappings(tester, _ports);
    expect(find.text('*:13306 → 3306'), findsNothing);
    expect(find.text('转发到服务的目标端口，本地监听 *（所有 IPv4 网卡）'), findsNothing);
    expect(findAppIconButton('复制本机端口'), findsNothing);
    expect(find.text('保存配置'), findsNothing);
    final panel = find.byType(ForwardSessionPanel);
    final card = find
        .descendant(of: panel, matching: find.byType(shadcn.Card))
        .first;
    final local = find.widgetWithText(AppTextFormField, '本地端口').first;
    final target = find.widgetWithText(AppTextFormField, '目标端口').first;
    final before = tester.getSize(local).width;
    expect(
      tester.getTopRight(card).dx,
      closeTo(tester.getTopRight(panel).dx - 24, 0.1),
    );
    expect(
      tester.getCenter(findAppIconButton('移除映射').first).dx,
      greaterThan(tester.getTopRight(target).dx),
    );
    tester.view.physicalSize = const Size(1680, 900);
    await tester.pumpAndSettle();
    expect(tester.getSize(local).width, greaterThan(before + 70));
    expect(
      tester.getTopRight(card).dx,
      closeTo(tester.getTopRight(panel).dx - 24, 0.1),
    );
    expect(find.text('连接到 Database server'), findsNothing);
    expect(find.text('名称'), findsNothing);
    expect(find.text('目标地址'), findsNWidgets(2));
    expect(find.text('关联网关：Operations gateway'), findsOneWidget);
    await capture(tester, 'gateway-forward-idle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Page 网关按最新配置和令牌启动 TCP 转发，不登录 SSH 服务', (tester) async {
    final page = _gateway.copyWith(
      gatewayType: GatewayType.page,
      pageClientId: 'internal-client',
      pageServerFingerprint: '',
    );
    final (engine, secrets) = await pump(tester, gateway: page);
    final gateways = Get.find<GatewayController>();
    await tester.tap(find.text(page.name), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('端口转发'));
    await tester.pumpAndSettle();
    expect(secrets.reads, 0);
    expect(engine.sessions, isEmpty);
    expect(
      find.text('目标地址由内网 Client 访问，127.0.0.1 指 Client 本机'),
      findsOneWidget,
    );
    await gateways.clearPassword(page.id);
    await start(tester);
    expect(engine.sessions, isEmpty);
    expect(find.text('Page 访问令牌未保存，请编辑网关'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await gateways.savePassword(page.id, 'page-access-token');
    await field(tester, '目标地址', '10.20.30.40');
    secrets.reads = 0;
    await start(tester);
    expect(secrets.reads, 1);
    expect(engine.ordinaryConnects, 0);
    expect(engine.hosts.single.gatewayType, GatewayType.page);
    expect(engine.hosts.single.pageClientId, 'internal-client');
    expect(engine.credentials.single.password, 'page-access-token');
    expect(engine.sessions.single.ports!.first.targetHost, '10.20.30.40');
    expect(find.text('正在监听'), findsOneWidget);
    await capture(tester, 'page-gateway-forward-ip');
    await tester.tap(find.text('停止转发'));
    await settleCleanup(tester);
    expect(engine.sessions.single.closed, isTrue);
    final stale = gateways.hosts.single;
    await gateways.save(stale.copyWith(pageClientId: 'new-client'));
    await gateways.savePassword(page.id, 'new-token');
    // 模拟树订阅尚未投递最新记录，启动仍须使用已保存配置。
    gateways.hosts.assignAll([stale]);
    final id = Get.find<SessionController>().sessions.single.id;
    await connectToHost(
      tester.element(find.byType(ForwardSessionPanel)),
      stale,
      kind: SessionKind.portForward,
      forwardSessionId: id,
    );
    await tester.pumpAndSettle();
    expect(engine.hosts.last.pageClientId, 'new-client');
    expect(engine.credentials.last.password, 'new-token');
    final closing = Get.find<SessionController>().close(id);
    await settleCleanup(tester);
    await closing;
    expect(engine.sessions.every((s) => s.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入自动保存，空白行不入库，不完整及重复端口不覆盖已存配置', (tester) async {
    final (engine, secrets) = await pump(
      tester,
      gateway: _gateway.copyWith(forwardPorts: []),
    );
    final hosts = Get.find<GatewayController>();
    await open(tester, gateway: hosts.hosts.single);
    await tester.tap(find.text('添加映射'));
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, isEmpty);
    await field(tester, '本地端口', '13306');
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, isEmpty);
    expect(find.text('1-65535'), findsOneWidget);
    await field(tester, '目标端口', '3306');
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, [_ports.first]);
    await tester.tap(find.text('添加映射'));
    await tester.pumpAndSettle();
    await field(tester, '本地端口', '13306', index: 1);
    await field(tester, '目标端口', '6379', index: 1);
    await autoSave(tester);
    expect(find.text('本地端口不能重复'), findsWidgets);
    expect(hosts.hosts.single.forwardPorts, [_ports.first]);
    await field(tester, '本地端口', '16379', index: 1);
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, _ports);
    await tester.tap(find.text('添加映射'));
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, _ports);
    expect(find.widgetWithText(AppTextFormField, '本地端口'), findsNWidgets(3));
    expect(secrets.reads, 0);
    expect(engine.sessions, isEmpty);
    await field(tester, '本地端口', '');
    await field(tester, '目标端口', '');
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, [_ports.last]);
    for (var i = 0; i < 3; i++) {
      await tester.tap(findAppIconButton('移除映射').first);
      await tester.pumpAndSettle();
    }
    await autoSave(tester);
    expect(hosts.hosts.single.forwardPorts, isEmpty);
    await start(tester);
    expect(find.text('请添加至少一组端口映射'), findsOneWidget);
    expect(engine.sessions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('慢写入时输入保持可编辑，连续修改按顺序保存且不重建输入控制器', (tester) async {
    final repository = InMemoryHostRepository();
    final folders = InMemoryFolderRepository();
    final tree = _DelayedTree(hosts: repository, folders: folders);
    final sessions = Get.put(SessionController(engine: _ForwardEngine()));
    final hosts = Get.put(
      GatewayController(
        repository: repository,
        secretStore: InMemorySecretStore(),
        treeRepository: tree,
        sessions: sessions,
        services: InMemoryHostRepository(),
      ),
    );
    await tree.saveHost(_gateway);
    sessions.openForward(_gateway);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Obx(() => ForwardSessionPanel(session: sessions.sessions.single)),
      ),
    );
    await tester.pumpAndSettle();
    final localField = find.widgetWithText(AppTextFormField, '本地端口').first;
    final editor = tester.widget<AppTextFormField>(localField).controller;
    final gate = Completer<void>();
    tree.saveGate = gate;
    await field(tester, '本地端口', '23306');
    await autoSave(tester);
    expect(tree.writes, hasLength(1));
    expect(tester.widget<AppTextFormField>(localField).enabled, isTrue);
    await field(tester, '目标端口', '5432');
    await autoSave(tester);
    expect(tree.writes, hasLength(1));
    tree.saveGate = null;
    gate.complete();
    await tester.pumpAndSettle();
    expect(tree.writes, hasLength(2));
    expect(
      hosts.hosts.single.forwardPorts.first,
      const ForwardPort(localPort: 23306, targetPort: 5432),
    );
    expect(
      tester.widget<AppTextFormField>(localField).controller,
      same(editor),
    );
    expect(editor.text, '23306');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    Get.reset();
    repository.dispose();
    folders.dispose();
  });

  testWidgets('快速关页签仍保存最后有效输入，重开不会恢复旧映射', (tester) async {
    final (engine, _) = await pump(tester);
    final id = await open(tester);
    await field(tester, '本地端口', '24444');
    await field(tester, '目标端口', '5432');
    final closing = Get.find<SessionController>().close(id);
    await settleCleanup(tester);
    await closing;
    final latest = Get.find<GatewayController>().hosts.single;
    expect(
      latest.forwardPorts.first,
      const ForwardPort(localPort: 24444, targetPort: 5432),
    );
    await open(tester, gateway: latest);
    expectMappings(tester, latest.forwardPorts);
    expect(engine.sessions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入后立即启动会先保存最新值并跳过额外空白行', (tester) async {
    final (engine, _) = await pump(tester);
    await open(tester);
    await tester.tap(find.text('添加映射'));
    await tester.pumpAndSettle();
    await field(tester, '本地端口', '25432');
    await field(tester, '目标端口', '5432');
    await start(tester);
    final expected = [
      const ForwardPort(localPort: 25432, targetPort: 5432),
      _ports.last,
    ];
    expect(engine.sessions.single.ports, expected);
    expect(Get.find<GatewayController>().hosts.single.forwardPorts, expected);
    expect(
      Get.find<SessionController>().sessions.single.phase,
      SessionPhase.ready,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动和停止仅按钮内显示进度，内容保留且运行中禁止编辑', (tester) async {
    final (engine, _) = await pump(tester);
    final sessions = Get.find<SessionController>();
    final id = await open(tester);
    final sidebarIcon = find.byIcon(shadcn.LucideIcons.network).first;
    final iconColor = tester.widget<Icon>(sidebarIcon).color;
    engine.connectGate = Completer<void>();
    await tester.tap(find.text('启动转发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sessions.sessions.single.phase, SessionPhase.connecting);
    expect(engine.sessions, hasLength(1));
    expectMappings(tester, _ports);
    final progress = find.byType(shadcn.CircularProgressIndicator);
    final startButton = find.ancestor(
      of: progress,
      matching: find.byType(shadcn.PrimaryButton),
    );
    expect(startButton, findsOneWidget);
    expect(tester.getCenter(progress), tester.getCenter(startButton));
    await capture(tester, 'service-forward-starting');
    engine.connectGate!.complete();
    await tester.pumpAndSettle();
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(engine.sessions.single.ports, _ports);
    expect(engine.sessions.single.shellStarts, 0);
    expect(engine.gateways.single!.host.id, _gateway.id);
    expect(tester.widget<Icon>(sidebarIcon).color, iconColor);
    expect(
      tester
          .widget<AppTextFormField>(
            find.widgetWithText(AppTextFormField, '本地端口').first,
          )
          .enabled,
      isFalse,
    );
    await expectLater(
      Get.find<GatewayController>().saveForwardPorts(_gateway.id, []),
      throwsStateError,
    );
    engine.sessions.single.closeGate = Completer<void>();
    await tester.tap(find.text('停止转发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sessions.sessions.single.phase, SessionPhase.stopping);
    final stopButton = find.ancestor(
      of: progress,
      matching: find.byType(shadcn.OutlineButton),
    );
    expect(stopButton, findsOneWidget);
    expect(tester.getCenter(progress), tester.getCenter(stopButton));
    expectMappings(tester, _ports);
    await capture(tester, 'service-forward-stopping');
    engine.sessions.single.closeGate!.complete();
    await settleCleanup(tester);
    expect(engine.sessions.single.closed, isTrue);
    expect(sessions.sessions.single.id, id);
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(
      tester
          .widget<AppTextFormField>(
            find.widgetWithText(AppTextFormField, '本地端口').first,
          )
          .enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新启动读取最新网关、密文和目标地址，不读取服务凭据', (tester) async {
    final (engine, secrets) = await pump(tester);
    final id = await open(tester);
    await start(tester);
    final sessions = Get.find<SessionController>();
    final stopping = sessions.stopForward(id);
    await settleCleanup(tester);
    await stopping;
    final gateways = Get.find<GatewayController>();
    await gateways.save(
      gateways.hosts.single.copyWith(
        hostname: 'new-jump.test',
        port: 2222,
        username: 'operator',
      ),
    );
    await gateways.savePassword(_gateway.id, 'new-gateway-test-only');
    await tester.pumpAndSettle();
    await field(tester, '本地端口', '23306');
    await field(tester, '目标端口', '5432');
    await field(tester, '目标地址', 'new-db.test');
    await sessions.retry(id);
    expect(engine.sessions, hasLength(1));
    secrets.reads = 0;
    await start(tester);
    expect(engine.sessions, hasLength(2));
    expect(engine.hosts.last.hostname, 'new-jump.test');
    expect(engine.hosts.last.port, 2222);
    expect(engine.hosts.last.username, 'operator');
    expect(engine.credentials.last.password, 'new-gateway-test-only');
    expect(engine.gateways.last!.host.hostname, 'new-jump.test');
    expect(engine.gateways.last!.credentials.password, 'new-gateway-test-only');
    expect(secrets.reads, 1);
    expect(
      engine.sessions.last.ports!.first,
      const ForwardPort(
        localPort: 23306,
        targetHost: 'new-db.test',
        targetPort: 5432,
      ),
    );
    expect(
      gateways.hosts.single.forwardPorts.first,
      engine.sessions.last.ports!.first,
    );
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未启用或已停止的转发关闭标签不弹确认框', (tester) async {
    final (engine, _) = await pump(tester);
    final sessions = Get.find<SessionController>();
    var id = await open(tester);
    await tester.tap(find.byKey(ValueKey('session-tab-close-$id')));
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
    expect(Get.isDialogOpen, isFalse);
    expect(engine.sessions, isEmpty);

    id = await open(tester);
    await start(tester);
    final stopping = sessions.stopForward(id);
    await settleCleanup(tester);
    await stopping;
    await tester.tap(find.byKey(ValueKey('session-tab-close-$id')));
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
    expect(Get.isDialogOpen, isFalse);
    expect(engine.sessions.single.closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭运行中转发先确认，取消保留连接，确认停止并关闭', (tester) async {
    final (engine, _) = await pump(tester);
    final sessions = Get.find<SessionController>();
    final id = await open(tester);
    await start(tester);
    final close = find.byKey(ValueKey('session-tab-close-$id'));
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('停止并关闭标签？'), findsOneWidget);
    expect(find.text('${_gateway.name}（端口转发）'), findsOneWidget);
    expect(engine.sessions.single.closed, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(engine.sessions.single.closed, isFalse);

    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-stop-and-close')));
    await settleCleanup(tester);
    expect(engine.sessions.single.closed, isTrue);
    expect(sessions.sessions, isEmpty);
    expect(Get.isDialogOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['关闭其他标签', '关闭全部标签']) {
    testWidgets('右键$action 统一确认，取消不部分关闭', (tester) async {
      final (engine, _) = await pump(tester);
      final sessions = Get.find<SessionController>();
      final forward = await open(tester);
      await start(tester);
      final keep = sessions.openProxy(_gateway);
      await tester.pumpAndSettle();
      final close = find.byKey(ValueKey('session-tab-close-$keep'));

      Future<void> request() async {
        await tester.tap(close, buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }

      await request();
      expect(find.text('${_gateway.name}（端口转发）'), findsOneWidget);
      expect(find.text('${_gateway.name}（动态代理）'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(sessions.sessions.map((s) => s.id), [forward, keep]);
      expect(sessions.activeSessionId.value, keep);
      expect(engine.sessions.single.closed, isFalse);

      await request();
      await tester.tap(find.byKey(const ValueKey('session-stop-and-close')));
      await settleCleanup(tester);
      expect(engine.sessions.single.closed, isTrue);
      expect(
        sessions.sessions.map((s) => s.id),
        action == '关闭其他标签' ? [keep] : <String>[],
      );
      expect(Get.isDialogOpen, isFalse);
      expect(tester.takeException(), isNull);
      await sessions.closeAll();
    });
  }

  testWidgets('关页签释放连接，重开保持未启用，再启动等待旧监听释放', (tester) async {
    final (engine, _) = await pump(tester);
    final sessions = Get.find<SessionController>();
    final id = await open(tester);
    await start(tester);
    final first = engine.sessions.single;
    first.closeGate = Completer<void>();
    final closing = sessions.close(id);
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
    final reopened = await open(
      tester,
      gateway: Get.find<GatewayController>().hosts.single,
    );
    expect(reopened, isNot(id));
    expect(engine.sessions, hasLength(1));
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    await tester.tap(find.text('启动转发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.sessions, hasLength(1));
    expect(sessions.sessions.single.phase, SessionPhase.connecting);
    first.closeGate!.complete();
    await settleCleanup(tester);
    await closing;
    expect(first.closed, isTrue);
    expect(engine.sessions, hasLength(2));
    expect(engine.sessions.last.ports, _ports);
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除服务不影响转发，删除网关关闭转发，终端和文件传输相互独立', (tester) async {
    final (engine, _) = await pump(tester);
    final sessions = Get.find<SessionController>();
    final forward = await open(tester);
    await start(tester);
    final terminal = await sessions.open(
      _service,
      const SshCredentials.password('terminal-test-only'),
      gateway: const SshGateway(
        host: _gateway,
        credentials: SshCredentials.password('jump-test-only'),
      ),
    );
    final transfer = await sessions.open(
      _service,
      const SshCredentials.password('transfer-test-only'),
      kind: SessionKind.fileTransfer,
      gateway: const SshGateway(
        host: _gateway,
        credentials: SshCredentials.password('jump-test-only'),
      ),
    );
    await tester.pumpAndSettle();
    expect(engine.sessions.map((s) => s.shellStarts), [0, 1, 0]);
    final closingTerminal = sessions.close(terminal);
    await settleCleanup(tester);
    await closingTerminal;
    expect(engine.sessions.first.closed, isFalse);
    expect(engine.sessions.last.closed, isFalse);
    sessions.activate(forward);
    final removingService = Get.find<HostController>().remove(_service.id);
    await settleCleanup(tester);
    await removingService;
    expect(engine.sessions.first.closed, isFalse);
    expect(
      sessions.findByHost(_gateway.id, kind: SessionKind.portForward),
      isNotNull,
    );
    final removing = Get.find<GatewayController>().remove(_gateway.id);
    await settleCleanup(tester);
    await removing;
    expect(
      sessions.findByHost(_gateway.id, kind: SessionKind.portForward),
      isNull,
    );
    expect(engine.sessions.first.closed, isTrue);
    expect(sessions.sessions.single.id, transfer);
    expect(engine.sessions.last.closed, isFalse);
    expect(await Get.find<HostRepository>().getAll(), isEmpty);
    expect(Get.find<GatewayController>().hosts, isEmpty);
    expect(await Get.find<GatewayController>().passwordOf(_gateway.id), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('转发失败释放资源，手动启动可恢复且清除旧错误', (tester) async {
    final (engine, _) = await pump(tester);
    final id = await open(tester);
    await start(tester);
    engine.sessions.single.events.addError(
      const SshEngineException('无法监听本地端口 13306，请检查端口占用或权限'),
    );
    await settleCleanup(tester);
    final sessions = Get.find<SessionController>();
    expect(sessions.sessions.single.phase, SessionPhase.failed);
    expect(engine.sessions.single.closed, isTrue);
    expect(find.text('转发失败'), findsOneWidget);
    await sessions.retry(id);
    expect(engine.sessions, hasLength(1));
    await start(tester);
    expect(engine.sessions, hasLength(2));
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(sessions.sessions.single.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网关编辑和复制保留最新映射，包括编辑弹窗打开后保存的映射', (tester) async {
    await pump(tester);
    final hosts = Get.find<GatewayController>();
    final context = tester.element(find.text(_gateway.name));
    final editing = showHostEditDialog(
      context,
      host: hosts.hosts.single,
      gateway: true,
    );
    await tester.pumpAndSettle();
    const updatedPorts = [ForwardPort(localPort: 15432, targetPort: 5432)];
    await hosts.saveForwardPorts(_gateway.id, updatedPorts);
    await tester.pumpAndSettle();
    await field(tester, '名称', 'Renamed gateway');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await editing;
    expect(hosts.hosts.single.forwardPorts, updatedPorts);
    final copying = showHostEditDialog(
      tester.element(find.text('Renamed gateway')),
      copyFrom: hosts.hosts.single,
      gateway: true,
    );
    await tester.pumpAndSettle();
    await field(tester, '名称', 'Copied gateway');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await copying;
    expect(hosts.hosts, hasLength(2));
    expect(
      hosts.hosts.firstWhere((h) => h.name == 'Copied gateway').forwardPorts,
      updatedPorts,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('多映射可滚动，指纹确认置顶，英文小窗口操作区始终可见', (tester) async {
    final many = _gateway.copyWith(
      forwardPorts: [
        for (var i = 0; i < 8; i++)
          ForwardPort(localPort: 15000 + i, targetPort: 3306 + i),
      ],
    );
    await pump(tester, gateway: many);
    final id = await open(tester, gateway: many);
    final sessions = Get.find<SessionController>();
    sessions.sessions[0] = Session(
      id: id,
      host: many,
      kind: SessionKind.portForward,
      phase: SessionPhase.hostKeyPending,
      hostKeyReview: const HostKeyReview(
        presented: SshHostKey(
          hostname: 'internal.example.test',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:test-only',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('信任并连接').hitTestable(), findsOneWidget);
    await capture(tester, 'service-forward-fingerprint');
    sessions.sessions[0] = Session(
      id: id,
      host: many,
      kind: SessionKind.portForward,
      phase: SessionPhase.closed,
    );
    // GetX 的 performReassemble 需要在组件测试的 fakeAsync 时钟外推进。
    await tester.runAsync(() async {
      unawaited(Get.updateLocale(AppTranslations.englishLocale));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpAndSettle();
    for (final label in ['Add mapping', 'Start forwarding']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    final lastField = find.widgetWithText(AppTextFormField, 'Local port').last;
    await tester.ensureVisible(lastField);
    await tester.pumpAndSettle();
    expect(find.text('Save configuration'), findsNothing);
    expect(find.text('Start forwarding').hitTestable(), findsOneWidget);
    await capture(tester, 'service-forward-english-small');
    expect(tester.takeException(), isNull);
  });
}
