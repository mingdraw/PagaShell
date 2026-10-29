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

class _ForwardEngine implements SshEngine {
  final sessions = <_ForwardSession>[];
  final hosts = <Host>[];
  final credentials = <SshCredentials>[];
  final gateways = <SshGateway?>[];
  Completer<void>? connectGate;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
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
  forwardPorts: _ports,
);
const _gateway = Host(
  id: 'gateway',
  name: 'Operations gateway',
  hostname: 'jump.example.test',
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
    Host service = _service,
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
    await Get.find<GatewayController>().save(_gateway);
    await Get.find<GatewayController>().savePassword(
      _gateway.id,
      'gateway-test-only',
    );
    await Get.find<HostController>().save(service);
    await Get.find<HostController>().savePassword(
      service.id,
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

  Future<String> open(WidgetTester tester, {Host service = _service}) async {
    final id = Get.find<SessionController>().openForward(service);
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
    expect(
      locals.map((f) => f.controller.text),
      ports.map((p) => p.localPort.toString()),
    );
    expect(
      targets.map((f) => f.controller.text),
      ports.map((p) => p.targetPort.toString()),
    );
  }

  testWidgets('服务右键只打开一个未启用页签，不读取密文或建立连接', (tester) async {
    final (engine, secrets) = await pump(tester);
    await Get.find<HostController>().clearPassword(_service.id);
    await Get.find<GatewayController>().clearPassword(_gateway.id);
    await tester.tap(find.text(_service.name), buttons: kSecondaryButton);
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
    expect(sessions.openForward(_service), sessions.sessions.single.id);
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
    expect(tester.getSize(local).width, greaterThan(before + 100));
    expect(
      tester.getTopRight(card).dx,
      closeTo(tester.getTopRight(panel).dx - 24, 0.1),
    );
    expect(find.text('连接到 Database server'), findsNothing);
    expect(find.text('名称'), findsNothing);
    expect(find.text('目标地址'), findsNothing);
    await capture(tester, 'service-forward-idle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入自动保存，空白行不入库，不完整及重复端口不覆盖已存配置', (tester) async {
    final (engine, secrets) = await pump(
      tester,
      service: _service.copyWith(forwardPorts: []),
    );
    final hosts = Get.find<HostController>();
    await open(tester, service: hosts.hosts.single);
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
      HostController(
        repository: repository,
        secretStore: InMemorySecretStore(),
        treeRepository: tree,
        sessions: sessions,
      ),
    );
    await tree.saveHost(_service);
    sessions.openForward(_service);
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
    final latest = Get.find<HostController>().hosts.single;
    expect(
      latest.forwardPorts.first,
      const ForwardPort(localPort: 24444, targetPort: 5432),
    );
    await open(tester, service: latest);
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
    expect(Get.find<HostController>().hosts.single.forwardPorts, expected);
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
    final sidebarIcon = find.byIcon(shadcn.LucideIcons.fileTerminal).first;
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
      Get.find<HostController>().saveForwardPorts(_service.id, []),
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

  testWidgets('重新启动保存当前映射，并读取更新后的服务、网关及密文', (tester) async {
    final (engine, secrets) = await pump(tester);
    final id = await open(tester);
    await start(tester);
    final sessions = Get.find<SessionController>();
    final stopping = sessions.stopForward(id);
    await settleCleanup(tester);
    await stopping;
    final hosts = Get.find<HostController>();
    final gateways = Get.find<GatewayController>();
    const newGateway = Host(
      id: 'new-gateway',
      name: 'New jump',
      hostname: 'new-jump.test',
      port: 2223,
    );
    await gateways.save(newGateway);
    await gateways.savePassword(newGateway.id, 'new-gateway-test-only');
    await hosts.save(
      hosts.hosts.single.copyWith(
        hostname: 'new-db.test',
        port: 2222,
        username: 'operator',
        gatewayId: newGateway.id,
      ),
    );
    await hosts.savePassword(_service.id, 'new-service-test-only');
    await tester.pumpAndSettle();
    await field(tester, '本地端口', '23306');
    await field(tester, '目标端口', '5432');
    await sessions.retry(id);
    expect(engine.sessions, hasLength(1));
    secrets.reads = 0;
    await start(tester);
    expect(engine.sessions, hasLength(2));
    expect(engine.hosts.last.hostname, 'new-db.test');
    expect(engine.hosts.last.port, 2222);
    expect(engine.hosts.last.username, 'operator');
    expect(engine.credentials.last.password, 'new-service-test-only');
    expect(engine.gateways.last!.host.hostname, 'new-jump.test');
    expect(engine.gateways.last!.credentials.password, 'new-gateway-test-only');
    expect(secrets.reads, 2);
    expect(
      engine.sessions.last.ports!.first,
      const ForwardPort(localPort: 23306, targetPort: 5432),
    );
    expect(
      hosts.hosts.single.forwardPorts.first,
      engine.sessions.last.ports!.first,
    );
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(tester.takeException(), isNull);
  });

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
      service: Get.find<HostController>().hosts.single,
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

  testWidgets('删除服务关闭转发并移除映射，终端与文件传输生命周期独立', (tester) async {
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
    final removing = Get.find<HostController>().remove(_service.id);
    await settleCleanup(tester);
    await removing;
    expect(
      sessions.findByHost(_service.id, kind: SessionKind.portForward),
      isNull,
    );
    expect(engine.sessions.first.closed, isTrue);
    expect(sessions.sessions.single.id, transfer);
    expect(engine.sessions.last.closed, isFalse);
    expect(await Get.find<HostRepository>().getAll(), isEmpty);
    expect(await Get.find<HostController>().passwordOf(_service.id), isNull);
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

  testWidgets('已有映射在服务编辑及复制后保留，包括编辑弹窗打开后保存的映射', (tester) async {
    await pump(tester);
    final hosts = Get.find<HostController>();
    final context = tester.element(find.text(_service.name));
    final editing = showHostEditDialog(context, host: hosts.hosts.single);
    await tester.pumpAndSettle();
    const updatedPorts = [ForwardPort(localPort: 15432, targetPort: 5432)];
    await hosts.saveForwardPorts(_service.id, updatedPorts);
    await tester.pumpAndSettle();
    await field(tester, '名称', 'Renamed service');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await editing;
    expect(hosts.hosts.single.forwardPorts, updatedPorts);
    final copying = showHostEditDialog(
      tester.element(find.text('Renamed service')),
      copyFrom: hosts.hosts.single,
    );
    await tester.pumpAndSettle();
    await field(tester, '名称', 'Copied service');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await copying;
    expect(hosts.hosts, hasLength(2));
    expect(
      hosts.hosts.firstWhere((h) => h.name == 'Copied service').forwardPorts,
      updatedPorts,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('多映射可滚动，指纹确认置顶，英文小窗口操作区始终可见', (tester) async {
    final many = _service.copyWith(
      forwardPorts: [
        for (var i = 0; i < 8; i++)
          ForwardPort(localPort: 15000 + i, targetPort: 3306 + i),
      ],
    );
    await pump(tester, service: many);
    final id = await open(tester, service: many);
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
