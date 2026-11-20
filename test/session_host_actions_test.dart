import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';

final _page = Host(
  id: 'page',
  name: 'Page relay',
  hostname: 'relay.test',
  port: 7443,
  gatewayType: GatewayType.page,
  pageClientId: 'client-a',
  pageServerFingerprint: 'a' * 64,
);

class _Engine implements SshEngine {
  final attempts = <(Host, SshCredentials, SshGateway?)>[];
  bool failNext = false;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    attempts.add((host, credentials, gateway));
    if (failNext) {
      failNext = false;
      throw const SshEngineException('测试连接失败');
    }
    return FakeSftpSession();
  }
}

void main() {
  tearDown(Get.reset);

  Future<void> mount(WidgetTester tester, {_Engine? engine}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine ?? _Engine()),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tab(String id) => find.byWidgetPredicate(
    (widget) => widget is shadcn.KeyedTabItem<String> && widget.tabKey == id,
  );
  final editFailed = find.byKey(const ValueKey('failed-edit-host'));

  for (final kind in [SessionKind.portForward, SessionKind.dynamicProxy]) {
    testWidgets('${kind.name} 标签编辑 Page 网关并保留网关配置', (tester) async {
      await mount(tester);
      final gateways = Get.find<GatewayController>();
      final hosts = Get.find<HostController>();
      final sessions = Get.find<SessionController>();
      await gateways.save(_page);
      await gateways.savePassword(_page.id, 'fixture-token');
      await hosts.save(
        const Host(
          id: 'service',
          name: 'Internal',
          hostname: 'internal.test',
          gatewayId: 'page',
        ),
      );
      final id = kind == SessionKind.portForward
          ? sessions.openForward(_page)
          : sessions.openProxy(_page);
      await tester.pumpAndSettle();
      await tester.tap(tab(id), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      final edit = find.widgetWithText(shadcn.MenuButton, '编辑网关');
      expect(edit, findsOneWidget);
      expect(find.widgetWithText(shadcn.MenuButton, '编辑服务'), findsNothing);
      final closeRight = find.widgetWithText(shadcn.MenuButton, '关闭右侧标签');
      expect(tester.widget<shadcn.MenuButton>(closeRight).enabled, isFalse);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        tester.widget<HostEditDialog>(find.byType(HostEditDialog)).gateway,
        isTrue,
      );
      await tester.enterText(
        find.widgetWithText(AppTextFormField, '名称'),
        'Updated relay',
      );
      await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.byType(HostEditDialog), findsNothing);
      final saved = await gateways.findSaved(_page.id);
      expect(saved?.name, 'Updated relay');
      expect(saved?.gatewayType, GatewayType.page);
      expect(saved?.pageClientId, _page.pageClientId);
      expect(saved?.pageServerFingerprint, _page.pageServerFingerprint);
      expect(await hosts.findSaved(_page.id), isNull);
      expect((await hosts.findSaved('service'))?.gatewayId, _page.id);
    });
  }

  for (final connectOnSave in [false, true]) {
    testWidgets('失败窗格${connectOnSave ? '保存并连接' : '保存后重试'}读取新地址、凭据和网关', (
      tester,
    ) async {
      final engine = _Engine();
      await mount(tester, engine: engine);
      final hosts = Get.find<HostController>();
      final gateways = Get.find<GatewayController>();
      final sessions = Get.find<SessionController>();
      const first = Host(id: 'first', name: 'First', hostname: 'first.test');
      const failed = Host(
        id: 'failed',
        name: 'Other',
        hostname: 'old.test',
        gatewayId: 'page',
      );
      const password = SshCredentials.password('old-password');
      await gateways.save(_page);
      await gateways.savePassword(_page.id, 'old-token');
      await hosts.save(failed);
      await hosts.savePassword(failed.id, 'old-password');
      final tabId = await sessions.open(first, password);
      engine.failNext = true;
      final id = (await sessions.splitToHost(
        tabId,
        failed,
        password,
        edge: SessionSplitEdge.right,
        gateway: SshGateway.page(host: _page, token: 'old-token'),
      ))!;
      await tester.pumpAndSettle();
      await tester.tap(editFailed);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('host-address')),
        'deploy@updated.test:2202',
      );
      await tester.enterText(
        find.byKey(const ValueKey('host-password')),
        'new-password',
      );
      await gateways.save(_page.copyWith(hostname: 'updated-relay.test'));
      await gateways.savePassword(_page.id, 'new-token');
      if (connectOnSave) {
        await tester.tap(find.byKey(const ValueKey('host-save-connect')));
      } else {
        await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '保存'));
        await tester.pumpAndSettle();
        expect(engine.attempts, hasLength(2));
        await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '重试'));
      }
      await tester.pumpAndSettle();
      expect(engine.attempts, hasLength(3));
      final (host, credentials, gateway) = engine.attempts.last;
      expect(
        (host.hostname, host.username, host.port),
        ('updated.test', 'deploy', 2202),
      );
      expect(credentials.password, 'new-password');
      expect(gateway?.host.hostname, 'updated-relay.test');
      expect(gateway?.credentials.password, 'new-token');
      expect(sessions.tabForSession(id)?.sessionIds, [tabId, id]);
      expect(sessions.activeSession?.phase, SessionPhase.ready);
    });
  }

  testWidgets('失败的临时连接可用已有凭证新建会话，服务库和最近连接不写入', (tester) async {
    final engine = _Engine()..failNext = true;
    await mount(tester, engine: engine);
    final sessions = Get.find<SessionController>();
    await Get.find<IdentityController>().saveWithPassword(
      name: 'Saved login',
      username: 'root',
      password: 'stored-password',
    );
    const host = Host(
      id: 'temporary-fixture',
      name: 'Transient',
      hostname: 'transient.test',
    );
    final id = await sessions.open(
      host,
      const SshCredentials.password('unused'),
      temporary: true,
    );
    await tester.pumpAndSettle();
    expect(editFailed, findsNothing);
    await tester.tap(tab(id), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(shadcn.MenuButton, '编辑服务'), findsNothing);
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '新建会话'));
    await tester.pumpAndSettle();
    expect(find.text('保存为凭证，供其他服务复用'), findsNothing);
    await tester.tap(find.widgetWithText(AppSelectField<String>, '凭证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved login（root · 密码）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '连接'));
    await tester.pumpAndSettle();
    expect(sessions.tabs, hasLength(2));
    expect(engine.attempts.last.$2.password, 'stored-password');
    expect(sessions.isTemporarySession(sessions.activeSession!.id), isTrue);
    expect(await Get.find<HostController>().findSaved(host.id), isNull);
    expect(sessions.recentHostIds, isEmpty);
    expect(
      Get.find<SettingsController>().sidebarState.value.recentHostIds,
      isEmpty,
    );
  });

  testWidgets('编辑对话框打开后删除服务，保存也不能恢复旧记录', (tester) async {
    final engine = _Engine()..failNext = true;
    await mount(tester, engine: engine);
    final hosts = Get.find<HostController>();
    const host = Host(id: 'gone', name: 'Gone', hostname: 'gone.test');
    await hosts.save(host);
    await Get.find<SessionController>().open(
      host,
      const SshCredentials.password('unused'),
    );
    await tester.pumpAndSettle();
    await tester.tap(editFailed);
    await tester.pumpAndSettle();
    await hosts.remove(host.id);
    await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '保存'));
    await tester.pumpAndSettle();
    expect(await hosts.findSaved(host.id), isNull);
    expect(find.text('所选服务已不存在'), findsOneWidget);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消'));
    await tester.pumpAndSettle();
    expect(editFailed, findsNothing);
  });

  testWidgets('凭证重名时保留输入密码，改名后提交并用原密码连接', (tester) async {
    final engine = _Engine();
    await mount(tester, engine: engine);
    final hosts = Get.find<HostController>();
    final identities = Get.find<IdentityController>();
    const host = Host(
      id: 'login',
      name: 'Batch login',
      hostname: 'fixture.test',
      username: 'ops',
    );
    await hosts.save(host);
    await identities.saveWithPassword(
      name: 'Existing',
      username: 'ops',
      password: 'existing-test-value',
    );
    await tester.pumpAndSettle();
    final row = find.text(host.name);
    final connecting = connectToHost(tester.element(row), host);
    await tester.pumpAndSettle();

    final manualPassword = find.ancestor(
      of: find.byWidgetPredicate(
        (widget) => widget is EditableText && widget.obscureText,
      ),
      matching: find.byType(AppTextFormField),
    );
    await tester.enterText(manualPassword, 'new-test-value');
    await tester.tap(find.byType(shadcn.Checkbox));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('connect-identity-name'));
    await tester.enterText(name, 'Existing');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('同级下已存在同名凭证'), findsOneWidget);
    expect(
      tester.widget<AppTextFormField>(manualPassword).controller.text,
      'new-test-value',
    );
    expect(engine.attempts, isEmpty);

    await tester.enterText(name, 'New login');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await connecting;
    expect(name, findsNothing);
    expect(engine.attempts.single.$2.password, 'new-test-value');
    final saved = identities.sorted.singleWhere(
      (item) => item.name == 'New login',
    );
    expect((await hosts.findSaved(host.id))?.identityId, saved.id);
  });
}
