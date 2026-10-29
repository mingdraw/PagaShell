import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/vault/secure_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const store = SecureSecretStore(FlutterSecureStorage());
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('平台读写删除异常明确失败，不泄露异常原文', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'locked', message: 'sensitive-sentinel');
    });
    for (final operation in [
      () => store.put('ref', 'sensitive-sentinel'),
      () => store.read('ref'),
      () => store.delete('ref'),
    ]) {
      await expectLater(
        operation(),
        throwsA(
          isA<SecretStoreException>()
              .having((e) => e.toString(), 'safe message', contains('系统钥匙串'))
              .having(
                (e) => e.toString(),
                'no secret',
                isNot(contains('sensitive-sentinel')),
              ),
        ),
      );
    }
  });

  test('不存在的密文可以读取为 null，删除不调用平台删除', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    expect(await store.read('missing'), isNull);
    await store.delete('missing');
    expect(calls, ['read', 'read']);
  });

  test('系统钥匙串写入失败不会创建看似成功的凭证元数据', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'locked');
    });
    final repository = InMemoryIdentityRepository();
    addTearDown(repository.dispose);
    final controller = IdentityController(
      repository: repository,
      secretStore: store,
    );
    await expectLater(
      controller.saveWithPassword(
        name: 'test',
        username: 'test',
        password: 'secret',
      ),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await repository.getAll(), isEmpty);
  });
}
