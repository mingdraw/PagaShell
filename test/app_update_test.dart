import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/updates/app_update_controller.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/updates/app_release.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/update_fixtures.dart';

class _UiUpdates extends AppUpdateController {
  _UiUpdates({required super.connect, required super.settings})
    : super(
        createDownloadConnect: AppConnect.new,
        installer: TestUpdateInstaller(),
      );
  int installCalls = 0;
  int cancelCalls = 0;
  final downloading = Completer<void>();
  @override
  Future<void> install(AppRelease release) async {
    installCalls++;
    phase.value = UpdatePhase.downloading;
    progress.value = 0.4;
    await downloading.future;
    phase.value = UpdatePhase.idle;
  }

  @override
  Future<void> cancelDownload() async {
    cancelCalls++;
    downloading.complete();
  }
}

class _UpdateBinding extends InMemoryBinding {
  _UpdateBinding({
    bool automatic = false,
    String latest = '0.3.0',
    this.sessions,
  }) : connect = UpdateConnect(
         handler: () =>
             Response(statusCode: 200, body: releaseJson(version: latest)),
       ),
       super(
         settingsRepository: InMemorySettingsRepository(
           automaticUpdates: automatic,
         ),
       );
  final UpdateConnect connect;
  final SessionController? sessions;
  late final _UiUpdates updates;
  @override
  void dependencies() {
    super.dependencies();
    if (sessions != null) Get.replace<SessionController>(sessions!);
    updates = Get.put<_UiUpdates>(
      _UiUpdates(connect: connect, settings: Get.find<SettingsController>()),
    );
    Get.put<AppUpdateController>(updates);
  }
}

class _NoEngine extends Fake implements SshEngine {}

class _ExitSessions extends SessionController {
  _ExitSessions(this.events) : super(engine: _NoEngine());
  final List<String> events;
  bool restoreFails = false;
  @override
  Future<void> closeAll() async {
    events.add('close-sessions');
    if (restoreFails) throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
  }
}

void main() {
  tearDown(Get.reset);

  Future<void> pump(WidgetTester tester, _UpdateBinding binding) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: binding, platform: defaultTargetPlatform),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      binding.connect.dispose();
    });
  }

  testWidgets('通用设置开关可保存，关闭时仍可手动检查、下载并取消', (tester) async {
    final binding = _UpdateBinding();
    await pump(tester, binding);
    expect(binding.connect.calls, 0);
    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('automatic-updates-switch'));
    expect(tester.widget<shadcn.Switch>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      (binding.settingsRepository as InMemorySettingsRepository)
          .automaticUpdates,
      isTrue,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      (binding.settingsRepository as InMemorySettingsRepository)
          .automaticUpdates,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('check-for-updates')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.3.0'), findsOneWidget);
    expect(find.text('修复终端问题'), findsOneWidget);
    expect(binding.updates.installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('install-app-update')));
    await tester.pump();
    expect(binding.updates.installCalls, 1);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('暂不更新'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cancel-update-download')));
    await tester.pumpAndSettle();
    expect(binding.updates.cancelCalls, 1);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(find.byType(SettingsDialog), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('启动检查发现新版先询问，不自动下载安装', (tester) async {
    final binding = _UpdateBinding(automatic: true);
    await pump(tester, binding);
    expect(binding.connect.calls, 1);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    expect(binding.updates.installCalls, 0);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(await binding.updates.checkOnStartup(), isNull);
    expect(binding.connect.calls, 1);
  });

  testWidgets('手动检查最新版会在通用设置显示结果', (tester) async {
    final binding = _UpdateBinding(latest: '0.2.1');
    await pump(tester, binding);
    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-for-updates')));
    await tester.pumpAndSettle();
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 更新退出先关闭会话，提交后再销毁原生窗口', (tester) async {
      final events = <String>[];
      final sessions = _ExitSessions(events);
      final binding = _UpdateBinding(sessions: sessions);
      final messenger = tester.binding.defaultBinaryMessenger;
      for (final name in ['pagashell/window', 'window_manager']) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'destroy') events.add(name);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      await pump(tester, binding);
      final result = await binding.updates.exitForUpdate!(() async {
        events.add('commit');
      });
      expect(result, isTrue);
      expect(events, [
        'close-sessions',
        'commit',
        platform == TargetPlatform.windows
            ? 'pagashell/window'
            : 'window_manager',
      ]);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('代理恢复失败时更新退出不提交，也不销毁窗口', (tester) async {
    final events = <String>[];
    final sessions = _ExitSessions(events)..restoreFails = true;
    final binding = _UpdateBinding(sessions: sessions);
    await pump(tester, binding);
    expect(
      await binding.updates.exitForUpdate!(() async {
        events.add('commit');
      }),
      isFalse,
    );
    await tester.pump();
    expect(events, ['close-sessions']);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
