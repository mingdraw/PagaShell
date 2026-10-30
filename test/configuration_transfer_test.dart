import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/configuration/configuration_transfer.dart';
import 'package:pagashell/domain/entities/connection_configuration.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/services/host_tree.dart';
import 'package:pagashell/domain/services/identity_tree.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_configuration_repository.dart';

class _Vault implements SecretStore {
  final values = <String, String>{};
  int writes = 0;
  final failOn = <int>{};

  @override
  Future<String?> read(String ref) async => values[ref];

  @override
  Future<void> put(String ref, String secret) async {
    values[ref] = secret;
    if (failOn.remove(++writes)) throw StateError('sensitive-platform-error');
  }

  @override
  Future<void> delete(String ref) async => values.remove(ref);
}

class _Store {
  _Store() {
    repository = DriftConfigurationRepository(db, vault);
    transfer = ConfigurationTransfer(repository: repository);
  }

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final vault = _Vault();
  late final DriftConfigurationRepository repository;
  late final ConfigurationTransfer transfer;
}

ConnectionConfiguration _fixture() => ConnectionConfiguration(
  serviceFolders: const [
    Folder(id: 'sf', name: 'Services', sortOrder: 1),
    Folder(id: 'sf-child', name: 'Nested', parentId: 'sf', sortOrder: 1),
  ],
  services: const [
    Host(
      id: 'own',
      name: 'Own password',
      hostname: 'own.example',
      sortOrder: 0,
    ),
    Host(
      id: 'ssh',
      name: 'SSH service',
      hostname: 'ssh.example',
      port: 2222,
      username: 'ignored',
      note: 'Test note',
      tags: ['one', '二'],
      folderId: 'sf',
      identityId: 'password',
      gatewayId: 'jump',
      colorValue: 0xff00ff00,
      sortOrder: 0,
    ),
    Host(
      id: 'nested',
      name: 'Nested SSH',
      hostname: 'nested.example',
      folderId: 'sf-child',
      identityId: 'key',
      sortOrder: 0,
    ),
    Host(
      id: 'rdp',
      name: 'RDP service',
      hostname: 'rdp.example',
      port: 3389,
      serviceType: ServiceType.rdp,
      rdpDomain: 'EXAMPLE',
      identityId: 'rdp-password',
      gatewayId: 'page',
      sortOrder: 2,
    ),
  ],
  gatewayFolders: const [
    Folder(id: 'gf', name: 'Gateways', sortOrder: 1),
    Folder(id: 'gf-child', name: 'Nested gateway', parentId: 'gf'),
  ],
  gateways: const [
    Host(
      id: 'page',
      name: 'Page gateway',
      hostname: 'page.example',
      port: 443,
      gatewayType: GatewayType.page,
      pageClientId: 'test-client',
      pageServerFingerprint: 'test-page-fingerprint',
      proxyConfig: ProxyConfig(
        mode: ProxyMode.rule,
        socks5Enabled: true,
        rules: [
          ProxyRule(type: ProxyRuleType.ip, value: '10.0.0.0/16'),
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'internal.test'),
        ],
      ),
      sortOrder: 0,
      forwardPorts: [
        ForwardPort(
          localPort: 13306,
          targetHost: 'db.internal',
          targetPort: 3306,
        ),
      ],
    ),
    Host(
      id: 'jump',
      name: 'SSH gateway',
      hostname: 'jump.example',
      folderId: 'gf-child',
      identityId: 'key',
      forwardPorts: [ForwardPort(localPort: 8080, targetPort: 80)],
    ),
  ],
  identityFolders: const [
    Folder(id: 'if', name: 'Credentials', sortOrder: 1),
    Folder(id: 'if-child', name: 'Nested credentials', parentId: 'if'),
  ],
  identities: const [
    Identity(
      id: 'rdp-password',
      name: 'RDP password',
      username: 'alice',
      authType: AuthType.password,
      serviceType: ServiceType.rdp,
      folderId: 'if-child',
      sortOrder: 1,
    ),
    Identity(
      id: 'password',
      name: 'Password',
      username: 'alice',
      authType: AuthType.password,
      secretRef: 'remote-secret-reference',
    ),
    Identity(
      id: 'key',
      name: 'Private key',
      username: 'bob',
      authType: AuthType.privateKey,
      folderId: 'if-child',
    ),
  ],
  identitySecrets: {
    'rdp-password': 'test-rdp-password-only',
    'password': 'test-password-only',
    'key': jsonEncode({
      'version': 1,
      'privateKey': 'public-test-key-marker-only',
      'passphrase': 'test-passphrase-only',
    }),
  },
  hostSecrets: const {'own': 'test-host-password', 'page': 'test-page-token'},
);

Matcher get _configurationError => throwsA(isA<ConfigurationException>());

void main() {
  for (final version in [1, 2]) {
    test('导入 v$version 清除旧端口映射，保留服务、网关和凭据', () async {
      final data = _fixture().toJson();
      data['version'] = version;
      final services = data['services']! as List<Object?>;
      (services.first! as Map<String, Object?>)['forwardPorts'] = [
        {'localPort': 8080, 'targetPort': 80},
      ];
      final converted = ConnectionConfiguration.fromJson(data);
      expect(converted.services.every((h) => h.forwardPorts.isEmpty), isTrue);
      expect(converted.gateways.every((h) => h.forwardPorts.isEmpty), isTrue);
      expect(
        converted.services.map((h) => h.hostname),
        _fixture().services.map((h) => h.hostname),
      );
      expect(
        converted.gateways.map((h) => h.hostname),
        _fixture().gateways.map((h) => h.hostname),
      );
      expect(
        converted.services.singleWhere((h) => h.id == 'ssh').gatewayId,
        'jump',
      );
      expect(converted.hostSecrets, _fixture().hostSecrets);
      final store = _Store();
      addTearDown(store.db.close);
      await store.repository.merge(converted);
      final stored = (await store.repository.read()).toJson();
      final expected = converted.toJson();
      for (final key in [
        'serviceFolders',
        'services',
        'gatewayFolders',
        'gateways',
        'identityFolders',
        'identities',
      ]) {
        expect(stored[key], unorderedEquals(expected[key]! as List<Object?>));
      }
      expect(stored['identitySecrets'], expected['identitySecrets']);
      expect(stored['hostSecrets'], expected['hostSecrets']);
    });
  }

  test('v3 保留网关目标地址，拒绝服务上的端口映射', () {
    final data = _fixture().toJson();
    expect(data['version'], 4);
    data['version'] = 3;
    for (final host in data['gateways']! as List<Object?>) {
      (host! as Map<String, Object?>).remove('proxyConfig');
    }
    final converted = ConnectionConfiguration.fromJson(data);
    expect(converted.gateways.first.proxyConfig.mode, ProxyMode.global);
    expect(
      converted.gateways.first.forwardPorts.first.targetHost,
      'db.internal',
    );
    final services = data['services']! as List<Object?>;
    (services.first! as Map<String, Object?>)['forwardPorts'] = [
      {'localPort': 8080, 'targetHost': 'db.internal', 'targetPort': 80},
    ];
    expect(() => ConnectionConfiguration.fromJson(data), _configurationError);
  });

  test('默认导出未加密文件，无密码导入保留配置、排序与全部凭据', () async {
    final source = _Store();
    late ConnectionConfiguration exported;
    late Uint8List archive;
    try {
      await source.repository.merge(_fixture());
      exported = await source.repository.read();
      archive = await source.transfer.exportFile();
    } finally {
      await source.db.close();
    }
    final target = _Store();
    addTearDown(target.db.close);
    final envelope = jsonDecode(utf8.decode(archive)) as Map<String, dynamic>;
    expect(envelope['encrypted'], isFalse);
    expect(envelope['data'], exported.toJson());
    expect(target.transfer.isEncrypted(archive), isFalse);
    await target.transfer.importFile(archive);
    expect((await target.repository.read()).toJson(), exported.toJson());
    final before = Map<String, String>.of(target.vault.values);
    await target.transfer.importFile(archive);
    expect((await target.repository.read()).toJson(), exported.toJson());
    expect(target.vault.values, before);
  });

  test('无效或混合格式的未加密文件在写入前拒绝', () async {
    final store = _Store();
    addTearDown(store.db.close);
    final archive = await store.transfer.exportFile();
    final envelope = jsonDecode(utf8.decode(archive)) as Map<String, dynamic>;
    for (final change in [
      {'encrypted': 'false'},
      {'version': 2},
      {'data': null},
      {'cipher': 'aes-256-gcm'},
      {'ciphertext': 'broken'},
      {
        'data': {'version': 1},
      },
    ]) {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({...envelope, ...change})),
      );
      await expectLater(store.transfer.importFile(bytes), _configurationError);
    }
    expect(await store.repository.services.getAll(), isEmpty);
    expect(store.vault.values, isEmpty);
  });

  group('加密配置文件', () {
    late Uint8List archive;
    late Map<String, Object?> exported;
    const password = 'test-export-password';

    setUpAll(() async {
      final source = _Store();
      try {
        await source.repository.merge(_fixture());
        exported = (await source.repository.read()).toJson();
        archive = await source.transfer.exportFile(password);
      } finally {
        await source.db.close();
      }
    });

    test('自动识别新旧加密文件，无密码时不写入，也不降级为明文', () async {
      final target = _Store();
      addTearDown(target.db.close);
      expect(target.transfer.isEncrypted(archive), isTrue);
      await expectLater(
        target.transfer.importFile(archive),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.message,
            'message',
            '请输入配置文件密码',
          ),
        ),
      );
      final legacy = jsonDecode(utf8.decode(archive)) as Map<String, dynamic>
        ..remove('encrypted');
      final oldArchive = Uint8List.fromList(utf8.encode(jsonEncode(legacy)));
      expect(target.transfer.isEncrypted(oldArchive), isTrue);
      await target.transfer.importFile(oldArchive, password);
      expect((await target.repository.read()).toJson(), exported);
      final before = Map<String, String>.of(target.vault.values);
      legacy['encrypted'] = false;
      final invalid = Uint8List.fromList(utf8.encode(jsonEncode(legacy)));
      expect(() => target.transfer.isEncrypted(invalid), _configurationError);
      await expectLater(
        target.transfer.importFile(invalid),
        _configurationError,
      );
      expect((await target.repository.read()).toJson(), exported);
      expect(target.vault.values, before);
    });

    test('跨设备往返保留三棵树、混合排序、引用、协议、映射和全部凭据', () async {
      final target = _Store();
      addTearDown(target.db.close);
      final text = utf8.decode(archive);
      for (final marker in [
        'test-password-only',
        'public-test-key-marker-only',
        'test-page-token',
        'test-passphrase-only',
        'ssh.example',
        'remote-secret-reference',
      ]) {
        expect(text.contains(marker), isFalse);
      }
      await target.transfer.importFile(archive, password);
      final result = await target.repository.read();
      expect(result.toJson(), exported);
      expect(result.identities.first.secretRef, startsWith('sec-import-'));
      final keys = result.identities.where((i) => i.id == 'key').single;
      final keyPayload = jsonDecode(
        target.vault.values[keys.secretRef!]!,
      ) as Map<String, dynamic>;
      expect(keyPayload['passphrase'], 'test-passphrase-only');
      expect(
        HostTreeSnapshot(
          folders: result.serviceFolders,
          hosts: result.services,
        ).childrenOf(null).map((node) => node.item.id),
        ['own', 'sf', 'rdp'],
      );
      expect(
        IdentityTreeSnapshot(
          folders: result.identityFolders,
          identities: result.identities,
        ).childrenOf(null).map((node) => node.item.id),
        ['password', 'if'],
      );
      // 系统信任、主题和 AI 配置均不随连接配置迁移。
      expect(await target.db.select(target.db.knownHosts).get(), isEmpty);
      expect(await target.db.select(target.db.appSettings).get(), isEmpty);
      final before = Map<String, String>.of(target.vault.values);
      await target.transfer.importFile(archive, password);
      expect((await target.repository.read()).toJson(), exported);
      expect(target.vault.values, before);
    });

    test('同样内容每次导出的盐和随机数不同', () async {
      final target = _Store();
      addTearDown(target.db.close);
      await target.repository.merge(_fixture());
      final other = await target.transfer.exportFile(password);
      final first = jsonDecode(utf8.decode(archive)) as Map<String, dynamic>;
      final second = jsonDecode(utf8.decode(other)) as Map<String, dynamic>;
      expect(first['salt'], isNot(second['salt']));
      expect(first['nonce'], isNot(second['nonce']));
      expect(
        (await target.transfer.readFile(other, password)).toJson(),
        exported,
      );
    });

    test('错误密码或篡改密文均拒绝，且不修改本地配置和凭据', () async {
      final target = _Store();
      addTearDown(target.db.close);
      await target.repository.merge(
        const ConnectionConfiguration(
          services: [
            Host(id: 'local', name: 'Local', hostname: 'local.example'),
          ],
          hostSecrets: {'local': 'local-password'},
        ),
      );
      final before = (await target.repository.read()).toJson();
      final secrets = Map<String, String>.of(target.vault.values);
      await expectLater(
        target.transfer.importFile(archive, 'wrong-password'),
        _configurationError,
      );
      final tampered = jsonDecode(utf8.decode(archive)) as Map<String, dynamic>;
      final cipher = base64Decode(tampered['ciphertext'] as String);
      cipher[0] ^= 1;
      tampered['ciphertext'] = base64Encode(cipher);
      await expectLater(
        target.transfer.importFile(
          Uint8List.fromList(utf8.encode(jsonEncode(tampered))),
          password,
        ),
        _configurationError,
      );
      expect((await target.repository.read()).toJson(), before);
      expect(target.vault.values, secrets);
    });

    test('拒绝未知版本、恶意派生参数、超限文件和过短导出密码', () async {
      final target = _Store();
      addTearDown(target.db.close);
      for (final change in [
        {'version': 2},
        {'iterations': 999999999},
        {'salt': 'AA=='},
      ]) {
        final envelope =
            jsonDecode(utf8.decode(archive)) as Map<String, dynamic>
              ..addAll(change);
        await expectLater(
          target.transfer.importFile(
            Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
            password,
          ),
          _configurationError,
        );
      }
      await expectLater(
        target.transfer.readFile(
          Uint8List(ConfigurationTransfer.maxFileBytes + 1),
          password,
        ),
        _configurationError,
      );
      await expectLater(
        target.transfer.exportFile('short'),
        _configurationError,
      );
      expect(await target.repository.services.getAll(), isEmpty);
      expect(target.vault.values, isEmpty);
    });
  });

  group('配置合并事务', () {
    late _Store store;
    setUp(() => store = _Store());
    tearDown(() => store.db.close());

    test('同 ID 更新，本地独有保留，同级不同 ID 重名自动编号，重复导入幂等', () async {
      await store.repository.merge(
        const ConnectionConfiguration(
          serviceFolders: [Folder(id: 'local-folder', name: 'Folder')],
          services: [
            Host(
              id: 'local',
              name: 'Same',
              hostname: 'local.example',
              sortOrder: 1,
            ),
            Host(
              id: 'update',
              name: 'Old',
              hostname: 'old.example',
              sortOrder: 2,
            ),
          ],
          hostSecrets: {'local': 'untouched'},
        ),
      );
      const incoming = ConnectionConfiguration(
        serviceFolders: [
          Folder(id: 'new-folder', name: 'Folder', sortOrder: 1),
        ],
        services: [
          Host(id: 'new', name: 'Same', hostname: 'new.example'),
          Host(
            id: 'update',
            name: 'Updated',
            hostname: 'updated.example',
            sortOrder: 2,
          ),
        ],
      );
      await store.repository.merge(incoming);
      final result = await store.repository.read();
      final tree = HostTreeSnapshot(
        folders: result.serviceFolders,
        hosts: result.services,
      );
      expect(tree.childrenOf(null).map((node) => node.name), [
        'Same (2)',
        'Folder (2)',
        'Updated',
        'Folder',
        'Same',
      ]);
      expect(
        result.services.singleWhere((h) => h.id == 'update').hostname,
        'updated.example',
      );
      expect(result.hostSecrets['local'], 'untouched');
      await store.repository.merge(incoming);
      expect((await store.repository.read()).toJson(), result.toJson());
    });

    test('忽略文件的 secretRef，随机分配本机键并避免身份 ID 与服务密码键相撞', () async {
      final json = const ConnectionConfiguration(
        identities: [
          Identity(
            id: 'host-service',
            name: 'Key',
            username: 'root',
            authType: AuthType.password,
            secretRef: 'pagashell-vault-key-v1',
          ),
        ],
        services: [Host(id: 'service', name: 'Service', hostname: 'example')],
        identitySecrets: {'host-service': 'identity-password'},
        hostSecrets: {'service': 'host-password'},
      ).toJson();
      final identityJson =
          (json['identities']! as List<Object?>).first! as Map<String, Object?>;
      identityJson['secretRef'] = 'pagashell-vault-key-v1';
      store.vault.values['pagashell-vault-key-v1'] = 'master-key-marker';
      final incoming = ConnectionConfiguration.fromJson(json);
      expect(incoming.identities.single.secretRef, isNull);
      await store.repository.merge(incoming);
      expect(store.vault.values['pagashell-vault-key-v1'], 'master-key-marker');
      final identity = (await store.repository.identities.getAll()).single;
      expect(identity.secretRef, startsWith('sec-import-'));
      expect(store.vault.values[identity.secretRef], 'identity-password');
      expect(store.vault.values['sec-host-service'], 'host-password');
    });

    test('拒绝已存在的跨项目凭据键冲突，避免覆盖别的项目', () async {
      await store.repository.identities.upsert(
        const Identity(
          id: 'local',
          name: 'Local',
          username: 'root',
          authType: AuthType.password,
          secretRef: 'sec-host-host',
        ),
      );
      store.vault.values['sec-host-host'] = 'local-identity-secret';
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            services: [Host(id: 'host', name: 'New', hostname: 'example')],
            hostSecrets: {'host': 'new-host-password'},
          ),
        ),
        _configurationError,
      );
      expect(await store.repository.services.getAll(), isEmpty);
      expect(store.vault.values['sec-host-host'], 'local-identity-secret');
    });

    test('元数据写入失败回滚三棵树，并恢复已覆盖和已新增的凭据', () async {
      await store.repository.merge(_fixture());
      final before = (await store.repository.read()).toJson();
      final secrets = Map<String, String>.of(store.vault.values);
      await store.db.customStatement(
        "CREATE TRIGGER fail_import BEFORE UPDATE ON hosts BEGIN SELECT RAISE(ABORT, 'sensitive-platform-error'); END",
      );
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            identities: [
              Identity(
                id: 'password',
                name: 'Changed',
                username: 'changed',
                authType: AuthType.password,
              ),
              Identity(
                id: 'new',
                name: 'New',
                username: 'new',
                authType: AuthType.password,
              ),
            ],
            identitySecrets: {'password': 'replacement', 'new': 'new-password'},
            hostSecrets: {'own': 'replacement-host'},
            services: [Host(id: 'own', name: 'Changed', hostname: 'changed')],
          ),
        ),
        _configurationError,
      );
      expect((await store.repository.read()).toJson(), before);
      expect(store.vault.values, secrets);
    });

    test('凭据部分写入失败时恢复原值，元数据没有中间状态', () async {
      await store.repository.merge(_fixture());
      final before = (await store.repository.read()).toJson();
      final secrets = Map<String, String>.of(store.vault.values);
      store.vault.failOn.add(store.vault.writes + 2);
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            identities: [
              Identity(
                id: 'password',
                name: 'Changed',
                username: 'changed',
                authType: AuthType.password,
              ),
              Identity(
                id: 'new',
                name: 'New',
                username: 'new',
                authType: AuthType.password,
              ),
            ],
            identitySecrets: {'password': 'replacement', 'new': 'new-password'},
          ),
        ),
        _configurationError,
      );
      expect((await store.repository.read()).toJson(), before);
      expect(store.vault.values, secrets);
    });

    test('凭据恢复再次失败时只展示脱敏说明', () async {
      await store.repository.merge(_fixture());
      store.vault.failOn.addAll([
        store.vault.writes + 1,
        store.vault.writes + 2,
      ]);
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            identities: [
              Identity(
                id: 'password',
                name: 'Changed',
                username: 'root',
                authType: AuthType.password,
              ),
            ],
            identitySecrets: {'password': 'replacement'},
          ),
        ),
        throwsA(
          isA<ConfigurationException>().having(
            (e) => e.message,
            'message',
            '配置导入失败，凭据恢复失败，请解锁钥匙串后重试',
          ),
        ),
      );
    });

    test('服务和网关共享表时拒绝跨分组覆盖，包括不再显示的旧 RDP 网关', () async {
      await store.db.customStatement(
        "INSERT INTO hosts (id, name, hostname, is_gateway, gateway_type) VALUES ('retired', 'Retired', 'old', 1, 'rdp')",
      );
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            services: [Host(id: 'retired', name: 'Service', hostname: 'new')],
            hostSecrets: {'retired': 'replacement'},
          ),
        ),
        _configurationError,
      );
      final row = (await store.db.select(store.db.hosts).get()).single;
      expect(row.isGateway, isTrue);
      expect(row.gatewayType, 'rdp');
      expect(row.hostname, 'old');
      expect(store.vault.values, isEmpty);
      await store.repository.gatewayFolders.upsert(
        const Folder(id: 'folder', name: 'Gateway folder'),
      );
      await expectLater(
        store.repository.merge(
          const ConnectionConfiguration(
            serviceFolders: [Folder(id: 'folder', name: 'Service folder')],
          ),
        ),
        _configurationError,
      );
      expect(
        (await store.repository.gatewayFolders.getAll()).single.name,
        'Gateway folder',
      );
    });

    test('引用缺失、循环、重名、重复 ID 和无效端口在写入前拒绝', () async {
      await store.repository.merge(_fixture());
      final before = (await store.repository.read()).toJson();
      final secrets = Map<String, String>.of(store.vault.values);
      for (final invalid in [
        const ConnectionConfiguration(
          serviceFolders: [
            Folder(id: 'a', name: 'A', parentId: 'b'),
            Folder(id: 'b', name: 'B', parentId: 'a'),
          ],
        ),
        const ConnectionConfiguration(
          services: [
            Host(id: 'a', name: 'A', hostname: 'a', identityId: 'missing'),
          ],
        ),
        const ConnectionConfiguration(
          services: [
            Host(id: 'a', name: 'A', hostname: 'a', gatewayId: 'missing'),
          ],
        ),
        const ConnectionConfiguration(
          services: [
            Host(id: 'a', name: 'A', hostname: 'a', folderId: 'missing'),
          ],
        ),
        const ConnectionConfiguration(
          services: [
            Host(id: 'a', name: 'Same', hostname: 'a'),
            Host(id: 'b', name: 'Same', hostname: 'b'),
          ],
        ),
        const ConnectionConfiguration(
          services: [Host(id: 'a', name: 'A', hostname: 'a')],
          gateways: [Host(id: 'a', name: 'B', hostname: 'b')],
        ),
        const ConnectionConfiguration(
          services: [Host(id: 'a', name: 'A', hostname: 'a', port: 65536)],
        ),
        const ConnectionConfiguration(
          gateways: [
            Host(
              id: 'a',
              name: 'A',
              hostname: 'a',
              forwardPorts: [
                ForwardPort(localPort: 80, targetPort: 80),
                ForwardPort(localPort: 80, targetPort: 443),
              ],
            ),
          ],
        ),
        const ConnectionConfiguration(
          identities: [
            Identity(
              id: 'key',
              name: 'Key',
              username: 'root',
              authType: AuthType.privateKey,
            ),
          ],
          identitySecrets: {'key': 'not-json'},
        ),
      ]) {
        await expectLater(store.repository.merge(invalid), _configurationError);
      }
      expect((await store.repository.read()).toJson(), before);
      expect(store.vault.values, secrets);
    });

    test('未提供密文时保留相同认证方式的本机凭据；缺失保存的密文时拒绝导出', () async {
      await store.repository.merge(_fixture());
      await store.repository.merge(
        const ConnectionConfiguration(
          identities: [
            Identity(
              id: 'password',
              name: 'Renamed',
              username: 'new',
              authType: AuthType.password,
            ),
          ],
        ),
      );
      expect(
        (await store.repository.read()).identitySecrets['password'],
        'test-password-only',
      );
      final key = (await store.repository.identities.getAll()).singleWhere(
        (i) => i.id == 'key',
      );
      store.vault.values.remove(key.secretRef);
      await expectLater(
        store.transfer.exportFile('export-password'),
        _configurationError,
      );
    });
  });
}
