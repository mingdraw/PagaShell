import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/repositories/host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';

const _ports = [
  ForwardPort(localPort: 13306, targetPort: 3306),
  ForwardPort(localPort: 16379, targetPort: 6379),
];
const _service = Host(id: 'service', name: 'Database', hostname: 'db.test');

class _Store {
  _Store(this.hosts, this.tree, this.close);

  factory _Store.memory() {
    final hosts = InMemoryHostRepository();
    final folders = InMemoryFolderRepository();
    return _Store(
      hosts,
      InMemoryHostTreeRepository(hosts: hosts, folders: folders),
      () async {
        hosts.dispose();
        folders.dispose();
      },
    );
  }

  factory _Store.sqlite() =>
      _Store.database(AppDatabase.forTesting(NativeDatabase.memory()));
  factory _Store.database(AppDatabase db) =>
      _Store(DriftHostRepository(db), DriftHostTreeRepository(db), db.close);

  final HostRepository hosts;
  final HostTreeRepository tree;
  final Future<void> Function() close;
  Future<Host> get service async => (await hosts.getAll()).single;
}

void main() {
  for (final (name, open) in [
    ('内存', _Store.memory),
    ('SQLite', _Store.sqlite),
  ]) {
    group('$name 服务端口映射', () {
      late _Store store;
      setUp(() async {
        store = open();
        await store.tree.saveHost(_service);
      });
      tearDown(() => store.close());

      test('保存多组映射只更新最新服务记录中的映射字段', () async {
        await store.tree.saveFolder(
          const Folder(id: 'folder', name: 'Production'),
        );
        await store.tree.saveHost(
          _service.copyWith(
            hostname: 'updated.test',
            port: 2222,
            username: 'operator',
            note: 'Updated note',
            identityId: 'identity',
            tags: ['production'],
            colorValue: 0xff112233,
          ),
        );
        await store.tree.move(
          const HostTreeItem.host('service'),
          const HostTreePlacement(parentId: 'folder'),
        );
        final saved = await store.tree.saveForwardPorts('service', _ports);
        expect(saved.forwardPorts, _ports);
        expect(saved.hostname, 'updated.test');
        expect(saved.port, 2222);
        expect(saved.username, 'operator');
        expect(saved.note, 'Updated note');
        expect(saved.identityId, 'identity');
        expect(saved.tags, ['production']);
        expect(saved.colorValue, 0xff112233);
        expect(saved.folderId, 'folder');
        expect((await store.service).forwardPorts, _ports);
        expect(
          () => saved.forwardPorts.add(_ports.first),
          throwsUnsupportedError,
        );
      });

      test('编辑、移动、重排及删除文件夹后保留映射', () async {
        await store.tree.saveForwardPorts('service', _ports);
        await store.tree.saveFolder(const Folder(id: 'outer', name: 'Outer'));
        await store.tree.saveFolder(
          const Folder(id: 'inner', name: 'Inner', parentId: 'outer'),
        );
        await store.tree.move(
          const HostTreeItem.host('service'),
          const HostTreePlacement(parentId: 'inner'),
        );
        await store.tree.move(
          const HostTreeItem.folder('inner'),
          const HostTreePlacement(
            parentId: null,
            anchor: HostTreeItem.folder('outer'),
          ),
        );
        final edited = (await store.service).copyWith(
          name: 'Renamed',
          note: 'Edited',
        );
        await store.tree.saveHost(edited);
        await store.tree.removeFolder('inner');
        final saved = await store.service;
        expect(saved.forwardPorts, _ports);
        expect(saved.folderId, isNull);
        expect(saved.name, 'Renamed');
        expect(saved.note, 'Edited');
        expect(edited.copyWith(hostname: 'copy.test').forwardPorts, _ports);
      });

      test('允许清空配置，拒绝重复本地端口及越界端口且保留已存值', () async {
        await store.tree.saveForwardPorts('service', _ports);
        for (final invalid in [
          [const ForwardPort(localPort: 0, targetPort: 3306)],
          [const ForwardPort(localPort: 65536, targetPort: 3306)],
          [const ForwardPort(localPort: 13306, targetPort: 65536)],
          [const ForwardPort(localPort: 13306, targetPort: 0)],
          [_ports.first, const ForwardPort(localPort: 13306, targetPort: 6379)],
        ]) {
          await expectLater(
            store.tree.saveForwardPorts('service', invalid),
            throwsStateError,
          );
          expect((await store.service).forwardPorts, _ports);
        }
        await store.tree.saveForwardPorts('service', []);
        expect((await store.service).forwardPorts, isEmpty);
      });

      test('删除服务后映射一并移除，无法保存到不存在的服务', () async {
        await store.tree.saveForwardPorts('service', _ports);
        await store.hosts.remove('service');
        await expectLater(
          store.tree.saveForwardPorts('service', _ports),
          throwsStateError,
        );
        expect(await store.hosts.getAll(), isEmpty);
        await store.tree.saveHost(_service);
        expect((await store.service).forwardPorts, isEmpty);
      });
    });
  }

  test('SQLite 关闭重开保留映射和网关引用，不创建独立转发表', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-service-ports-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(
      db,
      gateways: true,
    ).upsert(const Host(id: 'gateway', name: 'Jump', hostname: 'jump.test'));
    await DriftHostTreeRepository(db)
        .saveHost(_service.copyWith(gatewayId: 'gateway'));
    await DriftHostTreeRepository(db).saveForwardPorts('service', _ports);
    await db.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final saved = (await DriftHostRepository(reopened).getAll()).single;
    expect(saved.gatewayId, 'gateway');
    expect(saved.forwardPorts, _ports);
    final tables = await reopened
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    expect(
      tables.map((row) => row.read<String>('name')),
      isNot(contains('forward_rules')),
    );
    expect(
      tables.map((row) => row.read<String>('name')),
      isNot(contains('forward_folders')),
    );
  });

  test('旧版数据库仅补充空映射字段并清理停用表，保留其他服务配置', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-service-schema-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(
      old,
      gateways: true,
    ).upsert(const Host(id: 'gateway', name: 'Jump', hostname: 'jump.test'));
    await DriftHostTreeRepository(old)
        .saveHost(_service.copyWith(gatewayId: 'gateway', note: 'Preserved'));
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN forward_ports_json',
    );
    await old.customStatement(
      'CREATE TABLE forward_rules (id TEXT PRIMARY KEY)',
    );
    await old.customStatement(
      'CREATE TABLE forward_folders (id TEXT PRIMARY KEY)',
    );
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_type');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN rdp_domain');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN page_client_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN page_server_fingerprint',
    );
    await old.customStatement(
      'ALTER TABLE identities DROP COLUMN service_type',
    );
    await old.customStatement('PRAGMA user_version = 7');
    await old.close();

    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final saved = (await DriftHostRepository(db).getAll()).single;
    expect(saved.hostname, _service.hostname);
    expect(saved.gatewayId, 'gateway');
    expect(saved.note, 'Preserved');
    expect(saved.forwardPorts, isEmpty);
    await DriftHostTreeRepository(db).saveForwardPorts('service', _ports);
    expect(
      (await DriftHostRepository(db).getAll()).single.forwardPorts,
      _ports,
    );
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name IN ('forward_rules', 'forward_folders')",
        )
        .get();
    expect(tables, isEmpty);
  });
}
