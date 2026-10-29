import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/encrypted_secret_store.dart';
import 'package:pagashell/infrastructure/vault/encrypted_vault_storage.dart';

class _Keychain implements SecretStore {
  final values = <String, String>{};
  final reads = <String>[];
  final writes = <String>[];
  final deletes = <String>[];
  bool locked = false;
  bool failWrite = false;
  bool failDelete = false;

  @override
  Future<String?> read(String ref) async {
    reads.add(ref);
    if (locked) throw const SecretStoreException('钥匙串已锁定');
    return values[ref];
  }

  @override
  Future<void> put(String ref, String secret) async {
    writes.add(ref);
    if (failWrite) throw const SecretStoreException('钥匙串写入失败');
    values[ref] = secret;
  }

  @override
  Future<void> delete(String ref) async {
    deletes.add(ref);
    if (failDelete) throw const SecretStoreException('旧凭据清理失败');
    values.remove(ref);
  }
}

class _FailingStorage implements EncryptedVaultStorage {
  _FailingStorage(this.delegate);

  final EncryptedVaultStorage delegate;
  bool failWrite = false;

  @override
  Future<T> transaction<T>(Future<T> Function(VaultTransaction) action) =>
      delegate.transaction(
        (transaction) => action(_FailingTransaction(transaction, this)),
      );
}

class _FailingTransaction implements VaultTransaction {
  _FailingTransaction(this.delegate, this.storage);

  final VaultTransaction delegate;
  final _FailingStorage storage;

  @override
  Future<List<int>?> read() => delegate.read();

  @override
  Future<void> write(List<int> encrypted) {
    if (storage.failWrite) throw StateError('sensitive-sentinel');
    return delegate.write(encrypted);
  }
}

void main() {
  late Directory directory;
  late File file;
  late _Keychain keychain;
  late _FailingStorage storage;
  late EncryptedSecretStore store;

  EncryptedSecretStore reopen() =>
      EncryptedSecretStore(keychain: keychain, storage: storage);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pagashell-vault-test-');
    file = File('${directory.path}/${FileEncryptedVaultStorage.filename}');
    keychain = _Keychain();
    storage = _FailingStorage(
      FileEncryptedVaultStorage(directory: () async => directory),
    );
    store = reopen();
  });

  tearDown(() => directory.delete(recursive: true));

  test('服务、网关和私钥共用主密钥，重新运行后只读取一次钥匙串', () async {
    final secrets = {
      'sec-host-service': 'service-sensitive-sentinel',
      'sec-host-gateway': 'gateway-sensitive-sentinel',
      'sec-identity': jsonEncode({
        'privateKey': 'private-key-sensitive-sentinel',
        'passphrase': 'passphrase-sensitive-sentinel',
      }),
    };
    for (final entry in secrets.entries) {
      await store.put(entry.key, entry.value);
    }
    expect(keychain.values.keys, [EncryptedSecretStore.masterKeyRef]);
    expect(keychain.writes, [EncryptedSecretStore.masterKeyRef]);
    final encrypted = await file.readAsBytes();
    final encodedFile = String.fromCharCodes(encrypted);
    for (final entry in secrets.entries) {
      expect(encodedFile, isNot(contains(entry.key)));
      expect(encodedFile, isNot(contains(entry.value)));
      expect(
        encodedFile,
        isNot(contains(base64Encode(utf8.encode(entry.value)))),
      );
    }

    keychain.reads.clear();
    final updatedApp = reopen();
    for (var attempt = 0; attempt < 2; attempt++) {
      for (final entry in secrets.entries) {
        expect(await updatedApp.read(entry.key), entry.value);
      }
    }
    expect(keychain.reads, [EncryptedSecretStore.masterKeyRef]);
  });

  test('旧条目先加密落盘再移除，后续更新无需逐条读钥匙串', () async {
    keychain.values.addAll({
      'sec-host-old': 'legacy-password',
      'sec-old-identity': 'legacy-private-key',
    });
    expect(await store.read('sec-host-old'), 'legacy-password');
    expect(await store.read('sec-old-identity'), 'legacy-private-key');
    expect(keychain.values.keys, [EncryptedSecretStore.masterKeyRef]);
    expect(keychain.deletes, ['sec-host-old', 'sec-old-identity']);
    keychain.reads.clear();
    final updatedApp = reopen();
    expect(await updatedApp.read('sec-host-old'), 'legacy-password');
    expect(await updatedApp.read('sec-old-identity'), 'legacy-private-key');
    expect(keychain.reads, [EncryptedSecretStore.masterKeyRef]);
  });

  test('落盘失败保留旧条目和已保存保险库，重试可继续迁移', () async {
    await store.put('keep', 'saved');
    final before = await file.readAsBytes();
    keychain.values['legacy'] = 'original';
    storage.failWrite = true;
    await expectLater(
      store.read('legacy'),
      throwsA(
        isA<SecretStoreException>().having(
          (error) => error.message,
          'safe error',
          isNot(contains('sensitive-sentinel')),
        ),
      ),
    );
    expect(await file.readAsBytes(), before);
    expect(keychain.values['legacy'], 'original');
    expect(keychain.deletes, isNot(contains('legacy')));
    storage.failWrite = false;
    expect(await store.read('legacy'), 'original');
    expect(await store.read('keep'), 'saved');
    expect(keychain.values, isNot(contains('legacy')));
  });

  test('迁移后清理旧条目失败，已持久化的凭据仍可重试读取', () async {
    keychain.values['legacy'] = 'original';
    keychain.failDelete = true;
    await expectLater(
      store.read('legacy'),
      throwsA(isA<SecretStoreException>()),
    );
    keychain.locked = true;
    // 主密钥已解锁，重试不再读取受旧 ACL 保护的条目。
    expect(await store.read('legacy'), 'original');
    expect(keychain.values['legacy'], 'original');
  });

  test('清理失败保留原值，删除成功后旧条目不会被回退读取复活', () async {
    await store.put('ref', 'original');
    keychain.values['ref'] = 'stale';
    keychain.failDelete = true;
    await expectLater(
      store.delete('ref'),
      throwsA(isA<SecretStoreException>()),
    );
    keychain.reads.clear();
    expect(await reopen().read('ref'), 'original');
    expect(keychain.reads, [EncryptedSecretStore.masterKeyRef]);
    keychain.failDelete = false;
    await store.delete('ref');
    expect(keychain.values, isNot(contains('ref')));
    keychain.values['ref'] = 'restored-by-old-app';
    expect(await reopen().read('ref'), isNull);
    await store.put('ref', 'replacement');
    expect(await reopen().read('ref'), 'replacement');
  });

  test('覆盖旧凭据时清理失败或提交失败都保留原值', () async {
    keychain.values['legacy'] = 'original';
    keychain.failDelete = true;
    await expectLater(
      store.put('legacy', 'replacement'),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await store.read('legacy'), 'original');
    expect(keychain.values['legacy'], 'original');
    keychain.failDelete = false;
    storage.failWrite = true;
    await expectLater(
      store.put('legacy', 'replacement'),
      throwsA(isA<SecretStoreException>()),
    );
    // 即使已清理旧项，原值也已有加密副本。
    expect(keychain.values, isNot(contains('legacy')));
    expect(await store.read('legacy'), 'original');
    storage.failWrite = false;
    await store.put('legacy', 'replacement');
    expect(await reopen().read('legacy'), 'replacement');
  });

  test('清理失败的新建凭证不创建元数据或孤立的新密文', () async {
    final repository = InMemoryIdentityRepository();
    addTearDown(repository.dispose);
    final controller = IdentityController(
      repository: repository,
      secretStore: store,
    );
    keychain.failDelete = true;
    await expectLater(
      controller.saveWithPassword(
        name: 'test',
        username: 'test',
        password: 'new-sensitive-sentinel',
      ),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await repository.getAll(), isEmpty);
    expect(file.existsSync(), isFalse);
    expect(keychain.values, isEmpty);
  });

  test('同时保存和跨实例访问不丢失其他服务的凭据', () async {
    final other = reopen();
    await Future.wait([
      for (var index = 0; index < 24; index++)
        (index.isEven ? store : other).put('ref-$index', 'secret-$index'),
    ]);
    final nextRun = reopen();
    for (var index = 0; index < 24; index++) {
      expect(await nextRun.read('ref-$index'), 'secret-$index');
    }
    expect(keychain.writes, [EncryptedSecretStore.masterKeyRef]);
  });

  test('钥匙串拒绝解锁时不覆盖保险库或迁移旧条目', () async {
    await store.put('saved', 'original');
    keychain.values['legacy'] = 'not-migrated';
    final before = await file.readAsBytes();
    keychain.locked = true;
    final locked = reopen();
    for (final action in [
      () => locked.read('legacy'),
      () => locked.put('saved', 'replacement'),
      () => locked.delete('saved'),
    ]) {
      await expectLater(action(), throwsA(isA<SecretStoreException>()));
    }
    expect(await file.readAsBytes(), before);
    expect(keychain.values['legacy'], 'not-migrated');
  });

  test('主密钥丢失时拒绝重新生成或覆盖已有保险库', () async {
    await store.put('ref', 'original');
    final before = await file.readAsBytes();
    keychain.values.clear();
    keychain.writes.clear();
    await expectLater(
      reopen().put('ref', 'replacement'),
      throwsA(
        isA<SecretStoreException>().having(
          (error) => error.message,
          'missing key',
          contains('密钥缺失'),
        ),
      ),
    );
    expect(keychain.writes, isEmpty);
    expect(await file.readAsBytes(), before);
  });

  test('密文被篡改时校验失败，不回退旧条目或覆盖文件', () async {
    await store.put('ref', 'original');
    final damaged = await file.readAsBytes();
    damaged[damaged.length - 1] ^= 1;
    await file.writeAsBytes(damaged, flush: true);
    keychain.values['ref'] = 'stale';
    keychain.reads.clear();
    final corrupted = reopen();
    for (final action in [
      () => corrupted.read('ref'),
      () => corrupted.put('ref', 'replacement'),
      () => corrupted.delete('ref'),
    ]) {
      await expectLater(
        action(),
        throwsA(
          isA<SecretStoreException>().having(
            (error) => error.message,
            'authentication failure',
            contains('损坏或密钥不匹配'),
          ),
        ),
      );
    }
    expect(keychain.reads, [EncryptedSecretStore.masterKeyRef]);
    expect(await file.readAsBytes(), damaged);
  });

  test('主密钥写入失败不缓存未保存的密钥、不删除旧凭据', () async {
    keychain.values['legacy'] = 'original';
    keychain.failWrite = true;
    await expectLater(
      store.read('legacy'),
      throwsA(isA<SecretStoreException>()),
    );
    expect(file.existsSync(), isFalse);
    expect(keychain.deletes, isEmpty);
    keychain.failWrite = false;
    expect(await store.read('legacy'), 'original');
    expect(await reopen().read('legacy'), 'original');
  });

  test('重复写入相同内容使用不同 nonce，事务失败会释放文件锁', () async {
    await store.put('ref', 'same');
    final before = await file.readAsBytes();
    await store.put('ref', 'same');
    expect(await file.readAsBytes(), isNot(before));
    await expectLater(
      storage.transaction<void>((_) async => throw StateError('abort')),
      throwsStateError,
    );
    await store.put('next', 'saved');
    expect(await reopen().read('next'), 'saved');
    expect(
      await directory.list().map((entry) => entry.path).toList(),
      hasLength(2),
    );
  });
}
