import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/services/identity_protocol_migration.dart';

part 'app_database.g.dart';

/// 文件夹（可嵌套）。
@DataClassName('FolderRow')
class Folders extends Table {
  BoolColumn get isGateway => boolean().withDefault(const Constant(false))();
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 凭证分组与主机分组分开存储。
@DataClassName('IdentityFolderRow')
class IdentityFolders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 服务及网关元数据。端口映射随服务保存，凭据存于系统钥匙串。
@DataClassName('HostRow')
class Hosts extends Table {
  BoolColumn get isGateway => boolean().withDefault(const Constant(false))();
  TextColumn get gatewayId => text().nullable()();
  TextColumn get gatewayType => text().withDefault(const Constant('ssh'))();
  TextColumn get rdpDomain => text().withDefault(const Constant(''))();
  TextColumn get pageClientId => text().withDefault(const Constant(''))();
  TextColumn get pageServerFingerprint =>
      text().withDefault(const Constant(''))();
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get hostname => text()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text().withDefault(const Constant('root'))();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get tags => text().withDefault(const Constant(''))();
  TextColumn get folderId => text().nullable()();
  TextColumn get identityId => text().nullable()();
  IntColumn get colorValue => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get forwardPortsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 凭证（登录身份）。仅元数据；密文经 SecretStore 存于系统钥匙串。
@DataClassName('IdentityRow')
class Identities extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get username => text()();
  IntColumn get authType => integer().withDefault(const Constant(0))();
  TextColumn get serviceType => text().withDefault(const Constant('ssh'))();
  TextColumn get secretRef => text().nullable()();
  TextColumn get folderId => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 按地址和端口保存用户确认的服务器主机密钥摘要。
@DataClassName('KnownHostRow')
class KnownHosts extends Table {
  TextColumn get protocol => text().withDefault(const Constant('ssh'))();
  TextColumn get hostname => text()();
  IntColumn get port => integer()();
  TextColumn get keyType => text()();
  TextColumn get fingerprint => text()();

  @override
  Set<Column> get primaryKey => {hostname, port, protocol};
}

/// 非敏感的应用偏好，以稳定键名保存。
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 本地配置和加密对话数据库；凭据与 API Key 由独立保险库管理。
@DriftDatabase(
  tables: [
    Folders,
    IdentityFolders,
    Hosts,
    Identities,
    KnownHosts,
    AppSettings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(knownHosts);
      if (from < 3) await m.createTable(appSettings);
      if (from < 4) {
        await m.createTable(identityFolders);
        await m.addColumn(identities, identities.folderId);
        await m.addColumn(identities, identities.sortOrder);
      }
      if (from < 5) {
        await m.addColumn(folders, folders.isGateway);
        await m.addColumn(hosts, hosts.isGateway);
        await m.addColumn(hosts, hosts.gatewayId);
      }
      if (from < 8) {
        await m.addColumn(hosts, hosts.forwardPortsJson);
        // 未发布版本的独立转发配置已停用，不迁移旧数据。
        await customStatement('DROP TABLE IF EXISTS forward_rules');
        await customStatement('DROP TABLE IF EXISTS forward_folders');
      }
      if (from < 9) {
        await m.addColumn(hosts, hosts.gatewayType);
        await m.addColumn(hosts, hosts.rdpDomain);
        await m.alterTable(
          TableMigration(knownHosts, newColumns: [knownHosts.protocol]),
        );
      }
      if (from < 10) {
        await m.addColumn(hosts, hosts.pageClientId);
        await m.addColumn(hosts, hosts.pageServerFingerprint);
      }
      if (from < 11) {
        await m.addColumn(identities, identities.serviceType);
        final rows = await select(identities).get();
        final hostsUsingCredentials = await (select(
          hosts,
        )..where((h) => h.identityId.isNotNull())).get();
        final usage = <String, Set<ServiceType>>{};
        for (final h in hostsUsingCredentials) {
          if (h.isGateway && h.gatewayType != 'ssh') continue;
          final type = h.isGateway
              ? ServiceType.ssh
              : ServiceType.values.byName(h.gatewayType);
          (usage[h.identityId!] ??= {}).add(type);
        }
        final converted = IdentityProtocolMigration([
          for (final r in rows)
            Identity(
              id: r.id,
              name: r.name,
              username: r.username,
              authType: AuthType
                  .values[r.authType.clamp(0, AuthType.values.length - 1)],
              secretRef: r.secretRef,
              folderId: r.folderId,
              sortOrder: r.sortOrder,
            ),
        ], usage);
        for (final i in converted.identities) {
          await into(identities).insertOnConflictUpdate(
            IdentitiesCompanion.insert(
              id: i.id,
              name: i.name,
              username: i.username,
              authType: Value(i.authType.index),
              serviceType: Value(i.serviceType.name),
              secretRef: Value(i.secretRef),
              folderId: Value(i.folderId),
              sortOrder: Value(i.sortOrder),
            ),
          );
        }
        for (final h in hostsUsingCredentials) {
          if (h.isGateway && h.gatewayType != 'ssh') continue;
          final type = h.isGateway
              ? ServiceType.ssh
              : ServiceType.values.byName(h.gatewayType);
          final identityId = converted.bindings[(h.identityId!, type)];
          if (identityId != null && identityId != h.identityId) {
            await (update(hosts)..where((row) => row.id.equals(h.id))).write(
              HostsCompanion(identityId: Value(identityId)),
            );
          }
        }
      }
    },
  );

  static QueryExecutor _open() => driftDatabase(name: 'pagashell');
}
