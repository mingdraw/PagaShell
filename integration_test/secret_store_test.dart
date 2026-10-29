import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/infrastructure/vault/encrypted_secret_store.dart';
import 'package:pagashell/infrastructure/vault/encrypted_vault_storage.dart';
import 'package:pagashell/infrastructure/vault/secure_secret_store.dart';

/// 真机钥匙串回路测试（需要桌面设备）：
///
///   flutter test integration_test/secret_store_test.dart -d macos
///
/// 验证与 AppBinding 相同配置下密文能真正写入/读回系统钥匙串——
/// 单元测试用内存实现摸不到平台层，此前 macOS 上曾因默认走
/// Data Protection Keychain 而报 -34018（缺 keychain-access-groups 授权）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('钥匙串 put/read/delete 回路', () async {
    // 与 AppBinding 保持一致的配置。
    const store = SecureSecretStore(
      FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ),
    );
    const ref = 'sec-integration-test';

    await store.put(ref, 's3cret-roundtrip');
    expect(await store.read(ref), 's3cret-roundtrip');

    await store.put(ref, 'overwritten');
    expect(await store.read(ref), 'overwritten');

    await store.delete(ref);
    expect(await store.read(ref), isNull);
  });

  test('删除不存在的条目静默跳过，不触发钥匙串错误', () async {
    const store = SecureSecretStore(
      FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ),
    );

    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      // 插件在 macOS 传统钥匙串上删除不存在的条目会误报 -34018，
      // SecureSecretStore 以先读后删规避——不应产生任何失败日志。
      await store.delete('sec-never-existed');
    } finally {
      debugPrint = original;
    }

    expect(logs.where((m) => m.contains('SecureSecretStore')), isEmpty);
  });

  test('macOS 单主密钥保险库迁移和重新打开回路', () async {
    const keychain = SecureSecretStore(
      FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ),
    );
    final id = DateTime.now().microsecondsSinceEpoch;
    final keyRef = 'pagashell-integration-vault-key-$id';
    final legacyRef = 'sec-integration-legacy-$id';
    final serviceRef = 'sec-integration-service-$id';
    final gatewayRef = 'sec-integration-gateway-$id';
    final identityRef = 'sec-integration-identity-$id';
    final directory = await Directory.systemTemp.createTemp('pagashell-vault-');
    final storage = FileEncryptedVaultStorage(directory: () async => directory);
    EncryptedSecretStore open() => EncryptedSecretStore(
      keychain: keychain,
      storage: storage,
      keyRef: keyRef,
    );
    try {
      await keychain.put(legacyRef, 'test-legacy-password');
      final store = open();
      expect(await store.read(legacyRef), 'test-legacy-password');
      expect(await keychain.read(legacyRef), isNull);
      await store.put(serviceRef, 'test-service-password');
      await store.put(gatewayRef, 'test-gateway-password');
      await store.put(identityRef, 'test-private-key-and-phrase');
      final nextRun = open();
      expect(await nextRun.read(legacyRef), 'test-legacy-password');
      expect(await nextRun.read(serviceRef), 'test-service-password');
      expect(await nextRun.read(gatewayRef), 'test-gateway-password');
      expect(await nextRun.read(identityRef), 'test-private-key-and-phrase');
      await nextRun.put(serviceRef, 'test-updated-password');
      expect(await store.read(serviceRef), 'test-updated-password');
      await store.delete(identityRef);
      expect(await open().read(identityRef), isNull);
    } finally {
      await keychain.delete(legacyRef);
      await keychain.delete(keyRef);
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
