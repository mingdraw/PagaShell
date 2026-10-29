import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/identities/identity_edit_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_private_key_validator.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _ControlledSecrets extends InMemorySecretStore {
  bool locked = false;
  Completer<String?>? pending;

  @override
  Future<String?> read(String ref) async {
    if (locked) throw const SecretStoreException('无法读取系统钥匙串，请解锁后重试');
    if (pending != null) return pending!.future;
    return super.read(ref);
  }
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PagaShellApp(binding: InMemoryBinding()));
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester, String label) => tester
      .widget<AppTextFormField>(find.widgetWithText(AppTextFormField, label))
      .controller
      .text;

  Future<void> copyMenu(WidgetTester tester, String name) async {
    await tester.tap(find.text(name), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    final copy = tester.widget<shadcn.MenuButton>(
      find.widgetWithText(shadcn.MenuButton, '复制'),
    );
    expect((copy.leading! as Icon).icon, shadcn.LucideIcons.copy);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
  }

  for (final gateway in [false, true]) {
    for (final boundIdentity in [false, true]) {
      final kind = gateway ? '网关' : '服务';
      testWidgets('$kind 右键复制预填内容，保存新 ID、同级末尾和独立密码（凭证绑定：$boundIdentity）', (
        tester,
      ) async {
        await pumpApp(tester);
        final controller = gateway
            ? Get.find<GatewayController>()
            : Get.find<HostController>();
        final folders = gateway
            ? Get.find<GatewayFolderController>()
            : Get.find<FolderController>();
        final folder = await folders.create(name: 'Source folder');
        folders.expanded.add(folder.id);
        final identities = Get.find<IdentityController>();
        final identity = await identities.saveWithPassword(
          name: 'Reusable login',
          username: 'credential-user',
          password: 'credential-secret',
        );
        const jump = Host(
          id: 'jump',
          name: 'Jump',
          hostname: 'jump.test',
          username: 'jump',
        );
        if (!gateway) await Get.find<GatewayController>().save(jump);
        final original = Host(
          id: 'source',
          name: 'Source $kind',
          hostname: 'source.test',
          port: 2222,
          username: 'source-user',
          note: 'source note',
          tags: const ['production'],
          colorValue: 0xFF123456,
          folderId: folder.id,
          identityId: boundIdentity ? identity.id : null,
          gatewayId: gateway ? null : jump.id,
        );
        await controller.save(original);
        await controller.savePassword(original.id, 'source-secret');
        await tester.pumpAndSettle();
        await copyMenu(tester, original.name);
        expect(
          find.descendant(
            of: find.byType(AppDialog),
            matching: find.text('新建$kind'),
          ),
          findsOneWidget,
        );
        expect(fieldText(tester, '名称'), '${original.name} (2)');
        expect(fieldText(tester, '$kind地址'), original.hostname);
        expect(fieldText(tester, '端口'), '2222');
        expect(fieldText(tester, '备注'), original.note);
        expect(controller.hosts, hasLength(1));
        if (boundIdentity) {
          expect(find.text('已有凭证'), findsOneWidget);
          expect(find.text(identity.name), findsWidgets);
        } else {
          expect(fieldText(tester, '用户名'), original.username);
          expect(fieldText(tester, '密码'), 'source-secret');
          await tester.enterText(
            find.widgetWithText(AppTextFormField, '密码'),
            'copied-secret',
          );
        }
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        final copy = controller.hosts.singleWhere((h) => h.id != original.id);
        final source = controller.hosts.singleWhere((h) => h.id == original.id);
        expect(copy.name, '${original.name} (2)');
        expect(copy.folderId, source.folderId);
        expect(copy.sortOrder, greaterThan(source.sortOrder));
        expect(copy.hostname, source.hostname);
        expect(copy.username, source.username);
        expect(copy.port, source.port);
        expect(copy.note, source.note);
        expect(copy.tags, source.tags);
        expect(copy.colorValue, source.colorValue);
        expect(copy.identityId, source.identityId);
        expect(copy.gatewayId, source.gatewayId);
        expect(await controller.passwordOf(original.id), 'source-secret');
        expect(
          await controller.passwordOf(copy.id),
          boundIdentity ? isNull : 'copied-secret',
        );
        await copyMenu(tester, original.name);
        expect(fieldText(tester, '名称'), '${original.name} (3)');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(controller.hosts, hasLength(2));
        await controller.remove(copy.id);
        expect(await controller.passwordOf(original.id), 'source-secret');
        expect(await identities.passwordOf(identity), 'credential-secret');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('凭证右键复制可取消，保存为同文件夹末尾的独立凭证', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<IdentityFolderController>();
    final folder = await folders.create(name: 'Credential folder');
    folders.expanded.add(folder.id);
    final controller = Get.find<IdentityController>();
    final source = await controller.saveWithPassword(
      name: 'Login',
      username: 'user',
      password: 'original-secret',
      folderId: folder.id,
    );
    await tester.pumpAndSettle();
    await copyMenu(tester, source.name);
    expect(find.text('新建凭证'), findsOneWidget);
    expect(fieldText(tester, '名称'), 'Login (2)');
    expect(fieldText(tester, '用户名'), 'user');
    expect(fieldText(tester, '密码'), 'original-secret');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.identities, hasLength(1));
    await copyMenu(tester, source.name);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'new-secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final copy = controller.identities.singleWhere((i) => i.id != source.id);
    expect(copy.name, 'Login (2)');
    expect(copy.username, source.username);
    expect(copy.folderId, folder.id);
    expect(copy.sortOrder, greaterThan(source.sortOrder));
    expect(copy.secretRef, isNot(source.secretRef));
    expect(await controller.passwordOf(copy), 'new-secret');
    await controller.remove(copy.id);
    expect(await controller.passwordOf(source), 'original-secret');
    expect(tester.takeException(), isNull);
  });

  Future<IdentityController> standalone(
    WidgetTester tester,
    _ControlledSecrets secrets, {
    bool identity = true,
    Identity? sourceIdentity,
  }) async {
    final identities = InMemoryIdentityRepository();
    final hosts = InMemoryHostRepository();
    final folders = InMemoryFolderRepository();
    addTearDown(identities.dispose);
    addTearDown(hosts.dispose);
    addTearDown(folders.dispose);
    final controller = Get.put(
      IdentityController(
        repository: identities,
        secretStore: secrets,
        privateKeyValidator: FakePrivateKeyValidator(),
      ),
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
    );
    await tester.pump();
    final source =
        sourceIdentity ??
        const Identity(
          id: 'identity',
          name: 'Login',
          username: 'root',
          authType: AuthType.password,
          secretRef: 'source-ref',
        );
    await identities.upsert(source);
    const host = Host(
      id: 'host',
      name: 'Service',
      hostname: 'service.test',
      username: 'root',
    );
    await hosts.upsert(host);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: Builder(
            builder: (context) => shadcn.OutlineButton(
              onPressed: () => identity
                  ? showIdentityEditDialog(context, copyFrom: source)
                  : showHostEditDialog(context, copyFrom: host),
              child: const Text('Copy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    return controller;
  }

  for (final identity in [false, true]) {
    testWidgets('${identity ? '凭证' : '服务'}复制等待读取密码，失败可重试且不提前创建', (
      tester,
    ) async {
      final secrets = _ControlledSecrets()..locked = true;
      await secrets.put(identity ? 'source-ref' : 'sec-host-host', 'secret');
      final controller = await standalone(tester, secrets, identity: identity);
      expect(find.text('无法读取系统钥匙串，请解锁后重试'), findsOneWidget);
      expect(
        tester
            .widget<shadcn.PrimaryButton>(find.byType(shadcn.PrimaryButton))
            .onPressed,
        isNull,
      );
      expect(controller.identities, hasLength(1));
      expect(Get.find<HostController>().hosts, hasLength(1));
      secrets.locked = false;
      secrets.pending = Completer<String?>();
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('读取中…'), findsOneWidget);
      expect(
        tester
            .widget<shadcn.PrimaryButton>(find.byType(shadcn.PrimaryButton))
            .onPressed,
        isNull,
      );
      secrets.pending!.complete('secret');
      await tester.pumpAndSettle();
      expect(fieldText(tester, '密码'), 'secret');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(controller.identities, hasLength(identity ? 2 : 1));
      expect(Get.find<HostController>().hosts, hasLength(identity ? 1 : 2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('复制私钥凭证预填私钥和口令，使用新密文引用保存', (tester) async {
    final secrets = _ControlledSecrets();
    await secrets.put(
      'source-ref',
      '{"version":1,"privateKey":"PRIVATE KEY","passphrase":"phrase"}',
    );
    final controller = await standalone(
      tester,
      secrets,
      sourceIdentity: const Identity(
        id: 'identity',
        name: 'Key',
        username: 'key-user',
        authType: AuthType.privateKey,
        secretRef: 'source-ref',
      ),
    );
    final source = controller.identities.single;
    expect(find.text('私钥'), findsWidgets);
    expect(fieldText(tester, '私钥内容'), 'PRIVATE KEY');
    expect(fieldText(tester, '私钥口令（可选）'), 'phrase');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final copy = controller.identities.singleWhere((i) => i.id != source.id);
    expect(copy.secretRef, isNot(source.secretRef));
    expect(copy.authType, AuthType.privateKey);
    expect(copy.username, 'key-user');
    final credentials = await controller.credentialsOf(copy);
    expect(credentials!.privateKey, 'PRIVATE KEY');
    expect(credentials.passphrase, 'phrase');
    await controller.remove(copy.id);
    expect((await controller.credentialsOf(source))!.privateKey, 'PRIVATE KEY');
    expect(tester.takeException(), isNull);
  });
}
