import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/domain/repositories/folder_repository.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/repositories/host_tree_repository.dart';
import 'package:pagashell/domain/services/host_tree.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_folder_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';

Host _host(String id, {String? name, String? parent}) => Host(
  id: id,
  name: name ?? id,
  hostname: '$id.example.test',
  folderId: parent,
);

class _TreeStore {
  _TreeStore(this.folders, this.hosts, this.tree, this.close);

  factory _TreeStore.memory() {
    final folders = InMemoryFolderRepository();
    final hosts = InMemoryHostRepository();
    return _TreeStore(
      folders,
      hosts,
      InMemoryHostTreeRepository(folders: folders, hosts: hosts),
      () async {
        folders.dispose();
        hosts.dispose();
      },
    );
  }

  factory _TreeStore.sqlite() =>
      _TreeStore.database(AppDatabase.forTesting(NativeDatabase.memory()));

  factory _TreeStore.database(AppDatabase db) => _TreeStore(
    DriftFolderRepository(db),
    DriftHostRepository(db),
    DriftHostTreeRepository(db),
    db.close,
  );

  final FolderRepository folders;
  final HostRepository hosts;
  final HostTreeRepository tree;
  final Future<void> Function() close;

  Future<HostTreeSnapshot> snapshot() async => HostTreeSnapshot(
    folders: await folders.getAll(),
    hosts: await hosts.getAll(),
  );

  Future<List<String>> ids([String? parent]) async => (await snapshot())
      .childrenOf(parent)
      .map((node) => node.item.id)
      .toList();
}

void main() {
  for (final (name, open) in [
    ('内存', _TreeStore.memory),
    ('SQLite', _TreeStore.sqlite),
  ]) {
    group('$name 主机树', () {
      late _TreeStore store;
      setUp(() => store = open());
      tearDown(() => store.close());

      test('新文件夹与主机按创建顺序追加到同级末尾', () async {
        await store.tree.saveHost(_host('zh', name: 'Z'));
        await store.tree.saveFolder(const Folder(id: 'zf', name: 'Z'));
        await store.tree.saveHost(_host('ah', name: 'A'));
        await store.tree.saveFolder(const Folder(id: 'af', name: 'A'));
        expect(await store.ids(), ['zh', 'zf', 'ah', 'af']);
        expect(
          (await store.snapshot())
              .childrenOf(null)
              .map((node) => node.sortOrder),
          [0, 1, 2, 3],
        );
        await store.tree.saveHost(_host('child', parent: 'zf'));
        await store.tree.saveFolder(
          const Folder(id: 'sub', name: 'A', parentId: 'zf'),
        );
        expect(await store.ids('zf'), ['child', 'sub']);
      });

      test('编辑使用当前保存的位置，忽略调用方过期的顺序', () async {
        final first = _host('h1');
        const folder = Folder(id: 'f1', name: 'F');
        await store.tree.saveHost(first);
        await store.tree.saveFolder(folder);
        await store.tree.saveHost(_host('h2'));
        await store.tree.move(
          const HostTreeItem.folder('f1'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.host('h1'),
          ),
        );
        await store.tree.saveHost(first.copyWith(name: 'A', note: 'updated'));
        final saved = await store.tree.saveFolder(folder.copyWith(name: 'Z'));
        expect(saved.sortOrder, 0);
        expect(await store.ids(), ['f1', 'h1', 'h2']);
        expect(
          (await store.hosts.getAll())
              .firstWhere((host) => host.id == 'h1')
              .note,
          'updated',
        );
        await store.tree.saveHost(_host('h3'));
        expect(await store.ids(), ['f1', 'h1', 'h2', 'h3']);
      });

      test('文件夹与主机可互相插入前后位置', () async {
        await store.tree.saveFolder(const Folder(id: 'a', name: 'A'));
        await store.tree.saveHost(_host('h1'));
        await store.tree.saveFolder(const Folder(id: 'b', name: 'B'));
        await store.tree.saveHost(_host('h2'));
        await store.tree.move(
          const HostTreeItem.host('h2'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('a'),
          ),
        );
        expect(await store.ids(), ['h2', 'a', 'h1', 'b']);
        await store.tree.move(
          const HostTreeItem.folder('b'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.host('h1'),
          ),
        );
        expect(await store.ids(), ['h2', 'a', 'b', 'h1']);
        await store.tree.move(
          const HostTreeItem.host('h2'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('b'),
            after: true,
          ),
        );
        expect(await store.ids(), ['a', 'b', 'h2', 'h1']);
        await store.tree.move(
          const HostTreeItem.folder('a'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.host('h2'),
            after: true,
          ),
        );
        expect(await store.ids(), ['b', 'h2', 'a', 'h1']);
        expect(
          (await store.snapshot())
              .childrenOf(null)
              .map((node) => node.sortOrder),
          [0, 1, 2, 3],
        );
      });

      test('跨级移动追加或插入，文件夹保留所有后代', () async {
        await store.tree.saveFolder(const Folder(id: 't', name: 'Target'));
        await store.tree.saveFolder(const Folder(id: 'f', name: 'Source'));
        await store.tree.saveFolder(
          const Folder(id: 'sub', name: 'Nested', parentId: 'f'),
        );
        await store.tree.saveHost(_host('leaf', parent: 'sub'));
        await store.tree.saveHost(_host('existing', parent: 't'));
        await store.tree.saveHost(_host('root'));
        await store.tree.move(
          const HostTreeItem.folder('f'),
          const HostTreePlacement(parentId: 't'),
        );
        expect(await store.ids('t'), ['existing', 'f']);
        expect(await store.ids('f'), ['sub']);
        expect(await store.ids('sub'), ['leaf']);
        await store.tree.move(
          const HostTreeItem.host('root'),
          const HostTreePlacement(
            parentId: 't',
            anchor: HostTreeItem.folder('f'),
          ),
        );
        expect(await store.ids('t'), ['existing', 'root', 'f']);
        await store.tree.move(
          const HostTreeItem.folder('f'),
          const HostTreePlacement(parentId: null),
        );
        expect(await store.ids(), ['t', 'f']);
        expect(await store.ids('sub'), ['leaf']);
      });

      test('拒绝自身、后代、无效位置和同级重名，失败后仍可写入', () async {
        await store.tree.saveFolder(const Folder(id: 'f', name: 'Same'));
        await store.tree.saveFolder(
          const Folder(id: 'sub', name: 'Sub', parentId: 'f'),
        );
        await store.tree.saveFolder(const Folder(id: 't', name: 'Target'));
        await store.tree.saveFolder(
          const Folder(id: 'same', name: 'Same', parentId: 't'),
        );
        await store.tree.saveHost(_host('h1', name: 'Repeat'));
        await store.tree.saveHost(_host('h2', name: 'Repeat', parent: 't'));
        final original = await store.ids();
        for (final placement in [
          const HostTreePlacement(parentId: 'f'),
          const HostTreePlacement(parentId: 'sub'),
          const HostTreePlacement(parentId: 'missing'),
          const HostTreePlacement(parentId: 't'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('sub'),
          ),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('f'),
          ),
        ]) {
          expect(
            (await store.snapshot()).canMove(
              const HostTreeItem.folder('f'),
              placement,
            ),
            isFalse,
          );
          await expectLater(
            store.tree.move(const HostTreeItem.folder('f'), placement),
            throwsArgumentError,
          );
        }
        await expectLater(
          store.tree.move(
            const HostTreeItem.host('h1'),
            const HostTreePlacement(parentId: 't'),
          ),
          throwsArgumentError,
        );
        await expectLater(
          store.tree.saveHost(_host('invalid', parent: 'missing')),
          throwsArgumentError,
        );
        expect(await store.ids(), original);
        await store.tree.saveHost(_host('valid'));
        expect(await store.ids(), [...original, 'valid']);
      });

      test('删除文件夹将混合内容按原顺序放到父级末尾并处理重名', () async {
        await store.tree.saveHost(_host('existing-host', name: 'Dup'));
        await store.tree.saveFolder(
          const Folder(id: 'existing-folder', name: 'Dup'),
        );
        await store.tree.saveFolder(const Folder(id: 'remove', name: 'Remove'));
        await store.tree.saveHost(
          _host('promoted-host', name: 'Dup', parent: 'remove'),
        );
        await store.tree.saveFolder(
          const Folder(id: 'promoted-folder', name: 'Dup', parentId: 'remove'),
        );
        await store.tree.saveHost(_host('last', parent: 'remove'));
        await store.tree.removeFolder('remove');
        expect(await store.ids(), [
          'existing-host',
          'existing-folder',
          'promoted-host',
          'promoted-folder',
          'last',
        ]);
        expect(
          (await store.snapshot()).childrenOf(null).map((node) => node.name),
          ['Dup', 'Dup', 'Dup (2)', 'Dup (2)', 'last'],
        );
        expect(await store.ids('remove'), isEmpty);
      });

      test('并发新建文件夹和主机获得互不重复的末尾位置', () async {
        await Future.wait<void>([
          for (var index = 0; index < 12; index++)
            if (index.isEven)
              store.tree.saveHost(_host('h$index'))
            else
              store.tree
                  .saveFolder(Folder(id: 'f$index', name: 'F$index'))
                  .then((_) {}),
        ]);
        final orders = (await store.snapshot())
            .childrenOf(null)
            .map((node) => node.sortOrder)
            .toList();
        expect(orders, List.generate(12, (index) => index));
      });

      test('旧数据相同顺序沿用旧展示，重排后新建仍追加', () async {
        await store.folders.upsert(const Folder(id: 'fb', name: 'B'));
        await store.folders.upsert(const Folder(id: 'fa', name: 'A'));
        await store.hosts.upsert(_host('hb', name: 'B'));
        await store.hosts.upsert(_host('ha', name: 'A'));
        expect(await store.ids(), ['fa', 'fb', 'ha', 'hb']);
        await store.tree.move(
          const HostTreeItem.host('ha'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('fa'),
          ),
        );
        await store.tree.saveHost(_host('new', name: '0'));
        expect(await store.ids(), ['ha', 'fa', 'fb', 'hb', 'new']);
      });
    });
  }

  test('SQLite 关闭重开后恢复混合顺序、层级与后代，新增仍追加', () async {
    final directory = await Directory.systemTemp.createTemp('pagashell-tree-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final first = _TreeStore.database(
      AppDatabase.forTesting(NativeDatabase(file)),
    );
    await first.tree.saveFolder(const Folder(id: 'a', name: 'A'));
    await first.tree.saveHost(_host('root'));
    await first.tree.saveFolder(
      const Folder(id: 'b', name: 'B', parentId: 'a'),
    );
    await first.tree.saveHost(_host('leaf', parent: 'b'));
    await first.tree.move(
      const HostTreeItem.folder('b'),
      const HostTreePlacement(parentId: null, anchor: HostTreeItem.folder('a')),
    );
    await first.tree.move(
      const HostTreeItem.host('root'),
      const HostTreePlacement(parentId: 'b'),
    );
    await first.tree.move(
      const HostTreeItem.folder('a'),
      const HostTreePlacement(parentId: null, anchor: HostTreeItem.folder('b')),
    );
    await first.close();

    final reopened = _TreeStore.database(
      AppDatabase.forTesting(NativeDatabase(file)),
    );
    addTearDown(reopened.close);
    expect(await reopened.ids(), ['a', 'b']);
    expect(await reopened.ids('b'), ['leaf', 'root']);
    await reopened.tree.saveFolder(const Folder(id: 'z', name: '0'));
    expect(await reopened.ids(), ['a', 'b', 'z']);
  });

  test('SQLite 重排中主机写入失败时回滚已经写入的文件夹顺序', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = _TreeStore.database(db);
    addTearDown(store.close);
    await store.tree.saveFolder(const Folder(id: 'a', name: 'A'));
    await store.tree.saveHost(_host('h1'));
    await store.tree.saveFolder(const Folder(id: 'b', name: 'B'));
    await store.tree.saveHost(_host('h2'));
    await db.customStatement('''
      CREATE TRIGGER reject_host_update BEFORE UPDATE ON hosts
      BEGIN SELECT RAISE(ABORT, 'test-write-failure'); END
    ''');
    const placement = HostTreePlacement(
      parentId: null,
      anchor: HostTreeItem.folder('a'),
    );
    await expectLater(
      store.tree.move(const HostTreeItem.folder('b'), placement),
      throwsA(isA<Exception>()),
    );
    expect(await store.ids(), ['a', 'h1', 'b', 'h2']);
    expect(
      (await store.snapshot()).childrenOf(null).map((node) => node.sortOrder),
      [0, 1, 2, 3],
    );
    await db.customStatement('DROP TRIGGER reject_host_update');
    await store.tree.move(const HostTreeItem.folder('b'), placement);
    expect(await store.ids(), ['b', 'a', 'h1', 'h2']);
  });
}
