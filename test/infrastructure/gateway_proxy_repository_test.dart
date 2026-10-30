import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';

const config = ProxyConfig(
  mode: ProxyMode.rule,
  httpPort: 28080,
  httpsPort: 28080,
  socks5Enabled: true,
  socks5Port: 21080,
  autoSystemProxy: true,
  rules: [
    ProxyRule(type: ProxyRuleType.ip, value: '10.0.0.0/16'),
    ProxyRule(type: ProxyRuleType.ip, value: '2001:db8::/32'),
    ProxyRule(type: ProxyRuleType.domainExact, value: 'api.test'),
    ProxyRule(type: ProxyRuleType.domainPrefix, value: 'internal.'),
    ProxyRule(type: ProxyRuleType.domainSuffix, value: 'example.test'),
  ],
);
const gateway = Host(
  id: 'gateway',
  name: 'Proxy',
  hostname: 'jump.test',
  forwardPorts: [
    ForwardPort(localPort: 13306, targetHost: 'db.test', targetPort: 3306),
  ],
);

void main() {
  test('代理配置验证 IPv4/IPv6、CIDR、域名及启用协议', () {
    config.validate(forStart: true);
    for (final ip in [
      '0.0.0.0/0',
      '10.1.2.3',
      '255.255.255.255/32',
      '::/0',
      '::1',
      '2001:db8::/32',
      '2001:db8::1/128',
    ]) {
      ProxyRule(type: ProxyRuleType.ip, value: ip).validate();
    }
    for (final ip in [
      '256.0.0.1',
      '10.0.0.0/33',
      '::/129',
      '::/-1',
      '::1%lo0',
      '10.0.0.0/a',
      '',
    ]) {
      expect(
        () => ProxyRule(type: ProxyRuleType.ip, value: ip).validate(),
        throwsStateError,
      );
    }
    for (final domain in ['example.com', 'API.', 'internal_test.local.']) {
      ProxyRule(type: ProxyRuleType.domainPrefix, value: domain).validate();
    }
    for (final domain in [
      'https://example.com',
      'example.com:443',
      '*.test',
      '',
      'a b',
      '127.0.0.1',
    ]) {
      expect(
        () => ProxyRule(
          type: ProxyRuleType.domainExact,
          value: domain,
        ).validate(),
        throwsStateError,
      );
    }
    expect(
      () => const ProxyConfig(
        httpEnabled: false,
        httpsEnabled: false,
        socks5Enabled: false,
      ).validate(forStart: true),
      throwsStateError,
    );
    expect(ProxyConfig.fromJson(config.toJson()).toJson(), config.toJson());
    expect(ProxyConfig.fromJson({}).autoSystemProxy, isFalse);
    expect(config.toEngineJson().containsKey('autoSystemProxy'), isFalse);
  });

  test('旧直连配置读取为规则模式并保留协议、端口和规则', () {
    final legacy = {...config.toJson(), 'mode': 'direct'};
    final restored = ProxyConfig.fromJson(legacy);
    expect(restored.toJson(), config.toJson());
  });

  for (final sqlite in [false, true]) {
    test('${sqlite ? 'SQLite' : '内存'} 代理保存只更新最新代理字段且删除后不能复活', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final memory = InMemoryHostRepository();
      final folders = InMemoryFolderRepository();
      final hosts = sqlite ? DriftHostRepository(db, gateways: true) : memory;
      final tree = sqlite
          ? DriftHostTreeRepository(db, gateways: true)
          : InMemoryHostTreeRepository(hosts: memory, folders: folders);
      addTearDown(() async {
        await db.close();
        memory.dispose();
        folders.dispose();
      });
      await tree.saveHost(
        gateway.copyWith(name: 'Updated', hostname: 'new.test', note: 'keep'),
      );
      final saved = await tree.saveProxyConfig(gateway.id, config);
      expect(saved.proxyConfig.toJson(), config.toJson());
      expect(saved.name, 'Updated');
      expect(saved.hostname, 'new.test');
      expect(saved.note, 'keep');
      expect(saved.forwardPorts, gateway.forwardPorts);
      await tree.saveForwardPorts(gateway.id, []);
      expect(
        (await hosts.getAll()).single.proxyConfig.toJson(),
        config.toJson(),
      );
      expect(
        () => saved.proxyConfig.rules.add(config.rules.first),
        throwsUnsupportedError,
      );
      await expectLater(
        tree.saveProxyConfig(gateway.id, const ProxyConfig(httpPort: 0)),
        throwsStateError,
      );
      expect(
        (await hosts.getAll()).single.proxyConfig.toJson(),
        config.toJson(),
      );
      await hosts.remove(gateway.id);
      await expectLater(
        tree.saveProxyConfig(gateway.id, config),
        throwsStateError,
      );
      expect(await hosts.getAll(), isEmpty);
    });
  }

  test('schema 12 升级保留网关端口映射与服务引用；代理配置关闭重开保留', () async {
    final dir = await Directory.systemTemp.createTemp(
      'pagashell-proxy-migration-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(old, gateways: true).upsert(gateway);
    await DriftHostRepository(old).upsert(
      const Host(
        id: 'service',
        name: 'Service',
        hostname: 'service.test',
        gatewayId: 'gateway',
      ),
    );
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN proxy_config_json',
    );
    await old.customStatement('PRAGMA user_version = 12');
    await old.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    final saved = (await DriftHostRepository(
      upgraded,
      gateways: true,
    ).getAll()).single;
    expect(saved.forwardPorts, gateway.forwardPorts);
    expect(saved.proxyConfig.toJson(), const ProxyConfig().toJson());
    expect(
      (await DriftHostRepository(upgraded).getAll()).single.gatewayId,
      gateway.id,
    );
    await DriftHostTreeRepository(
      upgraded,
      gateways: true,
    ).saveProxyConfig(gateway.id, config);
    await upgraded.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final persisted = (await DriftHostRepository(
      reopened,
      gateways: true,
    ).getAll()).single;
    expect(persisted.proxyConfig.toJson(), config.toJson());
    expect(persisted.forwardPorts, gateway.forwardPorts);
  });
}
