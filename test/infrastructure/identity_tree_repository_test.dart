import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/entities/identity_tree_item.dart';
import 'package:pagashell/domain/repositories/identity_folder_repository.dart';
import 'package:pagashell/domain/repositories/identity_repository.dart';
import 'package:pagashell/domain/repositories/identity_tree_repository.dart';
import 'package:pagashell/domain/services/identity_tree.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_folder_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_folder_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

Identity _identity(String id, {String? name, String? parent}) => Identity(
  id: id,
  name: name ?? id,
  username: 'root',
  authType: AuthType.password,
  secretRef: 'sec-$id',
  folderId: parent,
);

class _Store {
  _Store(this.folders, this.identities, this.tree, this.close);
  factory _Store.memory() {
    final folders = InMemoryIdentityFolderRepository();
    final identities = InMemoryIdentityRepository();
    return _Store(
      folders,
      identities,
      InMemoryIdentityTreeRepository(folders: folders, identities: identities),
      () async {
        folders.dispose();
        identities.dispose();
      },
    );
  }
  factory _Store.sqlite() =>
      _Store.database(AppDatabase.forTesting(NativeDatabase.memory()));
  factory _Store.database(AppDatabase db) => _Store(
    DriftIdentityFolderRepository(db),
    DriftIdentityRepository(db),
    DriftIdentityTreeRepository(db),
    db.close,
  );
  final IdentityFolderRepository folders;
  final IdentityRepository identities;
  final IdentityTreeRepository tree;
  final Future<void> Function() close;
  Future<IdentityTreeSnapshot> snapshot() async => IdentityTreeSnapshot(
    folders: await folders.getAll(),
    identities: await identities.getAll(),
  );
  Future<List<String>> ids([String? parent]) async => (await snapshot())
      .childrenOf(parent)
      .map((node) => node.item.id)
      .toList();
}

void main() {
  for (final (name, open) in [
    ('内存', _Store.memory),
    ('SQLite', _Store.sqlite),
  ]) {
    group('$name 凭证树', () {
      late _Store store;
      setUp(() => store = open());
      tearDown(() => store.close());

      test('新增混合项追加，边缘排序后编辑保持位置和密文引用', () async {
        final first = _identity('z');
        await store.tree.saveIdentity(first);
        await store.tree.saveFolder(const Folder(id: 'f', name: 'F'));
        await store.tree.saveIdentity(_identity('a'));
        expect(await store.ids(), ['z', 'f', 'a']);
        await store.tree.move(
          const IdentityTreeItem.identity('a'),
          const IdentityTreePlacement(
            parentId: null,
            anchor: IdentityTreeItem.identity('z'),
          ),
        );
        await store.tree.move(
          const IdentityTreeItem.folder('f'),
          const IdentityTreePlacement(
            parentId: null,
            anchor: IdentityTreeItem.identity('a'),
            after: true,
          ),
        );
        await store.tree.saveIdentity(first.copyWith(name: 'edited'));
        expect(await store.ids(), ['a', 'f', 'z']);
        expect(
          (await store.identities.getAll())
              .firstWhere((i) => i.id == 'z')
              .secretRef,
          first.secretRef,
        );
        await store.tree.saveIdentity(_identity('new'));
        expect(await store.ids(), ['a', 'f', 'z', 'new']);
      });

      test('跨级移动文件夹保留子树，拒绝循环、无效落点和重名', () async {
        await store.tree.saveFolder(const Folder(id: 'source', name: 'Source'));
        await store.tree.saveFolder(
          const Folder(id: 'sub', name: 'Sub', parentId: 'source'),
        );
        await store.tree.saveIdentity(_identity('leaf', parent: 'sub'));
        await store.tree.saveFolder(const Folder(id: 'target', name: 'Target'));
        await store.tree.saveIdentity(
          _identity('taken', name: 'leaf', parent: 'target'),
        );
        await store.tree.move(
          const IdentityTreeItem.folder('source'),
          const IdentityTreePlacement(parentId: 'target'),
        );
        expect(await store.ids('target'), ['taken', 'source']);
        expect(await store.ids('source'), ['sub']);
        expect(await store.ids('sub'), ['leaf']);
        for (final parent in ['source', 'sub', 'missing']) {
          await expectLater(
            store.tree.move(
              const IdentityTreeItem.folder('source'),
              IdentityTreePlacement(parentId: parent),
            ),
            throwsArgumentError,
          );
        }
        await expectLater(
          store.tree.move(
            const IdentityTreeItem.identity('leaf'),
            const IdentityTreePlacement(parentId: 'target'),
          ),
          throwsArgumentError,
        );
        await store.tree.move(
          const IdentityTreeItem.folder('source'),
          const IdentityTreePlacement(parentId: null),
        );
        expect(await store.ids(), ['target', 'source']);
        expect(await store.ids('sub'), ['leaf']);
      });

      test('删除文件夹上移混合内容、处理重名并保留实际密文和引用', () async {
        final secrets = InMemorySecretStore();
        await secrets.put('sec-child', 'unchanged-password');
        await store.tree.saveIdentity(_identity('existing', name: 'Dup'));
        await store.tree.saveFolder(const Folder(id: 'same', name: 'Dup'));
        await store.tree.saveFolder(const Folder(id: 'remove', name: 'Remove'));
        await store.tree.saveIdentity(
          _identity('child', name: 'Dup', parent: 'remove'),
        );
        await store.tree.saveFolder(
          const Folder(id: 'child-folder', name: 'Dup', parentId: 'remove'),
        );
        await store.tree.saveIdentity(
          _identity('nested', parent: 'child-folder'),
        );
        await store.tree.removeFolder('remove');
        expect(await store.ids(), [
          'existing',
          'same',
          'child',
          'child-folder',
        ]);
        expect((await store.snapshot()).childrenOf(null).map((n) => n.name), [
          'Dup',
          'Dup',
          'Dup (2)',
          'Dup (2)',
        ]);
        expect(await store.ids('child-folder'), ['nested']);
        final child = (await store.identities.getAll()).firstWhere(
          (i) => i.id == 'child',
        );
        expect(child.secretRef, 'sec-child');
        expect(await secrets.read(child.secretRef!), 'unchanged-password');
      });

      test('并发新增仍使用连续唯一顺序', () async {
        await Future.wait<void>([
          for (var i = 0; i < 10; i++)
            if (i.isEven)
              store.tree.saveIdentity(_identity('i$i'))
            else
              store.tree
                  .saveFolder(Folder(id: 'f$i', name: 'F$i'))
                  .then((_) {}),
        ]);
        expect(
          (await store.snapshot()).childrenOf(null).map((n) => n.sortOrder),
          List.generate(10, (i) => i),
        );
      });

      test('控制器编辑保留嵌套和顺序，失败后恢复密码', () async {
        await store.tree.saveFolder(const Folder(id: 'f', name: 'F'));
        final secrets = InMemorySecretStore();
        final controller = IdentityController(
          repository: store.identities,
          secretStore: secrets,
          treeRepository: store.tree,
        );
        controller.onInit();
        addTearDown(controller.onClose);
        final created = await controller.saveWithPassword(
          name: 'first',
          username: 'root',
          password: 'original',
          folderId: 'f',
        );
        await controller.saveWithPassword(
          name: 'second',
          username: 'user',
          password: 'another',
          folderId: 'f',
        );
        await Future<void>.delayed(Duration.zero);
        await controller.updateIdentity(
          id: created.id,
          name: 'renamed',
          username: 'changed',
        );
        await Future<void>.delayed(Duration.zero);
        final edited = controller.byId(created.id)!;
        expect(edited.folderId, 'f');
        expect(edited.sortOrder, 0);
        expect(await controller.passwordOf(edited), 'original');
        await expectLater(
          controller.updateIdentity(
            id: created.id,
            name: 'second',
            username: 'changed',
            password: 'replacement',
          ),
          throwsArgumentError,
        );
        expect(await controller.passwordOf(edited), 'original');
      });
    });
  }

  test('SQLite 主机与凭证文件夹独立，重开后恢复层级和顺序', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-identity-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final store = _Store.database(db);
    await DriftFolderRepository(db)
        .upsert(const Folder(id: 'f', name: 'Host folder'));
    await store.tree.saveFolder(
      const Folder(id: 'f', name: 'Credential folder'),
    );
    await store.tree.saveIdentity(_identity('one'));
    await store.tree.saveIdentity(_identity('two'));
    await store.tree.move(
      const IdentityTreeItem.identity('two'),
      const IdentityTreePlacement(parentId: 'f'),
    );
    expect(
      (await DriftFolderRepository(db).getAll()).single.name,
      'Host folder',
    );
    await store.close();
    final reopenedDb = AppDatabase.forTesting(NativeDatabase(file));
    final reopened = _Store.database(reopenedDb);
    addTearDown(reopened.close);
    expect(await reopened.ids(), ['f', 'one']);
    expect(await reopened.ids('f'), ['two']);
    expect(
      (await reopened.identities.getAll())
          .firstWhere((i) => i.id == 'two')
          .secretRef,
      'sec-two',
    );
    await reopened.tree.saveIdentity(_identity('last'));
    expect(await reopened.ids(), ['f', 'one', 'last']);
  });

  test('版本 3 升级保留凭证认证信息，新增文件夹后旧凭证可移动', () async {
    final dir = await Directory.systemTemp.createTemp(
      'pagashell-identity-migration-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/old.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftIdentityRepository(old).upsert(
      const Identity(
        id: 'saved',
        name: 'Saved',
        username: 'user',
        authType: AuthType.privateKey,
        secretRef: 'vault-ref',
      ),
    );
    await old.customStatement('DROP TABLE identity_folders');
    await old.customStatement('ALTER TABLE identities DROP COLUMN folder_id');
    await old.customStatement('ALTER TABLE identities DROP COLUMN sort_order');
    await old.customStatement('ALTER TABLE folders DROP COLUMN is_gateway');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN is_gateway');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN forward_ports_json',
    );
    await old.customStatement('DROP TABLE IF EXISTS forward_folders');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_type');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN rdp_domain');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN page_client_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN page_server_fingerprint',
    );
    await old.customStatement(
      'ALTER TABLE identities DROP COLUMN service_type',
    );
    await old.customStatement('PRAGMA user_version = 3');
    await old.close();
    final upgraded = _Store.database(
      AppDatabase.forTesting(NativeDatabase(file)),
    );
    addTearDown(upgraded.close);
    final saved = (await upgraded.identities.getAll()).single;
    expect(saved.folderId, isNull);
    expect(saved.sortOrder, 0);
    expect(saved.username, 'user');
    expect(saved.authType, AuthType.privateKey);
    expect(saved.secretRef, 'vault-ref');
    await upgraded.tree.saveFolder(const Folder(id: 'f', name: 'Folder'));
    expect(await upgraded.ids(), ['saved', 'f']);
    await upgraded.tree.move(
      const IdentityTreeItem.identity('saved'),
      const IdentityTreePlacement(parentId: 'f'),
    );
    expect(await upgraded.ids('f'), ['saved']);
  });

  test('SQLite 重排写入失败回滚全部顺序', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = _Store.database(db);
    addTearDown(store.close);
    await store.tree.saveFolder(const Folder(id: 'a', name: 'A'));
    await store.tree.saveIdentity(_identity('one'));
    await store.tree.saveFolder(const Folder(id: 'b', name: 'B'));
    await db.customStatement(
      "CREATE TRIGGER reject_identity_update BEFORE UPDATE ON identities BEGIN SELECT RAISE(ABORT, 'test-write-failure'); END",
    );
    const placement = IdentityTreePlacement(
      parentId: null,
      anchor: IdentityTreeItem.folder('a'),
    );
    await expectLater(
      store.tree.move(const IdentityTreeItem.folder('b'), placement),
      throwsA(isA<Exception>()),
    );
    expect(await store.ids(), ['a', 'one', 'b']);
    expect((await store.snapshot()).childrenOf(null).map((n) => n.sortOrder), [
      0,
      1,
      2,
    ]);
    await db.customStatement('DROP TRIGGER reject_identity_update');
    await store.tree.move(const IdentityTreeItem.folder('b'), placement);
    expect(await store.ids(), ['b', 'a', 'one']);
  });
}
