import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/mcp/mcp_server_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/tray/system_tray_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_app_window.dart';
import 'support/fake_system_tray.dart';
import 'support/fixture_terminal.dart';
import 'support/in_memory_agent_conversation_repository.dart';
import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

class _StubEngine extends Fake implements SshEngine {}

class _FailingExitAgent extends AgentController {
  _FailingExitAgent()
    : super(
        connect: Get.find<GetConnect>(tag: 'ai'),
        settings: Get.find<AiSettingsController>(),
        secretStore: Get.find<SecretStore>(),
        sessions: Get.find<SessionController>(),
        conversations: InMemoryAgentConversationRepository(),
      );

  @override
  Future<bool> prepareForExit() async => false;
}

class _ProxyRestoreFailSessions extends SessionController {
  _ProxyRestoreFailSessions() : super(engine: _StubEngine());

  @override
  Future<void> closeAll() async {
    throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
  }
}

class _TrayTestBinding extends InMemoryBinding {
  _TrayTestBinding({
    super.settingsRepository,
    super.appWindow,
    super.systemTray,
    this.failingAgent = false,
    this.sessions,
  });

  final bool failingAgent;
  final SessionController? sessions;

  @override
  void dependencies() {
    super.dependencies();
    if (sessions != null) Get.replace<SessionController>(sessions!);
    if (failingAgent) {
      Get.replace<AgentController>(_FailingExitAgent());
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('pagashell/window');
  final nativeWindowCalls = <String>[];
  late FakeAppWindow appWindow;
  late FakeSystemTray systemTray;

  setUp(() {
    Get.locale = AppTranslations.defaultLocale;
    appWindow = FakeAppWindow();
    systemTray = FakeSystemTray();
    nativeWindowCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          nativeWindowCalls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    InMemorySettingsRepository? settingsRepository,
    bool failingAgent = false,
    SessionController? sessions,
    TargetPlatform? platform,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(
        binding: _TrayTestBinding(
          settingsRepository: settingsRepository,
          appWindow: appWindow,
          systemTray: systemTray,
          failingAgent: failingAgent,
          sessions: sessions,
        ),
        platform: platform ?? defaultTargetPlatform,
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
    nativeWindowCalls.clear();
    appWindow.calls.clear();
  }

  testWidgets('通用设置包含关闭时最小化到托盘开关，默认关闭且支持持久化并同步托盘菜单', (tester) async {
    final repo = InMemorySettingsRepository();
    await pumpShell(tester, settingsRepository: repo);

    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();

    final toggleFinder = find.byKey(
      const ValueKey('minimize-to-tray-on-close'),
    );
    expect(toggleFinder.hitTestable(), findsOneWidget);
    expect(find.text('关闭时最小化到托盘'), findsOneWidget);
    expect(tester.widget<shadcn.Switch>(toggleFinder).value, isFalse);

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<shadcn.Switch>(toggleFinder).value, isTrue);
    expect(repo.minimizeToTrayOnClose, isTrue);
    expect(Get.find<SettingsController>().minimizeToTrayOnClose.value, isTrue);

    final menuItem = systemTray.latestState!.items.firstWhere(
      (i) => i.id == SystemTrayController.actionToggleMinimizeToTray,
    );
    expect(menuItem.checked, isTrue);
  });

  testWidgets('开启关闭最小化到托盘后，关闭窗口隐藏到托盘且保留会话与 MCP，可通过托盘恢复或真正退出', (tester) async {
    final repo = InMemorySettingsRepository(minimizeToTrayOnClose: true);
    await pumpShell(tester, settingsRepository: repo);

    final sessions = Get.find<SessionController>();
    final mcp = Get.find<McpServerController>();
    await mcp.setEnabled(true);
    sessions.sessions.add(
      Session(
        id: 'fwd-bg',
        host: const Host(id: 'gw-bg', name: '后台网关', hostname: 'gw.test'),
        kind: SessionKind.portForward,
        phase: SessionPhase.ready,
        terminal: Terminal(),
      ),
    );
    await tester.pumpAndSettle();

    appWindow.requestClose();
    await tester.pumpAndSettle();

    expect(appWindow.visible, isFalse);
    expect(appWindow.calls, contains('hide'));
    expect(appWindow.calls, isNot(contains('destroy')));
    expect(nativeWindowCalls, isNot(contains('destroy')));
    expect(sessions.sessions, hasLength(1));
    expect(mcp.running.value, isTrue);
    expect(systemTray.backgroundModes.last, isTrue);
    expect(
      systemTray.latestState!.items.first.id,
      SystemTrayController.actionShowWindow,
    );

    // 点击托盘图标重新显示主窗口。
    systemTray.emitIconActivated();
    await tester.pumpAndSettle();

    expect(appWindow.visible, isTrue);
    expect(appWindow.calls, contains('show'));
    expect(systemTray.backgroundModes.last, isFalse);
    expect(
      systemTray.latestState!.items.first.id,
      SystemTrayController.actionHideWindow,
    );

    // 再次隐藏后通过托盘菜单「退出 PagaShell」真正退出。
    systemTray.emitMenuItemSelected(SystemTrayController.actionHideWindow);
    await tester.pumpAndSettle();
    expect(appWindow.visible, isFalse);

    // 退出流程包含内存 MCP StreamController 关闭与托盘队列同步，需离开 FakeAsync 时钟。
    await tester.runAsync(() async {
      systemTray.emitMenuItemSelected(SystemTrayController.actionQuit);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(mcp.running.value, isFalse);
    expect(sessions.sessions, isEmpty);
    expect(systemTray.disposed, isTrue);
    expect(appWindow.calls, contains('destroy'));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('后台托盘态退出遇 Agent 保存失败或系统代理恢复失败时自动唤起窗口提示', (tester) async {
    final repo = InMemorySettingsRepository(minimizeToTrayOnClose: true);
    await pumpShell(
      tester,
      settingsRepository: repo,
      failingAgent: true,
      platform: TargetPlatform.macOS,
    );

    appWindow.requestClose();
    await tester.pumpAndSettle();
    expect(appWindow.visible, isFalse);

    systemTray.emitMenuItemSelected(SystemTrayController.actionQuit);
    await tester.pumpAndSettle();

    expect(appWindow.visible, isTrue);
    expect(find.text('Agent 数据尚未保存'), findsOneWidget);
    expect(appWindow.calls, isNot(contains('destroy')));

    await tester.tap(find.byKey(const ValueKey('agent-exit-without-saving')));
    await tester.pumpAndSettle();
    expect(appWindow.calls, contains('destroy'));
    expect(systemTray.disposed, isTrue);
  });

  testWidgets('后台托盘态退出遇系统代理恢复失败时唤起窗口，确认后可退出', (tester) async {
    final repo = InMemorySettingsRepository(minimizeToTrayOnClose: true);
    final sessions = _ProxyRestoreFailSessions();
    await pumpShell(
      tester,
      settingsRepository: repo,
      sessions: sessions,
      platform: TargetPlatform.macOS,
    );

    appWindow.requestClose();
    await tester.pumpAndSettle();
    expect(appWindow.visible, isFalse);

    systemTray.emitMenuItemSelected(SystemTrayController.actionQuit);
    await tester.pumpAndSettle();

    expect(appWindow.visible, isTrue);
    expect(find.text('恢复系统代理失败，请重试停止代理'), findsOneWidget);
    expect(find.textContaining('浏览器等应用无法联网'), findsOneWidget);
    expect(appWindow.calls, isNot(contains('destroy')));

    await tester.tap(
      find.byKey(const ValueKey('exit-with-incomplete-cleanup')),
    );
    await tester.pumpAndSettle();
    expect(appWindow.calls, contains('destroy'));
    expect(systemTray.disposed, isTrue);
  });

  testWidgets('macOS Dock 重开事件同步恢复后台托盘状态', (tester) async {
    final repo = InMemorySettingsRepository(minimizeToTrayOnClose: true);
    await pumpShell(
      tester,
      settingsRepository: repo,
      platform: TargetPlatform.macOS,
    );

    appWindow.requestClose();
    await tester.pumpAndSettle();
    expect(Get.find<SystemTrayController>().windowHiddenInTray.value, isTrue);

    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          windowChannel.name,
          codec.encodeMethodCall(const MethodCall('windowReopened')),
          (_) {},
        );
    await tester.pumpAndSettle();

    expect(Get.find<SystemTrayController>().windowHiddenInTray.value, isFalse);
    expect(
      systemTray.latestState!.items.first.id,
      SystemTrayController.actionHideWindow,
    );
  });
}
