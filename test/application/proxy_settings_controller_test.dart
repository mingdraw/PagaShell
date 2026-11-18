import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/in_memory_settings_repository.dart';

class _CorruptedProxyRepository extends InMemorySettingsRepository {
  @override
  Future<AppProxySettings> readProxySettings() async =>
      throw const FormatException('corrupted');
}

class _FailingProxySaveRepository extends InMemorySettingsRepository {
  @override
  Future<void> saveProxySettings(AppProxySettings settings) async {
    throw StateError('disk full');
  }
}

void main() {
  test('代理模式切换保留手动配置，密码写入 SecretStore 并可更新与清除', () async {
    final repository = InMemorySettingsRepository();
    final secretStore = InMemorySecretStore();
    final controller = SettingsController(
      repository: repository,
      secretStore: secretStore,
    );
    await controller.ready;
    expect(controller.proxySettings.value.mode, AppProxyMode.auto);

    await controller.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.socks5,
      address: '127.0.0.1:1080',
      username: 'alice',
      password: 'secret-1',
    );
    final firstRef = controller.proxySettings.value.passwordSecretRef;
    expect(firstRef, isNotEmpty);
    expect(await secretStore.read(firstRef), 'secret-1');
    expect(repository.proxySettings.mode, AppProxyMode.manual);
    expect(repository.proxySettings.address, '127.0.0.1:1080');

    // 切换为关闭再切回手动时，保留之前的手动字段与密钥引用。
    await controller.saveProxySettings(mode: AppProxyMode.off);
    expect(controller.proxySettings.value.mode, AppProxyMode.off);
    expect(controller.proxySettings.value.address, '127.0.0.1:1080');
    expect(await controller.readProxyPassword(), 'secret-1');

    // 留空密码时保留原密文；替换密码时清理旧密文。
    await controller.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.http,
      address: '127.0.0.1:7890',
      username: 'bob',
    );
    expect(controller.proxySettings.value.passwordSecretRef, firstRef);
    expect(await secretStore.read(firstRef), 'secret-1');

    await controller.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.https,
      address: 'proxy.example.com:443',
      username: 'bob',
      password: 'secret-2',
    );
    final secondRef = controller.proxySettings.value.passwordSecretRef;
    expect(secondRef, isNot(firstRef));
    expect(await secretStore.read(secondRef), 'secret-2');
    expect(await secretStore.read(firstRef), isNull);

    // 清除密码时删除 SecretStore 记录。
    await controller.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.https,
      address: 'proxy.example.com:443',
      username: '',
      clearPassword: true,
    );
    expect(controller.proxySettings.value.hasSavedPassword, isFalse);
    expect(await secretStore.read(secondRef), isNull);
  });

  test('读取失败标记 proxyLoadFailed 并支持重载，保存失败保留旧设置', () async {
    final corrupted = SettingsController(
      repository: _CorruptedProxyRepository(),
      secretStore: InMemorySecretStore(),
    );
    await corrupted.ready;
    expect(corrupted.proxyLoadFailed.value, isTrue);
    await expectLater(
      corrupted.saveProxySettings(mode: AppProxyMode.off),
      throwsA(isA<ProxySettingsException>()),
    );

    final failing = SettingsController(
      repository: _FailingProxySaveRepository(),
      secretStore: InMemorySecretStore(),
    );
    await failing.ready;
    await expectLater(
      failing.saveProxySettings(mode: AppProxyMode.off),
      throwsA(isA<ProxySettingsException>()),
    );
    expect(failing.proxySettings.value.mode, AppProxyMode.auto);
  });
}
