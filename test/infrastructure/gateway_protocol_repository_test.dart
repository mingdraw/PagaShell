import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_repository.dart';
import 'package:pagashell/infrastructure/db/drift_known_host_repository.dart';

void main() {
  test('版本 9 服务协议列兼容旧 SSH，RDP 服务移动、编辑与重开数据库保留配置', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-rdp-service-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final services = DriftHostRepository(db);
    await services.upsert(
      const Host(id: 'ssh', name: 'Legacy SSH', hostname: 'linux.test'),
    );
    final tree = DriftHostTreeRepository(db);
    await tree.saveFolder(const Folder(id: 'windows', name: 'Windows'));
    await tree.saveHost(
      const Host(
        id: 'rdp-service',
        name: 'Desktop',
        hostname: 'windows.test',
        username: 'operator',
        port: 3389,
        serviceType: ServiceType.rdp,
        rdpDomain: 'CORP',
        folderId: 'windows',
      ),
    );
    await tree.removeFolder('windows');
    final saved = (await services.getAll()).firstWhere(
      (h) => h.id == 'rdp-service',
    );
    await services.upsert(saved.copyWith(name: 'Desktop edited'));
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final all = await DriftHostRepository(reopened).getAll();
    expect(all.firstWhere((h) => h.id == 'ssh').serviceType, ServiceType.ssh);
    final rdp = all.firstWhere((h) => h.id == 'rdp-service');
    expect(rdp.serviceType, ServiceType.rdp);
    expect(rdp.folderId, isNull);
    expect(rdp.port, 3389);
    expect(rdp.rdpDomain, 'CORP');
  });

  test('旧 RDP 网关停用但不清空服务绑定，重开后保留 RDP 服务并可改选 SSH 网关', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-old-gateway-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final gateways = DriftHostRepository(db, gateways: true);
    const oldGateway = Host(
      id: 'retired',
      name: 'Old gateway',
      hostname: 'old.test',
      port: 3389,
      identityId: 'gateway-credential',
    );
    final identities = DriftIdentityRepository(db);
    await identities.upsert(
      const Identity(
        id: 'gateway-credential',
        name: 'Old gateway credential',
        username: 'operator',
        authType: AuthType.password,
      ),
    );
    await gateways.upsert(oldGateway);
    expect(await identities.isReferenced('gateway-credential'), isTrue);
    await expectLater(
      identities.remove('gateway-credential'),
      throwsStateError,
    );
    await gateways.upsert(
      const Host(id: 'ssh', name: 'SSH gateway', hostname: 'jump.test'),
    );
    await expectLater(
      gateways.upsert(oldGateway.copyWith(serviceType: ServiceType.rdp)),
      throwsStateError,
    );
    await DriftHostRepository(db).upsert(
      const Host(
        id: 'service',
        name: 'Desktop',
        hostname: 'internal.test',
        port: 3389,
        serviceType: ServiceType.rdp,
        rdpDomain: 'CORP',
        gatewayId: 'retired',
      ),
    );
    // Reproduce a version 9 database containing a now-unsupported gateway.
    await db.customStatement(
      "UPDATE hosts SET gateway_type = 'rdp', rdp_domain = 'OLD' WHERE id = 'retired'",
    );
    await db.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final available = DriftHostRepository(reopened, gateways: true);
    expect((await available.getAll()).map((g) => g.id), ['ssh']);
    expect(
      (await available.watchAll().first).single.gatewayType,
      GatewayType.ssh,
    );
    final rows = await reopened.select(reopened.hosts).get();
    expect(rows.firstWhere((row) => row.id == 'retired').gatewayType, 'rdp');
    final reopenedIdentities = DriftIdentityRepository(reopened);
    expect(
      await reopenedIdentities.isReferenced('gateway-credential'),
      isFalse,
    );
    await reopenedIdentities.remove('gateway-credential');
    final retired = await (reopened.select(
      reopened.hosts,
    )..where((h) => h.id.equals('retired'))).getSingle();
    expect(retired.identityId, isNull);
    final services = DriftHostRepository(reopened);
    final saved = (await services.getAll()).single;
    expect(saved.gatewayId, 'retired');
    expect(saved.serviceType, ServiceType.rdp);
    expect(saved.rdpDomain, 'CORP');
    await expectLater(services.upsert(saved), throwsStateError);
    await services.upsert(saved.copyWith(gatewayId: 'ssh'));
    expect((await services.getAll()).single.gatewayId, 'ssh');
  });

  test('版本 8 升级保留 SSH 信任记录并隔离同地址同端口的 RDP 证书', () async {
    final dir = await Directory.systemTemp.createTemp('pagashell-rdp-v8-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(old, gateways: true).upsert(
      const Host(
        id: 'g',
        name: 'Old SSH gateway',
        hostname: 'gateway.test',
        port: 3389,
      ),
    );
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_type');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN rdp_domain');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN page_client_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN page_server_fingerprint',
    );
    await old.customStatement('DROP TABLE known_hosts');
    await old.customStatement(
      'CREATE TABLE known_hosts (hostname TEXT NOT NULL, port INTEGER NOT NULL, key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(hostname, port))',
    );
    await old.customStatement(
      "INSERT INTO known_hosts VALUES ('gateway.test', 3389, 'ssh-ed25519', 'old-ssh')",
    );
    await old.customStatement(
      'ALTER TABLE identities DROP COLUMN service_type',
    );
    await old.customStatement('PRAGMA user_version = 8');
    await old.close();

    final db = AppDatabase.forTesting(NativeDatabase(file));
    final saved = (await DriftHostRepository(
      db,
      gateways: true,
    ).getAll()).single;
    expect(saved.gatewayType, GatewayType.ssh);
    expect(saved.rdpDomain, isEmpty);
    final keys = DriftKnownHostRepository(db);
    expect((await keys.find('gateway.test', 3389))!.fingerprint, 'old-ssh');
    const rdp = SshHostKey(
      hostname: 'GATEWAY.test',
      port: 3389,
      keyType: 'X.509 SHA-256',
      fingerprint: 'rdp-cert',
      protocol: ServerIdentityProtocol.rdp,
    );
    expect(await keys.trustIfAbsent(rdp), isTrue);
    expect(
      await keys.trustIfAbsent(
        const SshHostKey(
          hostname: 'gateway.test',
          port: 3389,
          keyType: 'X.509 SHA-256',
          fingerprint: 'changed-cert',
          protocol: ServerIdentityProtocol.rdp,
        ),
      ),
      isFalse,
    );
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final repository = DriftKnownHostRepository(reopened);
    expect(
      (await repository.find('gateway.test', 3389))!.fingerprint,
      'old-ssh',
    );
    expect(
      (await repository.find(
        'gateway.test',
        3389,
        protocol: ServerIdentityProtocol.rdp,
      ))!.matches(rdp),
      isTrue,
    );
  });
}
