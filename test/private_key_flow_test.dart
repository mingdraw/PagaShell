import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/identities/identity_edit_dialog.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_private_key_validator.dart';
import 'support/shadcn_test_app.dart';

/// 在协议边界记录凭据，真实 SSH 签名和连接清理由 Rust 测试验证。
class _CapturingEngine implements SshEngine {
  final List<(Host, SshCredentials)> calls = [];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    calls.add((host, credentials));
    throw const SshEngineException('测试桩不连接服务器');
  }
}

class _FailingIdentityRepository extends InMemoryIdentityRepository {
  bool failNextWrite = false;

  @override
  Future<void> upsert(Identity identity) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('sensitive-database-error');
    }
    await super.upsert(identity);
  }
}

void main() {
  late _FailingIdentityRepository identities;
  late InMemoryHostRepository hosts;
  late InMemoryFolderRepository folders;
  late InMemorySecretStore secrets;
  late FakePrivateKeyValidator validator;
  late IdentityController controller;
  late _CapturingEngine engine;

  const host = Host(
    id: 'host',
    name: 'server',
    hostname: 'example.test',
    username: 'root',
  );

  setUp(() {
    identities = _FailingIdentityRepository();
    hosts = InMemoryHostRepository();
    folders = InMemoryFolderRepository();
    secrets = InMemorySecretStore();
    validator = FakePrivateKeyValidator();
    engine = _CapturingEngine();
    controller = Get.put(
      IdentityController(
        repository: identities,
        secretStore: secrets,
        privateKeyValidator: validator,
      ),
      permanent: true,
    );
    Get.put(
      HostController(
        repository: hosts,
        secretStore: secrets,
        treeRepository: InMemoryHostTreeRepository(
          folders: folders,
          hosts: hosts,
        ),
      ),
      permanent: true,
    );
    Get.put(SessionController(engine: engine), permanent: true);
  });

  tearDown(() {
    Get.reset();
    identities.dispose();
    hosts.dispose();
    folders.dispose();
  });

  Future<void> mount(
    WidgetTester tester,
    VoidCallback Function(BuildContext) action,
  ) async {
    // Desktop dialog size: the private-key form intentionally has more fields.
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: Builder(
            builder: (context) => shadcn.OutlineButton(
              onPressed: action(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> selectPrivateKey(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(AppSelectField<AuthType>, '认证方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私钥').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppTextFormField, '私钥内容'), findsOneWidget);
  }

  Future<void> enterKey(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '私钥内容'),
      'test-private-key',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '私钥口令（可选）'),
      'test-phrase',
    );
  }

  testWidgets('创建私钥凭证后仅钥匙串持有密钥和口令', (tester) async {
    await mount(
      tester,
      (context) =>
          () => showIdentityEditDialog(context),
    );
    await selectPrivateKey(tester);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'deploy-key',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '用户名'),
      'deploy',
    );
    await enterKey(tester);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    final identity = (await identities.getAll()).single;
    final credentials = await controller.credentialsOf(identity);
    expect(identity.name, 'deploy-key');
    expect(identity.authType, AuthType.privateKey);
    expect(credentials?.username, 'deploy');
    expect(credentials?.privateKey, 'test-private-key');
    expect(credentials?.passphrase, 'test-phrase');
  });

  testWidgets('编辑私钥凭证不预填密文，留空保留原值', (tester) async {
    final identity = await controller.saveWithPrivateKey(
      name: 'key',
      username: 'deploy',
      privateKey: 'stored-key',
      passphrase: 'stored-phrase',
    );
    await mount(
      tester,
      (context) =>
          () => showIdentityEditDialog(context, identity: identity),
    );
    final keyField = tester.widget<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '私钥内容'),
    );
    final phraseField = tester.widget<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '私钥口令（可选）'),
    );
    expect(keyField.controller.text, isEmpty);
    expect(phraseField.controller.text, isEmpty);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'renamed-key',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((await identities.getAll()).single.name, 'renamed-key');
    final credentials = await controller.credentialsOf(identity);
    expect(credentials?.privateKey, 'stored-key');
    expect(credentials?.passphrase, 'stored-phrase');
    expect(validator.calls, hasLength(1));
  });

  testWidgets('私钥解析失败时留在表单并且不保存凭证', (tester) async {
    validator.error = '私钥格式无效或口令错误，请检查私钥与口令';
    await mount(
      tester,
      (context) =>
          () => showIdentityEditDialog(context),
    );
    await selectPrivateKey(tester);
    await enterKey(tester);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.text(validator.error!), findsOneWidget);
    expect(await identities.getAll(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存期间禁止取消、点击遮罩或 Escape 退出', (tester) async {
    final completion = Completer<void>();
    validator.pause = completion;
    await mount(
      tester,
      (context) =>
          () => showIdentityEditDialog(context),
    );
    await selectPrivateKey(tester);
    await enterKey(tester);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<shadcn.OutlineButton>(
            find.widgetWithText(shadcn.OutlineButton, '取消'),
          )
          .onPressed,
      isNull,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(await identities.getAll(), isEmpty);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(await identities.getAll(), hasLength(1));
  });

  testWidgets('即时私钥连接传递密钥和口令，默认不保存', (tester) async {
    await mount(
      tester,
      (context) =>
          () => connectToHost(context, host),
    );
    await selectPrivateKey(tester);
    await enterKey(tester);
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    final credentials = engine.calls.single.$2;
    expect(credentials.authType, AuthType.privateKey);
    expect(credentials.privateKey, 'test-private-key');
    expect(credentials.passphrase, 'test-phrase');
    expect(await identities.getAll(), isEmpty);
    expect(await hosts.getAll(), isEmpty);
  });

  testWidgets('即时私钥可保存为凭证并绑定服务，下次无需输入', (tester) async {
    late Future<void> connecting;
    await mount(
      tester,
      (context) => () {
        connecting = connectToHost(context, host);
      },
    );
    await selectPrivateKey(tester);
    await enterKey(tester);
    await tester.tap(find.text('保存为凭证，供其他服务复用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    await connecting;
    await tester.pumpAndSettle();
    final identity = (await identities.getAll()).single;
    final storedHost = (await hosts.getAll()).single;
    expect(storedHost.identityId, identity.id);
    expect(engine.calls.single.$1.identityId, identity.id);
    final credentials = await controller.credentialsOf(identity);
    expect(credentials?.privateKey, 'test-private-key');
    expect(credentials?.passphrase, 'test-phrase');

    // forceNew bypasses the existing test session and exercises the saved binding.
    await mount(
      tester,
      (context) =>
          () => connectToHost(context, storedHost, forceNew: true),
    );
    expect(find.byType(AppDialog), findsNothing);
    expect(engine.calls, hasLength(2));
    expect(engine.calls.last.$2.privateKey, 'test-private-key');
    expect(engine.calls.last.$2.username, 'root');
  });

  testWidgets('即时凭证保存的数据库故障显示安全提示并停止连接', (tester) async {
    identities.failNextWrite = true;
    await mount(
      tester,
      (context) =>
          () => connectToHost(context, host),
    );
    await selectPrivateKey(tester);
    await enterKey(tester);
    await tester.tap(find.text('保存为凭证，供其他服务复用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.text('无法准备连接，请重试'), findsOneWidget);
    expect(find.textContaining('sensitive-database-error'), findsNothing);
    expect(await identities.getAll(), isEmpty);
    expect(await hosts.getAll(), isEmpty);
    expect(engine.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('选择已有私钥凭证使用凭证用户名并持久化绑定', (tester) async {
    late Future<void> connecting;
    final identity = await controller.saveWithPrivateKey(
      name: 'deploy-key',
      username: 'deploy',
      privateKey: 'stored-key',
      passphrase: 'stored-phrase',
    );
    await mount(
      tester,
      (context) => () {
        connecting = connectToHost(context, host);
      },
    );
    await tester.tap(find.widgetWithText(AppSelectField<String>, '凭证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('deploy-key（deploy · 私钥）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    await connecting;
    await tester.pumpAndSettle();
    expect(engine.calls.single.$2.username, 'deploy');
    expect(engine.calls.single.$2.privateKey, 'stored-key');
    expect((await hosts.getAll()).single.identityId, identity.id);
  });

  testWidgets('保留的未实现认证类型不会使编辑对话框崩溃', (tester) async {
    const identity = Identity(
      id: 'legacy',
      name: 'legacy',
      username: 'root',
      authType: AuthType.agent,
    );
    await mount(
      tester,
      (context) =>
          () => showIdentityEditDialog(context, identity: identity),
    );
    expect(find.text('暂不支持此认证方式'), findsOneWidget);
    expect(
      tester
          .widget<shadcn.PrimaryButton>(
            find.widgetWithText(shadcn.PrimaryButton, '保存'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
