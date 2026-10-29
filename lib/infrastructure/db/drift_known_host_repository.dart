import 'package:drift/drift.dart';

import '../../domain/repositories/known_host_repository.dart';
import '../../domain/ssh/host_key.dart';
import 'app_database.dart';

class DriftKnownHostRepository implements KnownHostRepository {
  DriftKnownHostRepository(this._db);

  final AppDatabase _db;

  static String _normalize(String hostname) => hostname.trim().toLowerCase();

  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async {
    final row =
        await (_db.select(_db.knownHosts)..where(
              (h) =>
                  h.hostname.equals(_normalize(hostname)) &
                  h.port.equals(port) &
                  h.protocol.equals(protocol.name),
            ))
            .getSingleOrNull();
    return row == null
        ? null
        : SshHostKey(
            hostname: row.hostname,
            port: row.port,
            keyType: row.keyType,
            fingerprint: row.fingerprint,
            protocol: protocol,
          );
  }

  @override
  Future<bool> trustIfAbsent(SshHostKey key) => _db.transaction(() async {
    await _db
        .into(_db.knownHosts)
        .insert(
          KnownHostsCompanion.insert(
            hostname: _normalize(key.hostname),
            port: key.port,
            keyType: key.keyType,
            fingerprint: key.fingerprint,
            protocol: Value(key.protocol.name),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (await find(
      key.hostname,
      key.port,
      protocol: key.protocol,
    ))!.matches(key);
  });

  @override
  Future<bool> removeIfMatches(SshHostKey key) async =>
      await (_db.delete(_db.knownHosts)..where(
            (h) =>
                h.hostname.equals(_normalize(key.hostname)) &
                h.port.equals(key.port) &
                h.protocol.equals(key.protocol.name) &
                h.keyType.equals(key.keyType) &
                h.fingerprint.equals(key.fingerprint),
          ))
          .go() >
      0;
}
