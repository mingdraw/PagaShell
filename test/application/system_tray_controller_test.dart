import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/mcp/mcp_server_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/tray/system_tray_controller.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/mcp/mcp_server_transport.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/tray/system_tray.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';

import '../support/fake_system_tray.dart';
import '../support/in_memory_ai_settings_repository.dart';
import '../support/in_memory_settings_repository.dart';

class _StubEngine extends Fake implements SshEngine {}

class _FakeMcpHandle implements McpServerHandle {
  _FakeMcpHandle(this.port);

  @override
  final int port;

  final clients = StreamController<int>.broadcast();
  int _count = 0;

  void emitClients(int count) {
    _count = count;
    clients.add(count);
  }

  @override
  int get activeSessionCount => _count;

  @override
  Stream<int> get activeSessionCountStream => clients.stream;

  @override
  void notifyToolsListChanged() {}

  @override
  void updateToken(String token) {}

  @override
  Future<void> close() async {
    await clients.close();
  }
}

class _FakeMcpFactory implements McpServerFactory {
  bool failStart = false;
  _FakeMcpHandle? lastHandle;

  @override
  Future<McpServerHandle> start({
    required int port,
    required String token,
    required McpServerDelegate delegate,
  }) async {
    if (failStart) {
      throw const McpServerException('MCP 服务端口已被占用或无权监听，请更换端口后重试');
    }
    return lastHandle = _FakeMcpHandle(port);
  }
}

class _TrackingSessionController extends SessionController {
  _TrackingSessionController() : super(engine: _StubEngine());

  final stoppedForwards = <String>[];
  final stoppedProxies = <String>[];
  final cleanupNeeded = <String>{};

  @override
  bool proxyNeedsCleanup(String id) => cleanupNeeded.contains(id);

  @override
  Future<void> stopForward(String id) async {
    stoppedForwards.add(id);
    final idx = sessions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      sessions[idx] = sessions[idx].copyWith(phase: SessionPhase.closed);
    }
  }

  @override
  Future<void> stopProxy(String id) async {
    stoppedProxies.add(id);
    if (cleanupNeeded.contains(id)) return;
    final idx = sessions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      sessions[idx] = sessions[idx].copyWith(phase: SessionPhase.closed);
    }
  }
}

void main() {
  late FakeSystemTray tray;
  late InMemorySettingsRepository settingsRepo;
  late SettingsController settings;
  late _TrackingSessionController sessions;
  late _FakeMcpFactory mcpFactory;
  late McpServerController mcp;
  late SystemTrayController controller;
  final copied = <String>[];

  setUp(() async {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = AppTranslations.defaultLocale;
    Get.fallbackLocale = AppTranslations.defaultLocale;

    tray = FakeSystemTray();
    settingsRepo = InMemorySettingsRepository();
    settings = SettingsController(repository: settingsRepo);
    await settings.ready;
    sessions = _TrackingSessionController();

    final secretStore = InMemorySecretStore();
    final aiSettings = AiSettingsController(
      repository: InMemoryAiSettingsRepository(),
      secretStore: secretStore,
    );
    await aiSettings.ready;

    final hostRepo = InMemoryHostRepository();
    final gatewayRepo = InMemoryHostRepository();
    final hosts = HostController(
      repository: hostRepo,
      secretStore: secretStore,
      treeRepository: InMemoryHostTreeRepository(
        folders: InMemoryFolderRepository(),
        hosts: hostRepo,
      ),
      sessions: sessions,
    );
    final gateways = GatewayController(
      repository: gatewayRepo,
      secretStore: secretStore,
      treeRepository: InMemoryHostTreeRepository(
        folders: InMemoryFolderRepository(),
        hosts: gatewayRepo,
      ),
      services: hostRepo,
      sessions: sessions,
    );
    final identities = IdentityController(
      repository: InMemoryIdentityRepository(
        services: hostRepo,
        gateways: gatewayRepo,
      ),
      secretStore: secretStore,
      treeRepository: InMemoryIdentityTreeRepository(
        folders: InMemoryIdentityFolderRepository(),
        identities: InMemoryIdentityRepository(
          services: hostRepo,
          gateways: gatewayRepo,
        ),
      ),
    );
    mcpFactory = _FakeMcpFactory();
    mcp = McpServerController(
      aiSettings: aiSettings,
      sessions: sessions,
      hosts: hosts,
      gateways: gateways,
      identities: identities,
      serverFactory: mcpFactory,
      autoStart: false,
    );
    await mcp.ready;
    copied.clear();
    controller = SystemTrayController(
      tray: tray,
      settings: settings,
      sessions: sessions,
      mcp: mcp,
      copyText: (text) async {
        copied.add(text);
        return true;
      },
    );
    controller.onInit();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await controller.disposeTray();
    mcp.onClose();
    sessions.onClose();
    settings.onClose();
    Get.reset();
    Get.clearTranslations();
  });

  test('空闲态菜单包含隐藏窗口、服务状态、快捷入口、关闭最小化勾选与退出', () {
    final state = controller.buildTrayState();
    expect(state.tooltip, 'PagaShell');
    expect(state.items.first.id, SystemTrayController.actionHideWindow);
    expect(state.items.first.label, '隐藏到托盘');
    expect(state.items.any((i) => i.label == '端口转发：未运行' && !i.enabled), isTrue);
    expect(state.items.any((i) => i.label == '动态代理：未运行' && !i.enabled), isTrue);

    final mcpMenu = state.items.firstWhere((i) => i.label == '本地 MCP 服务（已停止）');
    expect(mcpMenu.kind, SystemTrayMenuItemKind.submenu);
    expect(
      mcpMenu.children.any(
        (c) =>
            c.id == SystemTrayController.actionToggleMcp &&
            c.label == '启动本地 MCP 服务',
      ),
      isTrue,
    );

    final toggle = state.items.firstWhere(
      (i) => i.id == SystemTrayController.actionToggleMinimizeToTray,
    );
    expect(toggle.kind, SystemTrayMenuItemKind.checkbox);
    expect(toggle.checked, isFalse);
    expect(state.items.last.id, SystemTrayController.actionQuit);
  });

  test('任一后台服务就绪即点亮托盘绿点，最后一项停止后熄灭', () async {
    const host = Host(id: 'host', name: 'Host', hostname: 'host.test');
    final liveSessions = sessions.sessions;
    liveSessions.addAll(const [
      Session(id: 'ssh', host: host, phase: SessionPhase.ready),
      Session(id: 'forward', host: host, kind: SessionKind.portForward),
      Session(id: 'proxy', host: host, kind: SessionKind.dynamicProxy),
    ]);

    Future<bool> badgeVisible() async {
      await Future<void>.delayed(Duration.zero);
      return tray.latestState!.hasActiveServices;
    }

    expect(await badgeVisible(), isFalse);

    liveSessions[1] = liveSessions[1].copyWith(phase: SessionPhase.ready);
    expect(await badgeVisible(), isTrue);

    liveSessions[2] = liveSessions[2].copyWith(phase: SessionPhase.ready);
    await sessions.stopForward('forward');
    expect(await badgeVisible(), isTrue);

    await sessions.stopProxy('proxy');
    expect(await badgeVisible(), isFalse);

    await mcp.setEnabled(true);
    expect(await badgeVisible(), isTrue);

    await mcp.setEnabled(false);
    expect(await badgeVisible(), isFalse);
  });

  test('后台服务运行中时汇总 Tooltip 并生成端口转发、动态代理、MCP 与会话子菜单', () async {
    sessions.sessions.addAll([
      const Session(
        id: 'fwd-1',
        host: Host(
          id: 'gw-1',
          name: '生产网关',
          hostname: 'gw.example.test',
          forwardPorts: [
            ForwardPort(localPort: 3306, targetPort: 3306),
            ForwardPort(localPort: 6379, targetPort: 6379),
            ForwardPort(localPort: 5432, targetPort: 5432),
            ForwardPort(localPort: 9200, targetPort: 9200),
          ],
        ),
        kind: SessionKind.portForward,
        phase: SessionPhase.ready,
      ),
      const Session(
        id: 'proxy-1',
        host: Host(
          id: 'gw-2',
          name: '办公网关',
          hostname: 'office.example.test',
          proxyConfig: ProxyConfig(
            httpEnabled: true,
            httpPort: 18080,
            socks5Enabled: true,
            socks5Port: 1080,
            autoSystemProxy: true,
          ),
        ),
        kind: SessionKind.dynamicProxy,
        phase: SessionPhase.ready,
      ),
      const Session(
        id: 'sftp-1',
        host: Host(id: 'h-1', name: '日志服务器', hostname: 'logs.example.test'),
        kind: SessionKind.fileTransfer,
        phase: SessionPhase.ready,
      ),
    ]);
    await mcp.setEnabled(true);
    mcpFactory.lastHandle!.emitClients(2);
    await Future<void>.delayed(Duration.zero);

    final state = controller.buildTrayState();
    expect(state.tooltip, 'PagaShell · 端口转发 1 · 动态代理 1 · MCP :47321 · 会话 1');

    final forwardMenu = state.items.firstWhere((i) => i.label == '端口转发（1 运行中）');
    expect(forwardMenu.children.first.label, '生产网关 (:3306, :6379, :5432 +1)');
    expect(forwardMenu.children.last.label, '停止此端口转发');

    final proxyMenu = state.items.firstWhere((i) => i.label == '动态代理（1 运行中）');
    expect(
      proxyMenu.children.first.label,
      '办公网关 (HTTP :18080 · SOCKS5 :1080 · 系统代理)',
    );

    final mcpMenu = state.items.firstWhere(
      (i) => i.label == '本地 MCP 服务（运行中 :47321）',
    );
    expect(mcpMenu.children.first.label, '状态：运行中 · 2 个客户端');

    final activeMenu = state.items.firstWhere((i) => i.label == '活动会话（1）');
    expect(activeMenu.children.first.label, '日志服务器 (SFTP)');
  });

  test('隐藏到托盘后切换窗口菜单项与后台模式，英文环境完整翻译', () async {
    controller.setWindowHiddenInTray(true);
    await Future<void>.delayed(Duration.zero);
    expect(tray.backgroundModes.last, isTrue);

    final zhState = controller.buildTrayState();
    expect(zhState.tooltip, 'PagaShell · 后台运行中');
    expect(zhState.items.first.id, SystemTrayController.actionShowWindow);
    expect(zhState.items.first.label, '显示 PagaShell');

    Get.locale = AppTranslations.englishLocale;
    final enState = controller.buildTrayState();
    expect(enState.tooltip, 'PagaShell · Running in background');
    expect(enState.items.first.label, 'Show PagaShell');
    expect(enState.items.any((i) => i.label == 'Port Forwards: Idle'), isTrue);
    expect(enState.items.any((i) => i.label == 'Dynamic Proxy: Idle'), isTrue);
    expect(
      enState.items.any((i) => i.label == 'Minimize to tray on close'),
      isTrue,
    );
    expect(enState.items.last.label, 'Quit PagaShell');
  });

  test('托盘菜单操作可启停 MCP、复制地址、停止转发/代理并处理系统代理恢复失败', () async {
    final focused = <String>[];
    final errors = <String>[];
    final successes = <String>[];
    var shown = 0;
    controller.onFocusSession = (id) async => focused.add(id);
    controller.onShowWindow = () async => shown++;
    controller.onNoticeError = errors.add;
    controller.onNoticeSuccess = successes.add;

    await controller.handleMenuAction(SystemTrayController.actionToggleMcp);
    expect(mcp.running.value, isTrue);
    expect(successes, contains('本地 MCP 服务已启动'));

    await controller.handleMenuAction(
      SystemTrayController.actionCopyMcpEndpoint,
    );
    expect(copied, [mcp.endpointUrl]);

    await controller.handleMenuAction(SystemTrayController.actionToggleMcp);
    expect(mcp.running.value, isFalse);

    mcpFactory.failStart = true;
    await controller.handleMenuAction(SystemTrayController.actionToggleMcp);
    expect(shown, 1);
    expect(errors.last, contains('MCP 服务端口已被占用'));

    sessions.sessions.addAll([
      const Session(
        id: 'f1',
        host: Host(id: 'g1', name: 'GW1', hostname: 'g1.test'),
        kind: SessionKind.portForward,
        phase: SessionPhase.ready,
      ),
      const Session(
        id: 'p1',
        host: Host(id: 'g2', name: 'GW2', hostname: 'g2.test'),
        kind: SessionKind.dynamicProxy,
        phase: SessionPhase.ready,
      ),
    ]);
    await controller.handleMenuAction(
      SystemTrayController.actionStopAllForwards,
    );
    expect(sessions.stoppedForwards, ['f1']);

    sessions.cleanupNeeded.add('p1');
    await controller.handleMenuAction(
      SystemTrayController.actionStopAllProxies,
    );
    expect(sessions.stoppedProxies, ['p1']);
    expect(focused, ['p1']);
    expect(errors.last, '恢复系统代理失败，请重试停止代理');

    await controller.handleMenuAction(
      SystemTrayController.actionToggleMinimizeToTray,
    );
    expect(settings.minimizeToTrayOnClose.value, isTrue);
    expect(settingsRepo.minimizeToTrayOnClose, isTrue);
  });
}
