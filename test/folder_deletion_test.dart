import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/folders/tree_folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/repositories/identity_repository.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/presentation/folders/folder_dialogs.dart';
import 'package:pagashell/presentation/shell/shell_page.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';

enum _Kind { service, identity, gateway }

typedef _Item = ({String id, String secretRef});

class _FailingSecrets extends InMemorySecretStore {
  bool failDelete = false;

  @override
  Future<void> delete(String ref) async {
    if (failDelete) throw const SecretStoreException('钥匙串不可用');
    await super.delete(ref);
  }
}

TreeFolderController _folders(_Kind kind) => switch (kind) {
  _Kind.service => Get.find<FolderController>(),
  _Kind.identity => Get.find<IdentityFolderController>(),
  _Kind.gateway => Get.find<GatewayFolderController>(),
};

Future<void> Function(Set<String>) _removeItems(_Kind kind) => switch (kind) {
  _Kind.service => Get.find<HostController>().removeInFolders,
  _Kind.identity => Get.find<IdentityController>().removeInFolders,
  _Kind.gateway => Get.find<GatewayController>().removeInFolders,
};

Future<_Item> _addItem(_Kind kind, String name, String folderId) async {
  if (kind == _Kind.identity) {
    final identity = await Get.find<IdentityController>().saveWithPassword(
      name: name,
      username: 'deploy',
      password: 'test-secret',
      folderId: folderId,
    );
    return (id: identity.id, secretRef: identity.secretRef!);
  }
  final controller = kind == _Kind.gateway
      ? Get.find<GatewayController>()
      : Get.find<HostController>();
  final id = '${kind.name}-$name';
  await controller.save(
    Host(id: id, name: name, hostname: 'example.test', folderId: folderId),
  );
  await controller.savePassword(id, 'test-secret');
  return (id: id, secretRef: 'sec-host-$id');
}

Future<Map<String, String?>> _itemFolders(_Kind kind) async {
  if (kind == _Kind.identity) {
    return {
      for (final identity in await Get.find<IdentityRepository>().getAll())
        identity.id: identity.folderId,
    };
  }
  final repository = kind == _Kind.gateway
      ? Get.find<GatewayFolderController>().hostRepository
      : Get.find<HostRepository>();
  return {for (final host in await repository.getAll()) host.id: host.folderId};
}

class _Fixture {
  _Fixture(this.kind);

  final _Kind kind;
  TreeFolderController get folders => _folders(kind);
  late Folder parent;
  late Folder target;
  late Folder child;
  late Folder grandchild;
  late Folder sibling;
  late _Item direct;
  late _Item nested;
  late _Item outside;

  Future<void> seed() async {
    parent = await folders.create(name: '上级目录');
    target = await folders.create(name: '待删除目录', parentId: parent.id);
    child = await folders.create(name: '子目录', parentId: target.id);
    grandchild = await folders.create(name: '孙目录', parentId: child.id);
    sibling = await folders.create(name: '保留目录', parentId: parent.id);
    direct = await _addItem(kind, '直接项目', target.id);
    nested = await _addItem(kind, '深层项目', grandchild.id);
    outside = await _addItem(kind, '保留项目', sibling.id);
  }

  Future<void> confirm(WidgetTester tester) => confirmDeleteFolder(
    tester.element(find.byType(ShellPage)),
    target.id,
    folderController: folders,
    containsIdentities: kind == _Kind.identity,
    containsGateways: kind == _Kind.gateway,
  );

  Future<void> removeWithContents() =>
      folders.removeWithContents(target.id, removeItems: _removeItems(kind));
}

void main() {
  tearDown(Get.reset);

  Future<void> pumpApp(WidgetTester tester, {SecretStore? secrets}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(secretStore: secrets),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
  }

  final checkbox = find.byKey(const ValueKey('delete-folder-contents'));

  for (final kind in _Kind.values) {
    testWidgets('${kind.name} 默认不勾选，删除目录后保留内容并上移', (tester) async {
      await pumpApp(tester);
      final fixture = _Fixture(kind);
      await fixture.seed();
      await tester.pumpAndSettle();
      final confirmation = fixture.confirm(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(checkbox).state,
        shadcn.CheckboxState.unchecked,
      );
      await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '删除'));
      await tester.pumpAndSettle();
      await confirmation;

      final folders = await fixture.folders.folderRepository.getAll();
      expect(
        folders.map((folder) => folder.id),
        isNot(contains(fixture.target.id)),
      );
      expect(
        folders.singleWhere((folder) => folder.id == fixture.child.id).parentId,
        fixture.parent.id,
      );
      expect(
        folders
            .singleWhere((folder) => folder.id == fixture.grandchild.id)
            .parentId,
        fixture.child.id,
      );
      expect(await _itemFolders(kind), {
        fixture.direct.id: fixture.parent.id,
        fixture.nested.id: fixture.grandchild.id,
        fixture.outside.id: fixture.sibling.id,
      });
      for (final item in [fixture.direct, fixture.nested, fixture.outside]) {
        expect(
          await Get.find<SecretStore>().read(item.secretRef),
          'test-secret',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} 勾选可取消，重新打开默认不勾选，确认后删除完整子树及密文', (tester) async {
      await pumpApp(tester);
      final fixture = _Fixture(kind);
      await fixture.seed();
      await tester.pumpAndSettle();
      final cancelled = fixture.confirm(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('同时删除文件夹下的全部内容'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(checkbox).state,
        shadcn.CheckboxState.checked,
      );
      await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消'));
      await tester.pumpAndSettle();
      await cancelled;
      expect(await fixture.folders.folderRepository.getAll(), hasLength(5));
      expect(await _itemFolders(kind), hasLength(3));

      final confirmation = fixture.confirm(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(checkbox).state,
        shadcn.CheckboxState.unchecked,
      );
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(find.textContaining('此操作无法撤销'), findsOneWidget);
      await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '删除'));
      await tester.pumpAndSettle();
      await confirmation;

      expect(
        (await fixture.folders.folderRepository.getAll()).map(
          (folder) => folder.id,
        ),
        unorderedEquals([fixture.parent.id, fixture.sibling.id]),
      );
      expect(await _itemFolders(kind), {
        fixture.outside.id: fixture.sibling.id,
      });
      for (final item in [fixture.direct, fixture.nested]) {
        expect(await Get.find<SecretStore>().read(item.secretRef), isNull);
      }
      expect(
        await Get.find<SecretStore>().read(fixture.outside.secretRef),
        'test-secret',
      );
      expect(fixture.folders.expanded, isNot(contains(fixture.target.id)));
      expect(fixture.folders.expanded, isNot(contains(fixture.child.id)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} 钥匙串删除失败时保留目录和项目，可重试递归删除', (tester) async {
      final secrets = _FailingSecrets();
      await pumpApp(tester, secrets: secrets);
      final fixture = _Fixture(kind);
      await fixture.seed();
      secrets.failDelete = true;
      await expectLater(
        fixture.removeWithContents(),
        throwsA(isA<SecretStoreException>()),
      );
      expect(await fixture.folders.folderRepository.getAll(), hasLength(5));
      expect(await _itemFolders(kind), hasLength(3));
      expect(await secrets.read(fixture.direct.secretRef), 'test-secret');
      expect(await secrets.read(fixture.nested.secretRef), 'test-secret');

      secrets.failDelete = false;
      await fixture.removeWithContents();
      expect(await _itemFolders(kind), {
        fixture.outside.id: fixture.sibling.id,
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in [_Kind.identity, _Kind.gateway]) {
    testWidgets('${kind.name} 深层项目被服务引用时整组拒删，前面的项目和密文也保留', (tester) async {
      await pumpApp(tester);
      final fixture = _Fixture(kind);
      await fixture.seed();
      await Get.find<HostRepository>().upsert(
        Host(
          id: 'referencing-service',
          name: '引用服务',
          hostname: 'service.test',
          identityId: kind == _Kind.identity ? fixture.nested.id : null,
          gatewayId: kind == _Kind.gateway ? fixture.nested.id : null,
        ),
      );
      await expectLater(
        fixture.removeWithContents(),
        kind == _Kind.identity
            ? throwsStateError
            : throwsA(isA<SshEngineException>()),
      );
      expect(await fixture.folders.folderRepository.getAll(), hasLength(5));
      expect(await _itemFolders(kind), hasLength(3));
      expect(
        await Get.find<SecretStore>().read(fixture.direct.secretRef),
        'test-secret',
      );
      expect(
        await Get.find<SecretStore>().read(fixture.nested.secretRef),
        'test-secret',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('凭证递归删除保留目录外共享的密文，并清理目录内不再共享的密文', (tester) async {
    await pumpApp(tester);
    final fixture = _Fixture(_Kind.identity);
    await fixture.seed();
    final repository = Get.find<IdentityRepository>();
    final identities = await repository.getAll();
    final outside = identities.singleWhere(
      (item) => item.id == fixture.outside.id,
    );
    final nested = identities.singleWhere(
      (item) => item.id == fixture.nested.id,
    );
    await repository.upsert(
      outside.copyWith(secretRef: fixture.direct.secretRef),
    );
    await repository.upsert(
      Identity(
        id: 'shared-inside',
        name: '内部共享凭证',
        folderId: fixture.child.id,
        username: nested.username,
        authType: nested.authType,
        secretRef: nested.secretRef,
      ),
    );

    await fixture.removeWithContents();
    expect(await _itemFolders(_Kind.identity), {
      outside.id: fixture.sibling.id,
    });
    expect(
      await Get.find<SecretStore>().read(fixture.direct.secretRef),
      'test-secret',
    );
    expect(
      await Get.find<SecretStore>().read(fixture.nested.secretRef),
      isNull,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
