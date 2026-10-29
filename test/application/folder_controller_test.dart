import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';

void main() {
  group('FolderController', () {
    late InMemoryFolderRepository folderRepo;
    late InMemoryHostRepository hostRepo;
    late FolderController controller;

    setUp(() {
      folderRepo = InMemoryFolderRepository();
      hostRepo = InMemoryHostRepository();
      controller = FolderController(
        folderRepository: folderRepo,
        hostRepository: hostRepo,
        treeRepository: InMemoryHostTreeRepository(
          folders: folderRepo,
          hosts: hostRepo,
        ),
      )..onInit();
    });

    tearDown(() {
      controller.onClose();
      folderRepo.dispose();
      hostRepo.dispose();
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('创建嵌套文件夹并按父级归类', () async {
      final prod = await controller.create(name: '生产');
      final db = await controller.create(name: '数据库', parentId: prod.id);
      await pump();

      expect(controller.childrenOf(null).single.id, prod.id);
      expect(controller.childrenOf(prod.id).single.id, db.id);
    });

    test('pathOf 返回全路径', () async {
      final prod = await controller.create(name: '生产');
      final db = await controller.create(name: '数据库', parentId: prod.id);
      await pump();

      expect(controller.pathOf(db.id), '生产 / 数据库');
    });

    test('创建子文件夹时自动展开父级', () async {
      final prod = await controller.create(name: '生产');
      await controller.create(name: '数据库', parentId: prod.id);

      expect(controller.isExpanded(prod.id), isTrue);
    });

    test('删除文件夹时子文件夹与主机上移到父级', () async {
      final prod = await controller.create(name: '生产');
      final db = await controller.create(name: '数据库', parentId: prod.id);
      final sub = await controller.create(name: '主库', parentId: db.id);
      await hostRepo.upsert(
        const Host(
          id: 'h1',
          name: 'pg-01',
          hostname: '10.0.0.5',
        ).copyWith(folderId: 'placeholder'),
      );
      // 把主机归到 db 文件夹。
      await hostRepo.upsert(
        (await hostRepo.getAll()).single.copyWith(folderId: db.id),
      );
      await pump();

      await controller.remove(db.id);
      await pump();

      // 子文件夹 sub 上移到 prod。
      expect(controller.byId(sub.id)?.parentId, prod.id);
      // 主机上移到 prod。
      expect((await hostRepo.getAll()).single.folderId, prod.id);
      // db 已删除。
      expect(controller.byId(db.id), isNull);
    });

    test('删除根级文件夹时其内容变为未分组', () async {
      final prod = await controller.create(name: '生产');
      await hostRepo.upsert(
        const Host(id: 'h1', name: 'pg-01', hostname: '10.0.0.5'),
      );
      await hostRepo.upsert(
        (await hostRepo.getAll()).single.copyWith(folderId: prod.id),
      );
      await pump();

      await controller.remove(prod.id);
      await pump();

      expect((await hostRepo.getAll()).single.folderId, isNull);
    });

    test('同级下重名文件夹被拒绝，不同层级允许同名', () async {
      final prod = await controller.create(name: '生产');
      await pump();

      await expectLater(controller.create(name: '生产'), throwsArgumentError);
      // 不同层级允许同名。
      final nested = await controller.create(name: '生产', parentId: prod.id);
      await pump();
      expect(controller.byId(nested.id)?.parentId, prod.id);
    });

    test('重命名为同级已有名称被拒绝，改回自身名称允许', () async {
      await controller.create(name: 'A');
      final b = await controller.create(name: 'B');
      await pump();

      await expectLater(controller.rename(b.id, 'A'), throwsArgumentError);
      await controller.rename(b.id, 'B'); // 自身名称不冲突。
      await pump();
      expect(controller.byId(b.id)?.name, 'B');
    });

    test('删除文件夹上移内容时与同级重名自动加后缀', () async {
      final a = await controller.create(name: 'A');
      await controller.create(name: 'X'); // 根级已有同名文件夹。
      await controller.create(name: 'X', parentId: a.id);
      await hostRepo.upsert(
        const Host(id: 'h1', name: 'web', hostname: '1.1.1.1'),
      );
      await hostRepo.upsert(
        Host(id: 'h2', name: 'web', hostname: '2.2.2.2', folderId: a.id),
      );
      await pump();

      await controller.remove(a.id);
      await pump();

      expect(
        controller.childrenOf(null).map((f) => f.name),
        containsAll(['X', 'X (2)']),
      );
      expect(
        (await hostRepo.getAll()).map((h) => h.name),
        containsAll(['web', 'web (2)']),
      );
    });

    test('toggleExpanded 切换展开状态', () async {
      final prod = await controller.create(name: '生产');
      expect(controller.isExpanded(prod.id), isFalse);
      controller.toggleExpanded(prod.id);
      expect(controller.isExpanded(prod.id), isTrue);
      controller.toggleExpanded(prod.id);
      expect(controller.isExpanded(prod.id), isFalse);
    });
  });
}
