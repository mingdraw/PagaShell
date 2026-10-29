import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/identities/identity_edit_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

class _LockedSecrets implements SecretStore {
  @override
  Future<void> put(String ref, String secret) async =>
      throw const SecretStoreException('无法保存密码：系统钥匙串不可用');
  @override
  Future<String?> read(String ref) async => null;
  @override
  Future<void> delete(String ref) async {}
}

class _PendingSecrets extends _LockedSecrets {
  final saved = Completer<void>();

  @override
  Future<void> put(String ref, String secret) => saved.future;
}

void main() {
  tearDown(Get.reset);

  testWidgets('服务密码写入期间禁止取消、遮罩和 Escape，完成后返回工作区', (tester) async {
    final hosts = InMemoryHostRepository();
    final folders = InMemoryFolderRepository();
    final secrets = _PendingSecrets();
    addTearDown(hosts.dispose);
    addTearDown(folders.dispose);
    addTearDown(() {
      if (!secrets.saved.isCompleted) secrets.saved.complete();
    });
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
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: Builder(
            builder: (context) => shadcn.OutlineButton(
              onPressed: () => showHostEditDialog(context),
              child: const Text('新建'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      'example.test',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存中…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.tapAt(const Offset(5, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    secrets.saved.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(find.text('新建'), findsOneWidget);
    expect(await hosts.getAll(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('凭证保存失败时保留对话框并展示可操作的错误', (tester) async {
    final repository = InMemoryIdentityRepository();
    addTearDown(repository.dispose);
    Get.put(
      IdentityController(repository: repository, secretStore: _LockedSecrets()),
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: Builder(
            builder: (context) => shadcn.OutlineButton(
              onPressed: () => showIdentityEditDialog(context),
              child: const Text('新建'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.text('无法保存密码：系统钥匙串不可用'), findsOneWidget);
    expect(await repository.getAll(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务密码保存失败提示部分保存，重试不重复创建主机', (tester) async {
    final hosts = InMemoryHostRepository();
    final folders = InMemoryFolderRepository();
    final identities = InMemoryIdentityRepository();
    addTearDown(hosts.dispose);
    addTearDown(folders.dispose);
    addTearDown(identities.dispose);
    Get.put(
      HostController(
        repository: hosts,
        secretStore: _LockedSecrets(),
        treeRepository: InMemoryHostTreeRepository(
          folders: folders,
          hosts: hosts,
        ),
      ),
    );
    Get.put(
      IdentityController(repository: identities, secretStore: _LockedSecrets()),
    );
    await tester.pumpWidget(
      ShadcnTestApp(home: const shadcn.Scaffold(child: HostEditDialog())),
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      'example.com',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('密码操作未完成'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await hosts.getAll(), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
