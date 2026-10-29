import 'app_database.dart';
import 'drift_folder_repository.dart';
import 'drift_host_repository.dart';
import 'stored_host_tree_repository.dart';

class DriftHostTreeRepository extends StoredHostTreeRepository {
  DriftHostTreeRepository(this._db, {bool gateways = false})
    : super(
        folders: DriftFolderRepository(_db, gateways: gateways),
        hosts: DriftHostRepository(_db, gateways: gateways),
      );

  final AppDatabase _db;

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);
}
