import 'package:drift/drift.dart';

import '../../domain/entities/folder.dart';
import '../../domain/repositories/folder_repository.dart';
import 'app_database.dart';

/// 文件夹的 drift(SQLite) 持久化实现。
class DriftFolderRepository implements FolderRepository {
  DriftFolderRepository(this._db, {this.gateways = false});

  final AppDatabase _db;
  final bool gateways;

  SimpleSelectStatement<$FoldersTable, FolderRow> get _query =>
      _db.select(_db.folders)..where((f) => f.isGateway.equals(gateways));

  Folder _toEntity(FolderRow row) => Folder(
    id: row.id,
    name: row.name,
    parentId: row.parentId,
    sortOrder: row.sortOrder,
  );

  @override
  Stream<List<Folder>> watchAll() =>
      _query.watch().map((rows) => rows.map(_toEntity).toList());

  @override
  Future<List<Folder>> getAll() async =>
      (await _query.get()).map(_toEntity).toList();

  @override
  Future<void> upsert(Folder folder) => _db
      .into(_db.folders)
      .insertOnConflictUpdate(
        FoldersCompanion.insert(
          id: folder.id,
          name: folder.name,
          parentId: Value(folder.parentId),
          sortOrder: Value(folder.sortOrder),
          isGateway: Value(gateways),
        ),
      );

  @override
  Future<void> remove(String id) => (_db.delete(
    _db.folders,
  )..where((f) => f.id.equals(id) & f.isGateway.equals(gateways))).go();
}
