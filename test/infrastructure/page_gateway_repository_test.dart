import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';

void main() {
  test('Page 配置与 SSH/RDP 服务引用在数据库重开后保留，被引用时不可删除', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-page-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostTreeRepository(db, gateways: true).saveHost(
      Host(
        id: 'page',
        name: 'Page',
        hostname: 'relay.test',
        port: 7443,
        gatewayType: GatewayType.page,
        pageClientId: 'office',
        pageServerFingerprint: 'ab' * 32,
      ),
    );
    for (final type in ServiceType.values) {
      await DriftHostRepository(db).upsert(
        Host(
          id: type.name,
          name: type.name,
          hostname: 'internal.test',
          serviceType: type,
          gatewayId: 'page',
        ),
      );
    }
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final gateways = DriftHostRepository(reopened, gateways: true);
    final page = (await gateways.getAll()).single;
    expect(page.gatewayType, GatewayType.page);
    expect(page.pageClientId, 'office');
    expect(page.pageServerFingerprint, 'ab' * 32);
    expect(
      (await DriftHostRepository(reopened).getAll()).map((h) => h.gatewayId),
      everyElement('page'),
    );
    await expectLater(gateways.remove('page'), throwsStateError);
  });

  test('schema 9 升级到 10 保留 SSH 网关和绑定，新配置字段为空', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-page-v9-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(
      db,
      gateways: true,
    ).upsert(const Host(id: 'ssh', name: 'SSH', hostname: 'jump.test'));
    await DriftHostRepository(db).upsert(
      const Host(
        id: 'target',
        name: 'Desktop',
        hostname: 'internal.test',
        serviceType: ServiceType.rdp,
        rdpDomain: 'CORP',
        gatewayId: 'ssh',
      ),
    );
    await db.customStatement('ALTER TABLE hosts DROP COLUMN page_client_id');
    await db.customStatement(
      'ALTER TABLE hosts DROP COLUMN page_server_fingerprint',
    );
    await db.customStatement('ALTER TABLE identities DROP COLUMN service_type');
    await db.customStatement('PRAGMA user_version = 9');
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final ssh = (await DriftHostRepository(
      reopened,
      gateways: true,
    ).getAll()).single;
    expect(ssh.gatewayType, GatewayType.ssh);
    expect(ssh.pageClientId, isEmpty);
    final target = (await DriftHostRepository(reopened).getAll()).single;
    expect(target.gatewayId, 'ssh');
    expect(target.serviceType, ServiceType.rdp);
    expect(target.rdpDomain, 'CORP');
  });
}
