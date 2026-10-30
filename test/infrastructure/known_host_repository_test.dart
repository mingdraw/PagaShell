import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_known_host_repository.dart';

SshHostKey _key({
  String hostname = 'Example.COM',
  int port = 22,
  String fingerprint = 'SHA256:one',
  ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
}) => SshHostKey(
  hostname: hostname,
  port: port,
  keyType: 'ssh-ed25519',
  fingerprint: fingerprint,
  protocol: protocol,
);

void main() {
  test('可信记录按归一化地址和端口隔离，冲突不覆盖', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftKnownHostRepository(db);
    expect(await repository.find('example.com', 22), isNull);
    expect(await repository.trustIfAbsent(_key()), isTrue);
    expect(
      (await repository.find('example.com', 22))?.fingerprint,
      'SHA256:one',
    );
    expect(
      await repository.trustIfAbsent(_key(fingerprint: 'SHA256:two')),
      isFalse,
    );
    expect(
      await repository.trustIfAbsent(
        _key(port: 2222, fingerprint: 'SHA256:two'),
      ),
      isTrue,
    );
    expect(
      (await repository.find('EXAMPLE.COM', 22))?.fingerprint,
      'SHA256:one',
    );
    expect(
      (await repository.find('example.com', 2222))?.fingerprint,
      'SHA256:two',
    );
  });

  test('并发保存不同指纹只能信任其中一个', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftKnownHostRepository(db);
    final results = await Future.wait([
      repository.trustIfAbsent(_key()),
      repository.trustIfAbsent(_key(fingerprint: 'SHA256:two')),
    ]);
    expect(results.where((value) => value), hasLength(1));
  });

  test('清除按端点、协议及旧指纹精确匹配，并可重新信任新指纹', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftKnownHostRepository(db);
    await repository.trustIfAbsent(_key());
    await repository.trustIfAbsent(_key(port: 2222));
    await repository.trustIfAbsent(_key(hostname: 'jump.test'));
    await repository.trustIfAbsent(_key(protocol: ServerIdentityProtocol.rdp));
    expect(
      await repository.removeIfMatches(_key(fingerprint: 'SHA256:stale')),
      isFalse,
    );
    expect(
      (await repository.find('example.com', 22))!.fingerprint,
      'SHA256:one',
    );
    expect(
      await repository.removeIfMatches(_key(hostname: ' EXAMPLE.com ')),
      isTrue,
    );
    expect(await repository.find('example.com', 22), isNull);
    expect(await repository.find('example.com', 2222), isNotNull);
    expect(await repository.find('jump.test', 22), isNotNull);
    expect(
      await repository.find(
        'example.com',
        22,
        protocol: ServerIdentityProtocol.rdp,
      ),
      isNotNull,
    );
    expect(await repository.removeIfMatches(_key()), isFalse);
    expect(
      await repository.trustIfAbsent(_key(fingerprint: 'SHA256:new')),
      isTrue,
    );
    expect(await repository.removeIfMatches(_key()), isFalse);
    expect(
      (await repository.find('example.com', 22))!.fingerprint,
      'SHA256:new',
    );
  });

  test('从版本 1 升级新增可信记录表并保留主机数据，重开后仍可校验', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(old)
        .upsert(const Host(id: 'h1', name: 'saved', hostname: 'example.com'));
    // 模拟旧版结构：只保留版本 1 的三个元数据表。
    await old.customStatement('DROP TABLE app_settings');
    await old.customStatement('DROP TABLE known_hosts');
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
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN proxy_config_json',
    );
    await old.customStatement('PRAGMA user_version = 1');
    await old.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    expect((await DriftHostRepository(upgraded).getAll()).single.name, 'saved');
    expect(
      await DriftKnownHostRepository(upgraded).trustIfAbsent(_key()),
      isTrue,
    );
    await upgraded.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      (await DriftKnownHostRepository(
        reopened,
      ).find('example.com', 22))?.fingerprint,
      'SHA256:one',
    );
  });
}
