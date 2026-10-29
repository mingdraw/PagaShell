import '../entities/folder.dart';
import '../entities/identity.dart';
import '../entities/identity_tree_item.dart';

abstract class IdentityTreeRepository {
  Future<Folder> saveFolder(Folder folder);
  Future<Identity> saveIdentity(Identity identity);
  Future<void> move(IdentityTreeItem item, IdentityTreePlacement placement);
  Future<void> removeFolder(String id);
}
