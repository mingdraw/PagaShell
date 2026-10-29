import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

class _SecretStore extends InMemorySecretStore {
  bool failDelete = false;
  bool failRestore = false;

  @override
  Future<void> delete(String ref) async {
    if (failDelete) throw const SecretStoreException('钥匙串不可用');
    await super.delete(ref);
  }

  @override
  Future<void> put(String ref, String secret) async {
    if (failRestore) throw const SecretStoreException('钥匙串不可用');
    await super.put(ref, secret);
  }
}

class _GatewayRepository extends InMemoryHostRepository {
  bool rejectDelete = false;

  @override
  Future<void> remove(String id) async {
    if (rejectDelete) throw StateError('网关正在被服务使用，请先修改服务的网关配置');
    await super.remove(id);
  }
}

void main() {
  test('钥匙串失败保留网关，存储拒绝删除时恢复密码，恢复失败明确提示', () async {
    final gateways = _GatewayRepository();
    final folders = InMemoryFolderRepository();
    final services = InMemoryHostRepository();
    final store = _SecretStore();
    final controller = GatewayController(
      repository: gateways,
      secretStore: store,
      treeRepository: InMemoryHostTreeRepository(
        folders: folders,
        hosts: gateways,
      ),
      services: services,
    );
    addTearDown(gateways.dispose);
    addTearDown(folders.dispose);
    addTearDown(services.dispose);
    await controller.save(
      const Host(id: 'gateway', name: 'Gateway', hostname: 'gateway.test'),
    );
    await controller.savePassword('gateway', 'test-only-secret');
    store.failDelete = true;
    await expectLater(
      controller.remove('gateway'),
      throwsA(isA<SecretStoreException>()),
    );
    expect(await gateways.getAll(), hasLength(1));
    expect(await controller.passwordOf('gateway'), 'test-only-secret');
    store.failDelete = false;
    gateways.rejectDelete = true;
    await expectLater(controller.remove('gateway'), throwsStateError);
    expect(await gateways.getAll(), hasLength(1));
    expect(await controller.passwordOf('gateway'), 'test-only-secret');
    store.failRestore = true;
    await expectLater(
      controller.remove('gateway'),
      throwsA(
        isA<SecretStoreException>().having(
          (e) => e.message,
          'message',
          contains('密码恢复失败'),
        ),
      ),
    );
    expect(await gateways.getAll(), hasLength(1));
  });
}
