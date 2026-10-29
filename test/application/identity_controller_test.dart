import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/fake_private_key_validator.dart';

class _FailingRepository extends InMemoryIdentityRepository {
  _FailingRepository({super.services, super.gateways});

  bool failNextWrite = false;
  bool failNextRemove = false;

  @override
  Future<void> upsert(Identity identity) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('database-write-failed');
    }
    await super.upsert(identity);
  }

  @override
  Future<void> remove(String id) async {
    if (failNextRemove) {
      failNextRemove = false;
      throw StateError('database-delete-failed');
    }
    await super.remove(id);
  }
}

class _RecordingSecrets extends InMemorySecretStore {
  final Set<String> refs = {};
  final List<String> deletedRefs = [];
  bool failPut = false;
  bool failDelete = false;

  @override
  Future<void> put(String ref, String secret) async {
    if (failPut) throw const SecretStoreException('钥匙串不可用');
    refs.add(ref);
    await super.put(ref, secret);
  }

  @override
  Future<void> delete(String ref) async {
    if (failDelete) throw const SecretStoreException('钥匙串不可用');
    deletedRefs.add(ref);
    refs.remove(ref);
    await super.delete(ref);
  }
}

void main() {
  group('IdentityController', () {
    late _FailingRepository repo;
    late InMemoryHostRepository services;
    late InMemoryHostRepository gateways;
    late _RecordingSecrets secrets;
    late IdentityController controller;
    late FakePrivateKeyValidator validator;

    setUp(() {
      services = InMemoryHostRepository();
      gateways = InMemoryHostRepository();
      repo = _FailingRepository(services: services, gateways: gateways);
      secrets = _RecordingSecrets();
      validator = FakePrivateKeyValidator();
      controller = IdentityController(
        repository: repo,
        secretStore: secrets,
        privateKeyValidator: validator,
      )..onInit();
    });

    tearDown(() {
      controller.onClose();
      repo.dispose();
      services.dispose();
      gateways.dispose();
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('保存凭证后可按 id 查回并解出密码', () async {
      final identity = await controller.saveWithPassword(
        name: '生产环境 root',
        username: 'root',
        password: 's3cret',
      );
      await pump();

      expect(controller.byId(identity.id)?.username, 'root');
      expect(await controller.passwordOf(identity), 's3cret');
      final credentials = await controller.credentialsOf(identity);
      expect(credentials?.authType, AuthType.password);
      expect(credentials?.password, 's3cret');
      expect(credentials?.username, 'root');
    });

    test('同一凭证可被多次解出（多主机复用）', () async {
      final identity = await controller.saveWithPassword(
        name: 'deploy',
        username: 'deploy',
        password: 'pw',
      );
      await pump();

      expect(await controller.passwordOf(identity), 'pw');
      expect(await controller.passwordOf(identity), 'pw');
    });

    test('删除凭证时密文一并删除', () async {
      final identity = await controller.saveWithPassword(
        name: 'temp',
        username: 'temp',
        password: 'pw',
      );
      await pump();

      await controller.remove(identity.id);
      await pump();

      expect(controller.identities, isEmpty);
      expect(await secrets.read(identity.secretRef!), isNull);
    });

    for (final viaGateway in [false, true]) {
      for (final privateKey in [false, true]) {
        test(
          '${viaGateway ? '网关' : '服务'}引用的${privateKey ? '私钥' : '密码'}凭证拒删并保留密文，解绑后可删除',
          () async {
            final identity = privateKey
                ? await controller.saveWithPrivateKey(
                    name: 'Shared key',
                    username: 'deploy',
                    privateKey: 'test-key',
                    passphrase: 'test-phrase',
                  )
                : await controller.saveWithPassword(
                    name: 'Shared password',
                    username: 'deploy',
                    password: 'test-password',
                  );
            final hosts = viaGateway ? gateways : services;
            final host = Host(
              id: 'endpoint',
              name: 'Endpoint',
              hostname: 'endpoint.test',
              identityId: identity.id,
            );
            await hosts.upsert(host);

            await expectLater(
              controller.remove(identity.id),
              throwsA(
                isA<StateError>().having(
                  (error) => error.message,
                  'message',
                  '凭证正在被网关或服务使用，请先修改对应的凭证配置',
                ),
              ),
            );
            expect((await repo.getAll()).single.id, identity.id);
            expect((await hosts.getAll()).single.identityId, identity.id);
            expect(secrets.deletedRefs, isEmpty);
            final credentials = await controller.credentialsOf(identity);
            expect(credentials?.username, 'deploy');
            if (privateKey) {
              expect(credentials?.privateKey, 'test-key');
              expect(credentials?.passphrase, 'test-phrase');
            } else {
              expect(credentials?.password, 'test-password');
            }

            await hosts.upsert(host.copyWith(identityId: null));
            await controller.remove(identity.id);
            expect(await repo.getAll(), isEmpty);
            expect(await secrets.read(identity.secretRef!), isNull);
            expect((await hosts.getAll()).single.identityId, isNull);
          },
        );
      }
    }

    test('存储拒绝删除时恢复原密文，重试能正常删除', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'Shared key',
        username: 'deploy',
        privateKey: 'test-key',
        passphrase: 'test-phrase',
      );
      repo.failNextRemove = true;
      await expectLater(controller.remove(identity.id), throwsStateError);
      expect((await repo.getAll()).single.id, identity.id);
      final credentials = await controller.credentialsOf(identity);
      expect(credentials?.privateKey, 'test-key');
      expect(credentials?.passphrase, 'test-phrase');
      expect(secrets.refs, {identity.secretRef});

      await controller.remove(identity.id);
      expect(await repo.getAll(), isEmpty);
      expect(await secrets.read(identity.secretRef!), isNull);
    });

    test('钥匙串删除失败保留凭证，恢复密文失败明确提示', () async {
      final identity = await controller.saveWithPassword(
        name: 'Shared password',
        username: 'deploy',
        password: 'test-password',
      );
      secrets.failDelete = true;
      await expectLater(
        controller.remove(identity.id),
        throwsA(isA<SecretStoreException>()),
      );
      expect((await repo.getAll()).single.id, identity.id);
      expect(await controller.passwordOf(identity), 'test-password');

      secrets.failDelete = false;
      secrets.failPut = true;
      repo.failNextRemove = true;
      await expectLater(
        controller.remove(identity.id),
        throwsA(
          isA<SecretStoreException>().having(
            (error) => error.message,
            'message',
            contains('系统钥匙串恢复失败'),
          ),
        ),
      );
      expect((await repo.getAll()).single.id, identity.id);
    });

    test('列表按名称排序', () async {
      await controller.saveWithPassword(
        name: 'b-user',
        username: 'b',
        password: 'x',
      );
      await controller.saveWithPassword(
        name: 'a-user',
        username: 'a',
        password: 'x',
      );
      await pump();

      expect(controller.sorted.map((i) => i.name), ['a-user', 'b-user']);
    });

    test('私钥先校验后存入钥匙串，解出时保留口令和用户名', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'deploy-key',
        username: 'deploy',
        privateKey: '  test-private-key\n',
        passphrase: ' phrase ',
      );
      await pump();
      expect(validator.calls, [('test-private-key', ' phrase ')]);
      expect((await repo.getAll()).single.authType, AuthType.privateKey);
      final Object? secret = jsonDecode(
        (await secrets.read(identity.secretRef!))!,
      );
      expect(secret, {
        'version': 1,
        'privateKey': 'test-private-key',
        'passphrase': ' phrase ',
      });
      final credentials = await controller.credentialsOf(identity);
      expect(credentials?.privateKey, 'test-private-key');
      expect(credentials?.passphrase, ' phrase ');
      expect(credentials?.username, 'deploy');
      expect(credentials?.password, isNull);
      expect(await controller.passwordOf(identity), isNull);
    });

    test('未加密私钥的空口令归一为 null', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'test-key',
        passphrase: '',
      );
      expect(validator.calls, [('test-key', null)]);
      expect((await controller.credentialsOf(identity))?.passphrase, isNull);
    });

    test('只修改元数据时保留原私钥和口令，不重新校验或覆盖密文', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'old-key',
        passphrase: 'old-phrase',
      );
      await pump();
      final stored = await secrets.read(identity.secretRef!);
      await controller.updateIdentity(
        id: identity.id,
        name: 'renamed',
        username: 'deploy',
        privateKey: '',
        passphrase: '',
      );
      await pump();
      final updated = controller.byId(identity.id)!;
      expect(updated.name, 'renamed');
      expect(updated.username, 'deploy');
      expect(await secrets.read(updated.secretRef!), stored);
      expect(validator.calls, hasLength(1));
    });

    test('重新导入私钥时可替换密钥并清除原口令', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'old-key',
        passphrase: 'old-phrase',
      );
      await pump();
      await controller.updateIdentity(
        id: identity.id,
        name: 'key',
        username: 'root',
        privateKey: 'new-key',
      );
      final credentials = await controller.credentialsOf(identity);
      expect(credentials?.privateKey, 'new-key');
      expect(credentials?.passphrase, isNull);
      expect(validator.calls.last, ('new-key', null));
    });

    test('无效私钥不创建凭证；替换失败保持原凭证', () async {
      validator.error = '私钥格式无效或口令错误';
      await expectLater(
        controller.saveWithPrivateKey(
          name: 'bad',
          username: 'root',
          privateKey: 'invalid',
        ),
        throwsA(isA<SshEngineException>()),
      );
      expect(await repo.getAll(), isEmpty);
      validator.error = null;
      final identity = await controller.saveWithPrivateKey(
        name: 'good',
        username: 'root',
        privateKey: 'good-key',
        passphrase: 'good-phrase',
      );
      await pump();
      validator.error = '私钥格式无效或口令错误';
      await expectLater(
        controller.updateIdentity(
          id: identity.id,
          name: 'bad',
          username: 'other',
          privateKey: 'invalid',
        ),
        throwsA(isA<SshEngineException>()),
      );
      expect((await repo.getAll()).single.name, 'good');
      expect(
        (await controller.credentialsOf(identity))?.privateKey,
        'good-key',
      );
      expect(
        (await controller.credentialsOf(identity))?.passphrase,
        'good-phrase',
      );
    });

    test('不允许无私钥更换口令或变更已有凭证类型', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'test-key',
      );
      await pump();
      await expectLater(
        controller.updateIdentity(
          id: identity.id,
          name: 'key',
          username: 'root',
          passphrase: 'new-phrase',
        ),
        throwsA(isA<SshEngineException>()),
      );
      await expectLater(
        controller.updateIdentity(
          id: identity.id,
          name: 'key',
          username: 'root',
          authType: AuthType.password,
          password: 'password',
        ),
        throwsA(isA<SshEngineException>()),
      );
      expect((await repo.getAll()).single.authType, AuthType.privateKey);
      expect(
        (await controller.credentialsOf(identity))?.privateKey,
        'test-key',
      );
    });

    test('缺失私钥密文返回 null；损坏数据不会泄露密文原文', () async {
      const identity = Identity(
        id: 'key',
        name: 'key',
        username: 'root',
        authType: AuthType.privateKey,
        secretRef: 'key-ref',
      );
      expect(await controller.credentialsOf(identity), isNull);
      for (final stored in [
        'sensitive-invalid-json',
        '{"version":2,"privateKey":"sensitive-key"}',
        '{"version":1,"privateKey":5}',
        '{"version":1,"privateKey":"sensitive-key","passphrase":3}',
      ]) {
        await secrets.put('key-ref', stored);
        await expectLater(
          controller.credentialsOf(identity),
          throwsA(
            isA<SecretStoreException>().having(
              (error) => error.message,
              'safe message',
              '已保存的私钥凭证无法读取，请重新编辑并导入私钥',
            ),
          ),
        );
      }
    });

    test('私钥凭证删除时一并删除密钥和口令', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'test-key',
        passphrase: 'phrase',
      );
      await pump();
      await controller.remove(identity.id);
      await pump();
      expect(await secrets.read(identity.secretRef!), isNull);
      expect(await repo.getAll(), isEmpty);
    });

    test('新建时数据库写入失败清理新密文，重试不留下孤立凭据', () async {
      repo.failNextWrite = true;
      await expectLater(
        controller.saveWithPrivateKey(
          name: 'key',
          username: 'root',
          privateKey: 'new-key',
        ),
        throwsStateError,
      );
      expect(await repo.getAll(), isEmpty);
      expect(secrets.refs, isEmpty);
      final identity = await controller.saveWithPrivateKey(
        name: 'key',
        username: 'root',
        privateKey: 'new-key',
      );
      expect(await repo.getAll(), hasLength(1));
      expect(secrets.refs, {identity.secretRef});
    });

    test('替换时数据库写入失败恢复旧私钥和口令', () async {
      final identity = await controller.saveWithPrivateKey(
        name: 'original',
        username: 'root',
        privateKey: 'old-key',
        passphrase: 'old-phrase',
      );
      await pump();
      repo.failNextWrite = true;
      await expectLater(
        controller.updateIdentity(
          id: identity.id,
          name: 'replacement',
          username: 'deploy',
          privateKey: 'new-key',
          passphrase: 'new-phrase',
        ),
        throwsStateError,
      );
      expect((await repo.getAll()).single.name, 'original');
      final credentials = await controller.credentialsOf(identity);
      expect(credentials?.privateKey, 'old-key');
      expect(credentials?.passphrase, 'old-phrase');
      expect(secrets.refs, {identity.secretRef});
    });

    test('无校验器或空私钥不能落盘', () async {
      final unconfigured = IdentityController(
        repository: repo,
        secretStore: secrets,
      );
      await expectLater(
        unconfigured.saveWithPrivateKey(
          name: 'key',
          username: 'root',
          privateKey: 'test-key',
        ),
        throwsA(isA<SshEngineException>()),
      );
      await expectLater(
        controller.saveWithPrivateKey(
          name: 'key',
          username: 'root',
          privateKey: '   ',
        ),
        throwsA(isA<SshEngineException>()),
      );
      expect(await repo.getAll(), isEmpty);
      expect(validator.calls, isEmpty);
    });
  });
}
