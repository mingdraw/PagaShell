import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_folder_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';

const gateway = Host(id: 'gateway', name: 'Bastion', hostname: 'gateway.test');
const service = Host(
  id: 'service',
  name: 'Bastion',
  hostname: 'internal.test',
  gatewayId: 'gateway',
);

void main() {
  test('网关与服务分组隔离，嵌套和顺序持久化，禁止跨组拖拽', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-gateway-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tree.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final tree = DriftHostTreeRepository(db, gateways: true);
    await tree.saveFolder(const Folder(id: 'outer', name: 'Outer'));
    await tree.saveFolder(
      const Folder(id: 'inner', name: 'Inner', parentId: 'outer'),
    );
    await tree.saveHost(gateway);
    await DriftHostTreeRepository(db).saveHost(service);
    await tree.move(
      const HostTreeItem.host('gateway'),
      const HostTreePlacement(parentId: 'inner'),
    );
    await tree.move(
      const HostTreeItem.folder('inner'),
      const HostTreePlacement(
        parentId: null,
        anchor: HostTreeItem.folder('outer'),
      ),
    );
    await expectLater(
      DriftHostTreeRepository(db).move(
        const HostTreeItem.host('gateway'),
        const HostTreePlacement(parentId: null),
      ),
      throwsArgumentError,
    );
    await expectLater(
      tree.move(
        const HostTreeItem.host('service'),
        const HostTreePlacement(parentId: 'outer'),
      ),
      throwsArgumentError,
    );
    await expectLater(
      tree.move(
        const HostTreeItem.folder('outer'),
        const HostTreePlacement(parentId: 'outer'),
      ),
      throwsArgumentError,
    );
    await db.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      (await DriftHostRepository(reopened).getAll()).single.gatewayId,
      gateway.id,
    );
    expect(
      (await DriftHostRepository(
        reopened,
        gateways: true,
      ).getAll()).single.folderId,
      'inner',
    );
    expect(await DriftFolderRepository(reopened).getAll(), isEmpty);
    final folders = await DriftFolderRepository(
      reopened,
      gateways: true,
    ).getAll();
    expect(folders.firstWhere((f) => f.id == 'inner').sortOrder, 0);
    expect(folders.firstWhere((f) => f.id == 'outer').sortOrder, 1);
    await DriftHostTreeRepository(
      reopened,
      gateways: true,
    ).removeFolder('inner');
    expect(
      (await DriftHostRepository(
        reopened,
        gateways: true,
      ).getAll()).single.folderId,
      isNull,
    );
    expect(
      (await DriftHostRepository(reopened).getAll()).single.gatewayId,
      gateway.id,
    );
  });

  test('被引用网关不能删除，解除绑定后可以删除，失效引用不能保存', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final gateways = DriftHostRepository(db, gateways: true);
    final services = DriftHostRepository(db);
    await gateways.upsert(gateway);
    await services.upsert(service);
    await expectLater(gateways.remove(gateway.id), throwsStateError);
    expect(await gateways.getAll(), hasLength(1));
    await services.upsert(service.copyWith(gatewayId: null));
    await gateways.remove(gateway.id);
    await expectLater(services.upsert(service), throwsStateError);
    expect((await services.getAll()).single.gatewayId, isNull);
    await expectLater(
      gateways.upsert(gateway.copyWith(gatewayId: 'service')),
      throwsArgumentError,
    );
  });

  test('版本 4 升级保留服务、目录和凭证绑定，旧服务默认直连', () async {
    final dir = await Directory.systemTemp.createTemp(
      'pagashell-gateway-migration-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/old.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftFolderRepository(old)
        .upsert(const Folder(id: 'folder', name: 'Production'));
    await DriftHostRepository(old).upsert(
      service.copyWith(
        gatewayId: null,
        folderId: 'folder',
        identityId: 'saved-identity',
      ),
    );
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
    await old.customStatement('PRAGMA user_version = 4');
    await old.close();

    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final saved = (await DriftHostRepository(db).getAll()).single;
    expect(saved.gatewayId, isNull);
    expect(saved.identityId, 'saved-identity');
    expect(saved.folderId, 'folder');
    expect(
      (await DriftFolderRepository(db).getAll()).single.name,
      'Production',
    );
    expect(await DriftHostRepository(db, gateways: true).getAll(), isEmpty);
    await DriftHostRepository(db, gateways: true).upsert(gateway);
    await DriftHostRepository(db).upsert(saved.copyWith(gatewayId: gateway.id));
    expect(
      (await DriftHostRepository(db).getAll()).single.gatewayId,
      gateway.id,
    );
  });
}
