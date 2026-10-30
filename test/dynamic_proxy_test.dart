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
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/proxy/dynamic_proxy_engine.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/proxy/desktop_system_proxy.dart';
import 'package:pagashell/infrastructure/proxy/system_proxy_backend.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/proxy/clash_extension_dialog.dart';
import 'package:pagashell/presentation/proxy/dynamic_proxy_panel.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';

class _Secrets extends InMemorySecretStore {
  int reads = 0;
  @override
  Future<String?> read(String ref) {
    reads++;
    return super.read(ref);
  }
}

class _Proxy implements DynamicProxySession {
  final ended = Completer<void>();
  Completer<void>? closeGate;
  bool closed = false;
  bool reportDoneOnClose = true;
  Future<void>? _closing;
  @override
  Future<void> get done => ended.future;
  @override
  Future<void> close() => _closing ??= () async {
    await closeGate?.future;
    closed = true;
    if (reportDoneOnClose && !ended.isCompleted) ended.complete();
  }();
}

class _Engine implements SshEngine, DynamicProxyEngine {
  final proxies = <_Proxy>[];
  final gateways = <SshGateway?>[];
  final configs = <ProxyConfig>[];
  Completer<void>? startGate;
  bool cancelled = false;
  SshEngineException? failure;

  @override
  Future<DynamicProxySession> startProxy(
    ProxyConfig config, {
    SshGateway? gateway,
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  }) async {
    configs.add(config);
    gateways.add(gateway);
    unawaited(cancelled?.then((_) => this.cancelled = true));
    final proxy = _Proxy();
    proxies.add(proxy);
    await startGate?.future;
    if (failure != null) throw failure!;
    return proxy;
  }

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => throw StateError('Dynamic proxies must not open a target SSH session');
}

const _gateway = Host(
  id: 'proxy-gateway',
  name: 'Proxy gateway',
  hostname: 'jump.test',
);

class _SystemBackend implements SystemProxyBackend {
  final events = <String>[];
  Completer<void>? enableGate;
  Completer<void>? restoreGate;
  bool enableFails = false, restoreFails = false;
  String? owner;
  void Function()? onEnable;
  @override
  Future<void> enable(String owner, ProxyConfig config) async {
    events.add('enable');
    onEnable?.call();
    await enableGate?.future;
    this.owner = owner;
    if (enableFails) {
      throw const SystemProxyException('自动设置系统代理失败，请检查系统设置或取消自动设置');
    }
  }

  @override
  Future<void> restore(String owner) async {
    events.add('restore');
    await restoreGate?.future;
    if (restoreFails) throw StateError('restore failure');
    if (this.owner == owner) this.owner = null;
  }
}

void main() {
  setUpAll(() async {
    if (Platform.environment['PAGASHELL_PROXY_CAPTURE_DIR'] == null) return;
    for (final f in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
      'FiraCode Nerd Font Mono':
          'assets/fonts/FiraCodeNerdFontMono-Regular.ttf',
    }.entries) {
      await (FontLoader(f.key)..addFont(rootBundle.load(f.value))).load();
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

  Future<(_Engine, _Secrets, SessionController)> pump(
    WidgetTester tester, {
    Host host = _gateway,
    SystemProxy? systemProxy,
  }) async {
    tester.view.physicalSize = const Size(1360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = _Engine();
    final secrets = _Secrets();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('proxy-capture'),
        child: PagaShellApp(
          binding: InMemoryBinding(
            sshEngine: engine,
            secretStore: secrets,
            systemProxy: systemProxy,
          ),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await Get.find<GatewayController>().save(host);
    await Get.find<GatewayController>().savePassword(
      host.id,
      'test-token-only',
    );
    await tester.pumpAndSettle();
    secrets.reads = 0;
    return (engine, secrets, Get.find<SessionController>());
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['PAGASHELL_PROXY_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('proxy-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('网关右键打开独立动态代理标签，重复打开复用且不读取凭据', (tester) async {
    final (engine, secrets, sessions) = await pump(tester);
    await tester.tap(find.text(_gateway.name), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(shadcn.MenuButton, '动态代理'), findsOneWidget);
    await tester.tap(find.text('动态代理'));
    await tester.pumpAndSettle();
    expect(sessions.sessions.single.kind, SessionKind.dynamicProxy);
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(sessions.openProxy(_gateway), sessions.sessions.single.id);
    sessions.openForward(_gateway);
    expect(sessions.sessions, hasLength(2));
    sessions.openProxy(_gateway);
    await tester.pumpAndSettle();
    expect(find.byType(DynamicProxyPanel), findsOneWidget);
    expect(find.byType(shadcn.RadioCard<ProxyMode>), findsNWidgets(2));
    expect(find.text('直连'), findsNothing);
    expect(engine.proxies, isEmpty);
    expect(secrets.reads, 0);
    await capture(tester, 'proxy-global');
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('Page 代理未启用直接关，运行时原生关闭命令与关闭按钮都先确认', (tester) async {
    final host = _gateway.copyWith(
      gatewayType: GatewayType.page,
      pageClientId: 'inside',
    );
    final (engine, _, sessions) = await pump(tester, host: host);
    var id = sessions.openProxy(host);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('session-tab-close-$id')));
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
    expect(Get.isDialogOpen, isFalse);

    id = sessions.openProxy(host);
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    const codec = StandardMethodCodec();
    final command = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'pagashell/window',
      codec.encodeMethodCall(const MethodCall('closeActiveTab')),
      null,
    );
    await tester.pumpAndSettle();
    expect(codec.decodeEnvelope((await command)!), isNull);
    expect(find.text('${host.name}（动态代理）'), findsOneWidget);
    expect(engine.proxies.single.closed, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(engine.proxies.single.closed, isFalse);

    await tester.tap(find.byKey(ValueKey('session-tab-close-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-stop-and-close')));
    await tester.pumpAndSettle();
    expect(engine.proxies.single.closed, isTrue);
    expect(sessions.sessions, isEmpty);
    expect(Get.isDialogOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则模式使用网关凭据，运行时禁止切换模式，停止后可重新启动', (tester) async {
    final host = _gateway.copyWith(
      proxyConfig: const ProxyConfig(mode: ProxyMode.rule),
    );
    final (engine, secrets, sessions) = await pump(tester, host: host);
    sessions.openProxy(host);
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(engine.gateways.single!.host.id, host.id);
    expect(secrets.reads, 1);
    expect(
      tester
          .widget<shadcn.RadioGroup<ProxyMode>>(
            find.byType(shadcn.RadioGroup<ProxyMode>),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('proxy-mode-global')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<shadcn.RadioGroup<ProxyMode>>(
            find.byType(shadcn.RadioGroup<ProxyMode>),
          )
          .value,
      ProxyMode.rule,
    );
    expect(
      tester
          .widget<AppTextFormField>(
            find.byKey(const ValueKey('proxy-HTTP(S)-port')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('停止代理'));
    await tester.pumpAndSettle();
    expect(engine.proxies.single.closed, isTrue);
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    expect(engine.proxies, hasLength(2));
    expect(secrets.reads, 2);
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(engine.proxies.every((p) => p.closed), isTrue);
  });

  testWidgets('Page 使用已保存的最新端点、协议端口和令牌；删除网关清理代理', (tester) async {
    final host = _gateway.copyWith(
      gatewayType: GatewayType.page,
      pageClientId: 'inside',
    );
    final (engine, secrets, sessions) = await pump(tester, host: host);
    sessions.openProxy(host);
    await tester.pumpAndSettle();
    final controller = Get.find<GatewayController>();
    await controller.save(
      host.copyWith(hostname: 'new-relay.test', pageClientId: 'new-client'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('proxy-HTTP(S)-port')),
      '28080',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    expect(engine.gateways.single!.host.hostname, 'new-relay.test');
    expect(engine.gateways.single!.host.pageClientId, 'new-client');
    expect(engine.gateways.single!.credentials.password, 'test-token-only');
    expect(engine.configs.single.httpPort, 28080);
    expect(engine.configs.single.httpsPort, 28080);
    expect(engine.configs.single.httpEnabled, isTrue);
    expect(engine.configs.single.httpsEnabled, isTrue);
    expect(secrets.reads, 1);
    await controller.remove(host.id);
    await tester.pumpAndSettle();
    expect(engine.proxies.single.closed, isTrue);
    expect(sessions.sessions, isEmpty);
  });

  testWidgets('HTTP(S) 只有一组开关和端口，同时保存 HTTP 与 HTTPS', (tester) async {
    final (_, _, sessions) = await pump(tester);
    sessions.openProxy(_gateway);
    await tester.pumpAndSettle();
    final checkbox = find.widgetWithText(shadcn.Checkbox, 'HTTP(S)');
    expect(checkbox, findsOneWidget);
    expect(find.widgetWithText(shadcn.Checkbox, 'HTTP'), findsNothing);
    expect(find.widgetWithText(shadcn.Checkbox, 'HTTPS'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(DynamicProxyPanel),
        matching: find.byType(AppTextFormField),
      ),
      findsNWidgets(2),
    );
    final port = find.byKey(const ValueKey('proxy-HTTP(S)-port'));
    await tester.enterText(port, '28080');
    await tester.tap(checkbox);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final controller = Get.find<GatewayController>();
    var config = (await controller.findSaved(_gateway.id))!.proxyConfig;
    expect(config.httpEnabled, isFalse);
    expect(config.httpsEnabled, isFalse);
    expect(config.httpPort, 28080);
    expect(config.httpsPort, 28080);
    expect(tester.widget<AppTextFormField>(port).enabled, isFalse);
    await tester.tap(checkbox);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    config = (await controller.findSaved(_gateway.id))!.proxyConfig;
    expect(config.httpEnabled, isTrue);
    expect(config.httpsEnabled, isTrue);
    expect(config.socks5Enabled, isFalse);
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  for (final (http, https, expectedPort) in [
    (true, false, 28080),
    (false, true, 28443),
    (true, true, 28080),
  ]) {
    testWidgets('兼容旧配置 HTTP=$http HTTPS=$https，统一使用端口 $expectedPort', (
      tester,
    ) async {
      final host = _gateway.copyWith(
        proxyConfig: ProxyConfig.fromJson({
          'mode': 'direct',
          'httpEnabled': http,
          'httpPort': 28080,
          'httpsEnabled': https,
          'httpsPort': 28443,
        }),
      );
      final (engine, _, sessions) = await pump(tester, host: host);
      sessions.openProxy(host);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppTextFormField>(
              find.byKey(const ValueKey('proxy-HTTP(S)-port')),
            )
            .controller
            .text,
        '$expectedPort',
      );
      await tester.tap(find.text('启动代理'));
      await tester.pumpAndSettle();
      final config = engine.configs.single;
      expect(config.mode, ProxyMode.rule);
      expect(config.httpEnabled, isTrue);
      expect(config.httpsEnabled, isTrue);
      expect(config.httpPort, expectedPort);
      expect(config.httpsPort, expectedPort);
      await sessions.closeAll();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('代理规则自动保存；无效输入不覆盖；关闭有效草稿立即保存', (tester) async {
    final host = _gateway.copyWith(
      proxyConfig: const ProxyConfig(mode: ProxyMode.rule),
    );
    final (_, _, sessions) = await pump(tester, host: host);
    var id = sessions.openProxy(host);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加规则'));
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    final value = find.byKey(const ValueKey('proxy-rule-value'));
    await tester.ensureVisible(value);
    await tester.enterText(value, 'internal.test');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final controller = Get.find<GatewayController>();
    expect(
      (await controller.findSaved(host.id))!.proxyConfig.rules.single.value,
      'internal.test',
    );
    await tester.enterText(value, 'https://invalid.test');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      (await controller.findSaved(host.id))!.proxyConfig.rules.single.value,
      'internal.test',
    );
    await tester.enterText(value, 'new.internal.test');
    await sessions.close(id);
    await tester.pumpAndSettle();
    final saved = (await controller.findSaved(host.id))!;
    expect(saved.proxyConfig.rules.single.value, 'new.internal.test');
    id = sessions.openProxy(saved);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppTextFormField>(value).controller.text,
      'new.internal.test',
    );
    await sessions.close(id);
    await tester.pumpAndSettle();
  });

  testWidgets('规则面板宽窄屏、英文及 Radio Card 模式选择可用', (tester) async {
    final host = _gateway.copyWith(
      proxyConfig: const ProxyConfig(
        mode: ProxyMode.rule,
        socks5Enabled: true,
        rules: [
          ProxyRule(
            type: ProxyRuleType.domainSuffix,
            value: 'internal.example.com',
          ),
          ProxyRule(type: ProxyRuleType.ip, value: '10.0.0.0/16'),
          ProxyRule(type: ProxyRuleType.ip, value: '2001:db8::/32'),
        ],
      ),
    );
    final (_, _, sessions) = await pump(tester, host: host);
    sessions.openProxy(host);
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-rules-wide');
    tester.view.physicalSize = const Size(800, 800);
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-rules-narrow');
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      unawaited(Get.updateLocale(AppTranslations.englishLocale));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-rules-english');
    expect(find.text('Direct'), findsNothing);
    final global = find.byKey(const ValueKey('proxy-mode-global'));
    await tester.ensureVisible(global);
    await tester.tap(global);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      (await Get.find<GatewayController>().findSaved(host.id))!
          .proxyConfig
          .mode,
      ProxyMode.global,
    );
    expect(find.byKey(const ValueKey('proxy-rule-value')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('proxy-mode-rule')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      (await Get.find<GatewayController>().findSaved(host.id))!
          .proxyConfig
          .mode,
      ProxyMode.rule,
    );
    expect(find.byKey(const ValueKey('proxy-rule-value')), findsNWidgets(3));
    tester.view.physicalSize = const Size(1360, 1000);
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-rules-english-wide');
    expect(tester.takeException(), isNull);
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  test('关闭启动中的代理等待迟到句柄清理后才允许同网关重新启动', () async {
    final engine = _Engine()..startGate = Completer<void>();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final gateway = SshGateway(
      host: _gateway,
      credentials: const SshCredentials.password('test-only'),
    );
    final starting = sessions.startProxy(id, _gateway, gateway: gateway);
    await Future<void>.delayed(Duration.zero);
    final closing = sessions.close(id);
    final nextId = sessions.openProxy(_gateway);
    final next = sessions.startProxy(nextId, _gateway, gateway: gateway);
    await Future<void>.delayed(Duration.zero);
    expect(engine.proxies, hasLength(1));
    expect(engine.cancelled, isTrue);
    engine.startGate!.complete();
    await Future.wait([starting, closing, next]);
    expect(engine.proxies.first.closed, isTrue);
    expect(engine.proxies, hasLength(2));
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('启动中的代理关闭请求只确认一次，确认前不取消，确认后释放迟到句柄', () async {
    final engine = _Engine()..startGate = Completer<void>();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final starting = sessions.startProxy(
      id,
      _gateway,
      gateway: SshGateway(
        host: _gateway,
        credentials: const SshCredentials.password('test-only'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final decision = Completer<bool>();
    var confirmations = 0;
    Future<bool> confirm(List<Session> running) {
      confirmations++;
      expect(running.single.phase, SessionPhase.connecting);
      return decision.future;
    }

    final closing = sessions.requestTabClose([id], confirm: confirm);
    final repeated = sessions.requestTabClose([id], confirm: confirm);
    expect(identical(closing, repeated), isTrue);
    expect(confirmations, 1);
    expect(engine.cancelled, isFalse);
    expect(engine.proxies.single.closed, isFalse);
    decision.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(engine.cancelled, isTrue);
    engine.startGate!.complete();
    await Future.wait([starting, closing, repeated]);
    expect(engine.proxies.single.closed, isTrue);
    expect(sessions.sessions, isEmpty);
    sessions.onClose();
  });

  test('停止正在启动的代理，取消后保留关闭状态且释放迟到句柄', () async {
    final engine = _Engine()..startGate = Completer<void>();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final starting = sessions.startProxy(
      id,
      _gateway,
      gateway: SshGateway(
        host: _gateway,
        credentials: const SshCredentials.password('test-only'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final stopped = sessions.stopProxy(id);
    expect(sessions.sessions.single.phase, SessionPhase.stopping);
    engine.startGate!.complete();
    await Future.wait([starting, stopped]);
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(engine.proxies.single.closed, isTrue);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('重启后旧监听迟到的结束事件不能关闭新代理', () async {
    final engine = _Engine();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final gateway = SshGateway(
      host: _gateway,
      credentials: const SshCredentials.password('test-only'),
    );
    await sessions.startProxy(id, _gateway, gateway: gateway);
    final old = engine.proxies.single..reportDoneOnClose = false;
    await sessions.stopProxy(id);
    await sessions.startProxy(id, _gateway, gateway: gateway);
    old.ended.completeError(const SshEngineException('old listener ended'));
    await Future<void>.delayed(Duration.zero);
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    expect(engine.proxies.last.closed, isFalse);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('等待旧代理清理时停止重启，不得在清理完成后又启动监听', () async {
    final engine = _Engine();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final gateway = SshGateway(
      host: _gateway,
      credentials: const SshCredentials.password('test-only'),
    );
    await sessions.startProxy(id, _gateway, gateway: gateway);
    final first = engine.proxies.single..closeGate = Completer<void>();
    first.ended.completeError(const SshEngineException('listener failed'));
    await Future<void>.delayed(Duration.zero);
    final restarting = sessions.startProxy(id, _gateway, gateway: gateway);
    final stopping = sessions.stopProxy(id);
    first.closeGate!.complete();
    await Future.wait([restarting, stopping]);
    expect(engine.proxies, hasLength(1));
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('监听意外结束标记失败，重启等待旧连接关闭', () async {
    final engine = _Engine();
    final sessions = SessionController(engine: engine);
    final id = sessions.openProxy(_gateway);
    final gateway = SshGateway(
      host: _gateway,
      credentials: const SshCredentials.password('test-only'),
    );
    await sessions.startProxy(id, _gateway, gateway: gateway);
    final first = engine.proxies.single..closeGate = Completer<void>();
    first.ended.completeError(const SshEngineException('listener failed'));
    await Future<void>.delayed(Duration.zero);
    expect(sessions.sessions.single.phase, SessionPhase.failed);
    final restarting = sessions.startProxy(id, _gateway, gateway: gateway);
    await Future<void>.delayed(Duration.zero);
    expect(engine.proxies, hasLength(1));
    first.closeGate!.complete();
    await restarting;
    expect(engine.proxies, hasLength(2));
    expect(sessions.sessions.single.phase, SessionPhase.ready);
    await sessions.closeAll();
    sessions.onClose();
  });

  testWidgets('Clash 脚本使用当前草稿，可复制且宽窄屏、中英文可用', (tester) async {
    final host = _gateway.copyWith(
      proxyConfig: const ProxyConfig(
        mode: ProxyMode.rule,
        rules: [
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'corp.internal'),
          ProxyRule(type: ProxyRuleType.ip, value: '10.20.0.0/16'),
        ],
      ),
    );
    final (engine, secrets, sessions) = await pump(tester, host: host);
    sessions.openProxy(host);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proxy-HTTP(S)-port')),
      '28080',
    );
    await tester.tap(find.byKey(const ValueKey('proxy-clash-script')));
    await tester.pumpAndSettle();
    final dialog = tester.widget<ClashExtensionDialog>(
      find.byType(ClashExtensionDialog),
    );
    expect(dialog.script.node['port'], 28080);
    expect(dialog.script.mode, ProxyMode.rule);
    expect(
      dialog.script.rules.first,
      startsWith('DOMAIN-SUFFIX,corp.internal,'),
    );
    expect(
      find.text('规则模式：命中已配置规则的请求通过 PagaShell 网关，其余流量沿用 Clash 原有分流。'),
      findsOneWidget,
    );
    expect(
      find.text('由 Clash 开启系统代理并使用规则模式；PagaShell 关闭自动设置系统网络代理，使用全局模式后启动。'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('clash-extension-code')), findsOneWidget);
    expect(secrets.reads, 0);
    expect(engine.proxies, isEmpty);
    await capture(tester, 'proxy-clash-script-wide');

    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map<dynamic, dynamic>)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byKey(const ValueKey('clash-extension-copy')));
    await tester.pumpAndSettle();
    expect(clipboard, dialog.script.source);
    expect(find.text('已复制'), findsOneWidget);

    tester.view.physicalSize = const Size(800, 680);
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-clash-script-narrow');
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      unawaited(Get.updateLocale(AppTranslations.englishLocale));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    await capture(tester, 'proxy-clash-script-english');
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ClashExtensionDialog), findsNothing);
    final global = find.byKey(const ValueKey('proxy-mode-global'));
    await tester.ensureVisible(global);
    await tester.tap(global);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('proxy-clash-script')));
    await tester.pumpAndSettle();
    final globalDialog = tester.widget<ClashExtensionDialog>(
      find.byType(ClashExtensionDialog),
    );
    expect(globalDialog.script.mode, ProxyMode.global);
    expect(globalDialog.script.rules, [
      'MATCH,${globalDialog.script.node['name']}',
    ]);
    expect(globalDialog.script.source, isNot(contains('corp.internal')));
    expect(
      find.text(
        'Global mode: Traffic not matched by existing Clash rules uses the PagaShell gateway.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('clash-extension-copy')));
    await tester.pumpAndSettle();
    expect(clipboard, globalDialog.script.source);
    await capture(tester, 'proxy-clash-script-global-english');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('没有启用协议时在面板提示，不展示无效 Clash 脚本', (tester) async {
    final (_, _, sessions) = await pump(tester);
    sessions.openProxy(_gateway);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.Checkbox, 'HTTP(S)'));
    await tester.tap(find.byKey(const ValueKey('proxy-clash-script')));
    await tester.pumpAndSettle();
    expect(find.byType(ClashExtensionDialog), findsNothing);
    expect(find.text('请至少启用一种代理协议'), findsOneWidget);
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('自动系统代理默认关闭，勾选自动保存且运行时不可修改', (tester) async {
    final backend = _SystemBackend();
    final (engine, _, sessions) = await pump(
      tester,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    sessions.openProxy(_gateway);
    await tester.pumpAndSettle();
    final checkbox = find.byKey(const ValueKey('proxy-auto-system'));
    final clashScript = find.byKey(const ValueKey('proxy-clash-script'));
    expect(clashScript, findsOneWidget);
    expect(
      tester.widget<shadcn.Checkbox>(checkbox).state,
      shadcn.CheckboxState.unchecked,
    );
    await tester.tap(checkbox);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(clashScript, findsNothing);
    expect(
      (await Get.find<GatewayController>().findSaved(_gateway.id))!
          .proxyConfig
          .autoSystemProxy,
      isTrue,
    );
    await tester.tap(find.text('启动代理'));
    await tester.pumpAndSettle();
    expect(engine.configs.single.autoSystemProxy, isTrue);
    expect(tester.widget<shadcn.Checkbox>(checkbox).onChanged, isNull);
    await tester.tap(find.text('停止代理'));
    await tester.pumpAndSettle();
    expect(backend.events, ['enable', 'restore']);
    expect(tester.widget<shadcn.Checkbox>(checkbox).onChanged, isNotNull);
    await tester.tap(checkbox);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(clashScript, findsOneWidget);
    await sessions.closeAll();
    await tester.pumpAndSettle();
  });

  final autoHost = _gateway.copyWith(
    proxyConfig: const ProxyConfig(autoSystemProxy: true),
  );
  SshGateway route(Host host) => SshGateway(
    host: host,
    credentials: const SshCredentials.password('test-only'),
  );

  for (final action in ['stop', 'close', 'delete', 'exit']) {
    test('系统代理在监听成功后设置，$action 等待恢复后释放监听', () async {
      final engine = _Engine();
      final backend = _SystemBackend()
        ..onEnable = () => expect(engine.proxies.single.closed, isFalse);
      final sessions = SessionController(
        engine: engine,
        systemProxy: DesktopSystemProxy(backend: backend),
      );
      final id = sessions.openProxy(autoHost);
      await sessions.startProxy(id, autoHost, gateway: route(autoHost));
      expect(sessions.sessions.single.phase, SessionPhase.ready);
      expect(backend.owner, isNotNull);
      switch (action) {
        case 'stop':
          await sessions.stopProxy(id);
        case 'close':
          await sessions.close(id);
        case 'delete':
          await sessions.closeProxyForHost(autoHost.id);
        case 'exit':
          await sessions.closeAll();
      }
      expect(backend.events, ['enable', 'restore']);
      expect(backend.owner, isNull);
      expect(engine.proxies.single.closed, isTrue);
      await sessions.closeAll();
      sessions.onClose();
    });
  }

  test('监听启动失败不设置系统代理，设置失败回滚并关闭已启动监听', () async {
    final engine = _Engine()..failure = const SshEngineException('bind failed');
    final backend = _SystemBackend();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    expect(backend.events, isEmpty);
    engine.failure = null;
    backend.enableFails = true;
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    expect(backend.events, ['enable', 'restore']);
    expect(sessions.sessions.single.phase, SessionPhase.failed);
    expect(engine.proxies.last.closed, isTrue);
    expect(backend.owner, isNull);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('设置系统代理中停止，等待迟到设置恢复后再关闭监听', () async {
    final engine = _Engine();
    final backend = _SystemBackend()..enableGate = Completer<void>();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    final starting = sessions.startProxy(
      id,
      autoHost,
      gateway: route(autoHost),
    );
    await Future<void>.delayed(Duration.zero);
    final stopping = sessions.stopProxy(id);
    expect(engine.proxies.single.closed, isFalse);
    backend.enableGate!.complete();
    await Future.wait([starting, stopping]);
    expect(sessions.sessions.single.phase, SessionPhase.closed);
    expect(backend.events, ['enable', 'restore']);
    expect(backend.owner, isNull);
    expect(engine.proxies.single.closed, isTrue);
    await sessions.closeAll();
    sessions.onClose();
  });

  test('系统代理恢复失败保留监听和标签、阻止退出，重试可恢复', () async {
    final engine = _Engine();
    final backend = _SystemBackend();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    backend.restoreFails = true;
    await sessions.close(id);
    expect(sessions.sessions.single.id, id);
    expect(sessions.proxyNeedsCleanup(id), isTrue);
    expect(engine.proxies.single.closed, isFalse);
    await expectLater(
      sessions.closeAll(),
      throwsA(isA<SystemProxyException>()),
    );
    backend.restoreFails = false;
    await sessions.stopProxy(id);
    expect(sessions.proxyNeedsCleanup(id), isFalse);
    expect(engine.proxies.single.closed, isTrue);
    await sessions.closeAll();
    sessions.onClose();
  });

  testWidgets('确认关闭代理等待系统代理恢复，恢复失败保留监听和标签供重试', (tester) async {
    final backend = _SystemBackend()..restoreFails = true;
    final (engine, _, sessions) = await pump(
      tester,
      host: autoHost,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    await tester.pumpAndSettle();

    Future<void> confirmClose() async {
      await tester.tap(find.byKey(ValueKey('session-tab-close-$id')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session-close-confirmation')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('session-stop-and-close')));
      await tester.pumpAndSettle();
    }

    await confirmClose();
    expect(sessions.sessions.single.id, id);
    expect(sessions.proxyNeedsCleanup(id), isTrue);
    expect(engine.proxies.single.closed, isFalse);
    expect(backend.owner, isNotNull);
    backend.restoreFails = false;
    backend.restoreGate = Completer<void>();
    await confirmClose();
    expect(sessions.sessions.single.id, id);
    expect(engine.proxies.single.closed, isFalse);
    backend.restoreGate!.complete();
    await tester.pumpAndSettle();
    expect(sessions.sessions, isEmpty);
    expect(engine.proxies.single.closed, isTrue);
    expect(backend.owner, isNull);
    expect(tester.takeException(), isNull);
  });

  test('多个网关不能覆盖系统代理所有权，第二个启动回滚监听', () async {
    final engine = _Engine();
    final backend = _SystemBackend();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final first = sessions.openProxy(autoHost);
    await sessions.startProxy(first, autoHost, gateway: route(autoHost));
    final secondHost = Host(
      id: 'second-proxy',
      name: 'Second',
      hostname: 'second.test',
      proxyConfig: autoHost.proxyConfig,
    );
    final second = sessions.openProxy(secondHost);
    await sessions.startProxy(second, secondHost, gateway: route(secondHost));
    expect(backend.events, ['enable']);
    expect(engine.proxies.first.closed, isFalse);
    expect(engine.proxies.last.closed, isTrue);
    expect(sessions.sessions.last.phase, SessionPhase.failed);
    await sessions.closeAll();
    expect(backend.events, ['enable', 'restore']);
    sessions.onClose();
  });

  test('监听意外中断也恢复系统代理', () async {
    final engine = _Engine();
    final backend = _SystemBackend();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    engine.proxies.single.ended.completeError(
      const SshEngineException('listener failed'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.owner, isNull);
    expect(sessions.sessions.single.phase, SessionPhase.failed);
    await sessions.closeAll();
    sessions.onClose();
  });

  testWidgets('正常退出请求等待系统代理恢复再关闭监听', (tester) async {
    final backend = _SystemBackend()..restoreGate = Completer<void>();
    final (engine, _, sessions) = await pump(
      tester,
      host: autoHost,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    await tester.pumpAndSettle();
    var exited = false;
    final exit = tester.binding.handleRequestAppExit();
    unawaited(exit.then((_) => exited = true));
    await tester.pump();
    expect(backend.events, ['enable', 'restore']);
    expect(exited, isFalse);
    expect(engine.proxies.single.closed, isFalse);
    backend.restoreGate!.complete();
    await tester.pumpAndSettle();
    expect(await exit, ui.AppExitResponse.exit);
    expect(engine.proxies.single.closed, isTrue);
    expect(backend.owner, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('删除网关前恢复系统代理，失败保留网关和凭据供重试', (tester) async {
    final backend = _SystemBackend();
    final (engine, _, sessions) = await pump(
      tester,
      host: autoHost,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final gateways = Get.find<GatewayController>();
    final id = sessions.openProxy(autoHost);
    await sessions.startProxy(id, autoHost, gateway: route(autoHost));
    backend.restoreFails = true;
    await expectLater(
      gateways.remove(autoHost.id),
      throwsA(isA<SystemProxyException>()),
    );
    expect(await gateways.findSaved(autoHost.id), isNotNull);
    expect(await gateways.passwordOf(autoHost.id), 'test-token-only');
    expect(engine.proxies.single.closed, isFalse);
    backend.restoreFails = false;
    await gateways.remove(autoHost.id);
    expect(await gateways.findSaved(autoHost.id), isNull);
    expect(engine.proxies.single.closed, isTrue);
    await tester.pumpAndSettle();
  });

  test('等待系统授权时监听中断，迟到的设置会恢复且不会转为就绪', () async {
    final engine = _Engine();
    final backend = _SystemBackend()..enableGate = Completer<void>();
    final sessions = SessionController(
      engine: engine,
      systemProxy: DesktopSystemProxy(backend: backend),
    );
    final id = sessions.openProxy(autoHost);
    final starting = sessions.startProxy(
      id,
      autoHost,
      gateway: route(autoHost),
    );
    await Future<void>.delayed(Duration.zero);
    engine.proxies.single.ended.completeError(
      const SshEngineException('listener failed'),
    );
    await Future<void>.delayed(Duration.zero);
    backend.enableGate!.complete();
    await starting;
    await Future<void>.delayed(Duration.zero);
    expect(sessions.sessions.single.phase, SessionPhase.failed);
    expect(backend.owner, isNull);
    expect(engine.proxies.single.closed, isTrue);
    await sessions.closeAll();
    sessions.onClose();
  });
}
