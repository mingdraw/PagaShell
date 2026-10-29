import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

const _web = Host(id: 'h1', name: 'web-01', hostname: '10.0.0.5');
const _db = Host(id: 'h2', name: 'db-01', hostname: '10.0.0.6', tags: ['prod']);

void main() {
  group('HostController', () {
    late InMemoryHostRepository repo;
    late InMemoryFolderRepository folders;
    late InMemorySecretStore secretStore;
    late HostController controller;

    setUp(() async {
      repo = InMemoryHostRepository();
      folders = InMemoryFolderRepository();
      await folders.upsert(const Folder(id: 'f1', name: '生产'));
      secretStore = InMemorySecretStore();
      controller = HostController(
        repository: repo,
        secretStore: secretStore,
        treeRepository: InMemoryHostTreeRepository(
          folders: folders,
          hosts: repo,
        ),
      )..onInit();
    });

    tearDown(() {
      controller.onClose();
      repo.dispose();
      folders.dispose();
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('save 后列表更新且按名称排序', () async {
      await controller.save(_web);
      await controller.save(_db);
      await pump();

      expect(controller.sorted.map((h) => h.name), ['db-01', 'web-01']);
    });

    test('搜索词过滤名称与标签', () async {
      await controller.save(_web);
      await controller.save(_db);
      await pump();

      controller.searchQuery.value = 'prod';
      expect(controller.filtered.single.id, _db.id);

      controller.searchQuery.value = 'web';
      expect(controller.filtered.single.id, _web.id);

      controller.searchQuery.value = '';
      expect(controller.filtered.length, 2);
    });

    test('同级下重名主机被拒绝，不同文件夹与编辑自身允许', () async {
      await controller.save(_web);
      await pump();

      // 根级已有 web-01，再存同名同级主机 → 拒绝。
      await expectLater(
        controller.save(
          const Host(id: 'h9', name: 'web-01', hostname: '9.9.9.9'),
        ),
        throwsArgumentError,
      );
      // 同名但在其他文件夹 → 允许。
      await controller.save(
        const Host(
          id: 'h10',
          name: 'web-01',
          hostname: '9.9.9.9',
          folderId: 'f1',
        ),
      );
      // 编辑自身（名称不变）→ 允许。
      await controller.save(_web.copyWith(note: 'updated'));
      await pump();

      expect(controller.hosts.length, 2);
    });

    test('remove 后从列表消失', () async {
      await controller.save(_web);
      await pump();
      await controller.remove(_web.id);
      await pump();

      expect(controller.hosts, isEmpty);
    });

    test('moveToFolder 移动主机，目标同级重名时拒绝', () async {
      await controller.save(_web);
      await pump();

      await controller.moveToFolder(_web.id, 'f1');
      await pump();
      expect(controller.hosts.single.folderId, 'f1');

      // 已在目标层级 → 无操作不报错。
      await controller.moveToFolder(_web.id, 'f1');

      // 根级再建同名主机，移入 f1 与已有 web-01 冲突 → 拒绝。
      await controller.save(
        const Host(id: 'h9', name: 'web-01', hostname: '9.9.9.9'),
      );
      await pump();
      await expectLater(
        controller.moveToFolder('h9', 'f1'),
        throwsArgumentError,
      );
    });

    test('主机自有密码：保存/读取/清除', () async {
      expect(await controller.passwordOf(_web.id), isNull);

      await controller.savePassword(_web.id, 's3cret');
      expect(await controller.passwordOf(_web.id), 's3cret');

      await controller.clearPassword(_web.id);
      expect(await controller.passwordOf(_web.id), isNull);
    });

    test('删除主机时一并清除其自有密码', () async {
      await controller.save(_web);
      await controller.savePassword(_web.id, 's3cret');
      await pump();

      await controller.remove(_web.id);

      expect(await controller.passwordOf(_web.id), isNull);
    });
  });
}
