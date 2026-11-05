import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/presentation/shell/shell_page.dart';

import 'support/fixture_terminal.dart';

import 'support/in_memory_agent_conversation_repository.dart';
import 'support/in_memory_binding.dart';

class _ExitAgent extends AgentController {
  _ExitAgent()
    : super(
        connect: Get.find<GetConnect>(tag: 'ai'),
        settings: Get.find<AiSettingsController>(),
        secretStore: Get.find<SecretStore>(),
        sessions: Get.find<SessionController>(),
        conversations: InMemoryAgentConversationRepository(),
      );

  final saving = Completer<bool>();
  int exitCalls = 0;

  @override
  Future<bool> prepareForExit() {
    exitCalls++;
    return saving.future;
  }
}

class _EngineSession extends Fake implements SshEngineSession {
  final closing = Completer<void>();
  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    return closing.future;
  }
}

class _UnusedEngine extends Fake implements SshEngine {}

class _ProxyRestoreSessions extends SessionController {
  _ProxyRestoreSessions() : super(engine: _UnusedEngine());

  bool restoreFails = true;

  @override
  Future<void> closeAll() async {
    if (restoreFails) {
      throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
    }
    await super.closeAll();
  }
}

class _Binding extends InMemoryBinding {
  _Binding({this.waitForAgent = false, this.sessions});

  final bool waitForAgent;
  final SessionController? sessions;
  _ExitAgent? exitAgent;

  @override
  void dependencies() {
    super.dependencies();
    if (sessions != null) Get.replace<SessionController>(sessions!);
    if (waitForAgent) {
      exitAgent = _ExitAgent();
      Get.replace<AgentController>(exitAgent!);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('pagashell/window');
  const managerChannel = MethodChannel('window_manager');
  const codec = StandardMethodCodec();
  final calls = <String>[];

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add('native:${call.method}');
      return null;
    });
    messenger.setMockMethodCallHandler(managerChannel, (call) async {
      calls.add('manager:${call.method}');
      return null;
    });
    calls.clear();
  });

  tearDown(() {
    Get.reset();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(managerChannel, null);
  });

  Future<void> pump(WidgetTester tester, {_Binding? binding}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(
        binding: binding ?? _Binding(),
        platform: defaultTargetPlatform,
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
    calls.clear();
  }

  Future<void> requestClose(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'window_manager',
      codec.encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      null,
    );
  }

  testWidgets('Windows 空窗口通过原生窗口销毁流程退出，重复关闭只销毁一次', (tester) async {
    await pump(tester);
    expect(find.byType(ShellPage, skipOffstage: false), findsOneWidget);
    await Future.wait(List.generate(3, (_) => requestClose(tester)));
    await tester.pumpAndSettle();
    expect(calls, ['native:destroy']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('等待 Agent 保存和 SSH 断开后才允许原生销毁', (tester) async {
    final binding = _Binding(waitForAgent: true);
    await pump(tester, binding: binding);
    final engine = _EngineSession();
    Get.find<SessionController>().sessions.add(
      Session(
        id: 'closing',
        host: const Host(id: 'closing', name: 'Server', hostname: 'test'),
        phase: SessionPhase.ready,
        engineSession: engine,
        terminal: Terminal(),
      ),
    );
    await Future.wait(List.generate(2, (_) => requestClose(tester)));
    await tester.pumpAndSettle();
    expect(binding.exitAgent!.exitCalls, 1);
    expect(engine.closeCalls, 0);
    expect(calls, isEmpty);

    binding.exitAgent!.saving.complete(true);
    await tester.pumpAndSettle();
    expect(engine.closeCalls, 1);
    expect(calls, isEmpty);
    engine.closing.complete();
    await tester.pumpAndSettle();
    expect(calls, ['native:destroy']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Agent 保存失败时可取消退出，确认仍然退出后才销毁窗口', (tester) async {
    final binding = _Binding(waitForAgent: true);
    await pump(tester, binding: binding);
    binding.exitAgent!.saving.complete(false);
    await requestClose(tester);
    await tester.pumpAndSettle();
    expect(find.text('Agent 数据尚未保存'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await requestClose(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-exit-without-saving')));
    await tester.pumpAndSettle();
    expect(calls, ['native:destroy']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('系统代理恢复失败保留窗口，恢复后可重新关闭', (tester) async {
    final sessions = _ProxyRestoreSessions();
    await pump(tester, binding: _Binding(sessions: sessions));
    await requestClose(tester);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('恢复系统代理失败，请重试停止代理'), findsOneWidget);

    sessions.restoreFails = false;
    await requestClose(tester);
    await tester.pumpAndSettle();
    expect(calls, ['native:destroy']);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    testWidgets('$platform 沿用平台窗口管理器退出', (tester) async {
      await pump(tester);
      await requestClose(tester);
      await tester.pumpAndSettle();
      expect(calls, ['manager:destroy']);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }
}
