import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/entities/connection_configuration.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_configuration_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

void main() {
  test('schema 10 迁移按绑定拆分共享凭证，保留原密文引用及独立凭证', () async {
    final directory = await Directory.systemTemp.createTemp('vnc-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/db.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    final identities = DriftIdentityRepository(old);
    for (final id in ['shared', 'rdp-only', 'unused']) {
      await identities.upsert(
        Identity(
          id: id,
          name: id,
          username: 'user',
          authType: AuthType.password,
          secretRef: 'sec-$id',
        ),
      );
    }
    final hosts = DriftHostRepository(old);
    await hosts.upsert(
      const Host(
        id: 'ssh',
        name: 'SSH',
        hostname: 'ssh.test',
        identityId: 'shared',
      ),
    );
    await hosts.upsert(
      const Host(
        id: 'rdp',
        name: 'RDP',
        hostname: 'rdp.test',
        identityId: 'shared',
        serviceType: ServiceType.rdp,
      ),
    );
    await hosts.upsert(
      const Host(
        id: 'rdp2',
        name: 'RDP2',
        hostname: 'rdp2.test',
        identityId: 'rdp-only',
        serviceType: ServiceType.rdp,
      ),
    );
    await old.customStatement(
      'ALTER TABLE identities DROP COLUMN service_type',
    );
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN proxy_config_json',
    );
    await old.customStatement('PRAGMA user_version = 10');
    await old.close();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final saved = await DriftIdentityRepository(db).getAll();
    expect(saved.length, 4);
    expect(
      saved.singleWhere((i) => i.id == 'shared').serviceType,
      ServiceType.ssh,
    );
    expect(
      saved.singleWhere((i) => i.id == 'rdp-only').serviceType,
      ServiceType.rdp,
    );
    expect(
      saved.singleWhere((i) => i.id == 'unused').serviceType,
      ServiceType.ssh,
    );
    final clone = saved.singleWhere((i) => i.id.startsWith('shared-'));
    expect(clone.serviceType, ServiceType.rdp);
    expect(clone.secretRef, 'sec-shared');
    expect(
      (await DriftHostRepository(
        db,
      ).getAll()).singleWhere((h) => h.id == 'rdp').identityId,
      clone.id,
    );

    final vault = InMemorySecretStore();
    await vault.put('sec-shared', 'original');
    final controller = IdentityController(
      repository: DriftIdentityRepository(db),
      secretStore: vault,
    );
    controller.identities.assignAll(saved);
    await controller.updateIdentity(
      id: clone.id,
      name: clone.name,
      username: clone.username,
      password: 'new-password',
    );
    final updated = (await DriftIdentityRepository(
      db,
    ).getAll()).singleWhere((i) => i.id == clone.id);
    expect(updated.secretRef, isNot('sec-shared'));
    expect(await vault.read('sec-shared'), 'original');
    expect(await vault.read(updated.secretRef!), 'new-password');
  });

  test('删除共享旧密文的一个凭证不会删除另一条仍使用的密文', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftIdentityRepository(db);
    for (final id in ['a', 'b']) {
      await repository.upsert(
        Identity(
          id: id,
          name: id,
          username: 'user',
          authType: AuthType.password,
          secretRef: 'shared',
        ),
      );
    }
    final vault = InMemorySecretStore();
    await vault.put('shared', 'original');
    final controller = IdentityController(
      repository: repository,
      secretStore: vault,
    );
    await controller.remove('a');
    expect(await vault.read('shared'), 'original');
    await controller.remove('b');
    expect(await vault.read('shared'), isNull);
  });

  test('旧版配置拆分共享 SSH/RDP 凭证，VNC 配置和密文跨设备往返', () async {
    final legacy = ConnectionConfiguration(
      identities: const [
        Identity(
          id: 'i',
          name: 'Login',
          username: 'user',
          authType: AuthType.password,
        ),
      ],
      services: const [
        Host(id: 'ssh', name: 'SSH', hostname: 'ssh', identityId: 'i'),
        Host(
          id: 'rdp',
          name: 'RDP',
          hostname: 'rdp',
          identityId: 'i',
          serviceType: ServiceType.rdp,
        ),
      ],
      identitySecrets: const {'i': 'original'},
    ).toJson();
    legacy['version'] = 1;
    final migrated = ConnectionConfiguration.fromJson(
      Map<String, dynamic>.from(legacy),
    );
    expect(migrated.identities.map((i) => i.serviceType).toSet(), {
      ServiceType.ssh,
      ServiceType.rdp,
    });
    expect(migrated.identitySecrets.values, everyElement('original'));
    expect(
      migrated.services[0].identityId,
      isNot(migrated.services[1].identityId),
    );

    const config = ConnectionConfiguration(
      identities: [
        Identity(
          id: 'v',
          name: 'VNC login',
          username: '',
          authType: AuthType.password,
          serviceType: ServiceType.vnc,
        ),
      ],
      services: [
        Host(
          id: 'vnc',
          name: 'VNC',
          hostname: 'vnc.test',
          port: 5900,
          serviceType: ServiceType.vnc,
          identityId: 'v',
        ),
      ],
      identitySecrets: {'v': 'test-vnc-password'},
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final vault = InMemorySecretStore();
    final repository = DriftConfigurationRepository(db, vault);
    await repository.merge(
      ConnectionConfiguration.fromJson(
        Map<String, dynamic>.from(config.toJson()),
      ),
    );
    expect((await repository.read()).toJson(), config.toJson());
    expect(
      (await DriftIdentityRepository(
        db,
      ).getAll()).single.supports(ServiceType.ssh),
      isFalse,
    );
    final invalid = config.toJson();
    (invalid['identities']! as List<Map<String, Object?>>)
            .single['serviceType'] =
        'ssh';
    expect(
      () =>
          ConnectionConfiguration.fromJson(Map<String, dynamic>.from(invalid)),
      throwsA(isA<ConfigurationException>()),
    );
  });
}
