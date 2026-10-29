import '../../domain/entities/folder.dart';
import '../../domain/entities/identity.dart';
import '../../domain/entities/identity_tree_item.dart';
import '../../domain/repositories/identity_folder_repository.dart';
import '../../domain/repositories/identity_repository.dart';
import '../../domain/repositories/identity_tree_repository.dart';
import '../../domain/services/identity_tree.dart';

/// 所有树变更在一次事务内读取权威快照、校验并提交，不操作凭证密文。
abstract class StoredIdentityTreeRepository implements IdentityTreeRepository {
  StoredIdentityTreeRepository({
    required this.folders,
    required this.identities,
  });
  final IdentityFolderRepository folders;
  final IdentityRepository identities;
  Future<T> transaction<T>(Future<T> Function() action);

  Future<IdentityTreeSnapshot> _snapshot() async => IdentityTreeSnapshot(
    folders: await folders.getAll(),
    identities: await identities.getAll(),
  );
  @override
  Future<Folder> saveFolder(Folder folder) => transaction(() async {
    final saved = (await _snapshot()).prepareFolder(folder);
    await folders.upsert(saved);
    return saved;
  });
  @override
  Future<Identity> saveIdentity(Identity identity) => transaction(() async {
    final saved = (await _snapshot()).prepareIdentity(identity);
    await identities.upsert(saved);
    return saved;
  });
  @override
  Future<void> move(IdentityTreeItem item, IdentityTreePlacement placement) =>
      transaction(() async {
        await _apply((await _snapshot()).planMove(item, placement));
      });
  @override
  Future<void> removeFolder(String id) => transaction(() async {
    await _apply((await _snapshot()).planRemoveFolder(id));
  });

  Future<void> _apply(IdentityTreeChanges changes) async {
    for (final folder in changes.folders) {
      await folders.upsert(folder);
    }
    for (final identity in changes.identities) {
      await identities.upsert(identity);
    }
    final removed = changes.removedFolderId;
    if (removed != null) await folders.remove(removed);
  }
}
