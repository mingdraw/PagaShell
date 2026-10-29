import 'package:drift/drift.dart';

import '../../domain/entities/folder.dart';
import '../../domain/repositories/identity_folder_repository.dart';
import 'app_database.dart';

class DriftIdentityFolderRepository implements IdentityFolderRepository {
  DriftIdentityFolderRepository(this._db);
  final AppDatabase _db;

  Folder _toEntity(IdentityFolderRow row) => Folder(
    id: row.id,
    name: row.name,
    parentId: row.parentId,
    sortOrder: row.sortOrder,
  );
  @override
  Stream<List<Folder>> watchAll() => _db
      .select(_db.identityFolders)
      .watch()
      .map((rows) => rows.map(_toEntity).toList());
  @override
  Future<List<Folder>> getAll() async =>
      (await _db.select(_db.identityFolders).get()).map(_toEntity).toList();
  @override
  Future<void> upsert(Folder folder) => _db
      .into(_db.identityFolders)
      .insertOnConflictUpdate(
        IdentityFoldersCompanion.insert(
          id: folder.id,
          name: folder.name,
          parentId: Value(folder.parentId),
          sortOrder: Value(folder.sortOrder),
        ),
      );
  @override
  Future<void> remove(String id) =>
      (_db.delete(_db.identityFolders)..where((row) => row.id.equals(id))).go();
}
