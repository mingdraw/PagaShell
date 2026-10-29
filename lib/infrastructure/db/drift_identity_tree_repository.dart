import 'app_database.dart';
import 'drift_identity_folder_repository.dart';
import 'drift_identity_repository.dart';
import 'stored_identity_tree_repository.dart';

class DriftIdentityTreeRepository extends StoredIdentityTreeRepository {
  DriftIdentityTreeRepository(this._db)
    : super(
        folders: DriftIdentityFolderRepository(_db),
        identities: DriftIdentityRepository(_db),
      );
  final AppDatabase _db;
  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);
}
