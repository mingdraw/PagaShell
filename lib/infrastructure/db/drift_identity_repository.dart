import 'package:drift/drift.dart';

import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/repositories/identity_repository.dart';
import 'app_database.dart';

/// 凭证的 drift(SQLite) 持久化实现（仅元数据；密文在 SecretStore）。
class DriftIdentityRepository implements IdentityRepository {
  DriftIdentityRepository(this._db);

  final AppDatabase _db;

  Identity _toEntity(IdentityRow row) => Identity(
    id: row.id,
    name: row.name,
    username: row.username,
    authType:
        AuthType.values[row.authType.clamp(0, AuthType.values.length - 1)],
    secretRef: row.secretRef,
    folderId: row.folderId,
    sortOrder: row.sortOrder,
    serviceType: ServiceType.values.byName(row.serviceType),
  );

  @override
  Stream<List<Identity>> watchAll() => _db
      .select(_db.identities)
      .watch()
      .map((rows) => rows.map(_toEntity).toList());

  @override
  Future<List<Identity>> getAll() async =>
      (await _db.select(_db.identities).get()).map(_toEntity).toList();

  @override
  Future<void> upsert(Identity identity) => _db
      .into(_db.identities)
      .insertOnConflictUpdate(
        IdentitiesCompanion.insert(
          id: identity.id,
          name: identity.name,
          username: identity.username,
          authType: Value(identity.authType.index),
          serviceType: Value(identity.serviceType.name),
          secretRef: Value(identity.secretRef),
          folderId: Value(identity.folderId),
          sortOrder: Value(identity.sortOrder),
        ),
      );

  @override
  Future<bool> isReferenced(String id) async =>
      await (_db.select(_db.hosts)
            ..where(
              (host) =>
                  host.identityId.equals(id) &
                  (host.isGateway.equals(false) |
                      host.gatewayType.equals('ssh')),
            )
            ..limit(1))
          .getSingleOrNull() !=
      null;

  @override
  Future<void> remove(String id) => _db.transaction(() async {
    if (await isReferenced(id)) {
      throw StateError('凭证正在被网关或服务使用，请先修改对应的凭证配置');
    }
    // Retired gateway records are hidden and cannot keep a credential in use.
    await (_db.update(_db.hosts)..where(
          (host) => host.isGateway.equals(true) & host.identityId.equals(id),
        ))
        .write(const HostsCompanion(identityId: Value(null)));
    await (_db.delete(_db.identities)..where((i) => i.id.equals(id))).go();
  });
}
