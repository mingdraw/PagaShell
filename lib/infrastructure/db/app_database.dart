import 'dart:io' show Platform;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/services/identity_protocol_migration.dart';
import '../storage/application_directories.dart';

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

/// 服务及网关元数据。转发与代理随网关保存，凭据存于系统钥匙串。
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
  TextColumn get proxyConfigJson => text().withDefault(const Constant('{}'))();

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
  TextColumn get rdpDomain => text().nullable()();
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
  @visibleForTesting
  AppDatabase.openAt(String directory)
    : super(_open(directory: () async => directory, tempDirectory: directory));

  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      // 先补齐新列（均按实际 schema 幂等检查），后面的历史迁移会使用生成的整行查询。
      if (from < 14) {
        await _addColumnIfMissing(m, identities, identities.rdpDomain);
      }
      if (from < 13) {
        await _addColumnIfMissing(m, hosts, hosts.proxyConfigJson);
      }
      if (from < 2) await _createTableIfMissing(m, knownHosts);
      if (from < 3) await _createTableIfMissing(m, appSettings);
      if (from < 4) {
        await _createTableIfMissing(m, identityFolders);
        await _addColumnIfMissing(m, identities, identities.folderId);
        await _addColumnIfMissing(m, identities, identities.sortOrder);
      }
      if (from < 5) {
        await _addColumnIfMissing(m, folders, folders.isGateway);
        await _addColumnIfMissing(m, hosts, hosts.isGateway);
        await _addColumnIfMissing(m, hosts, hosts.gatewayId);
      }
      if (from < 8) {
        await _addColumnIfMissing(m, hosts, hosts.forwardPortsJson);
        // 未发布版本的独立转发配置已停用，不迁移旧数据。
        await customStatement('DROP TABLE IF EXISTS forward_rules');
        await customStatement('DROP TABLE IF EXISTS forward_folders');
      }
      if (from < 9) {
        await _addColumnIfMissing(m, hosts, hosts.gatewayType);
        await _addColumnIfMissing(m, hosts, hosts.rdpDomain);
        if (!await _hasColumn(
          knownHosts.actualTableName,
          knownHosts.protocol.$name,
        )) {
          await m.alterTable(
            TableMigration(knownHosts, newColumns: [knownHosts.protocol]),
          );
        }
      }
      if (from < 10) {
        await _addColumnIfMissing(m, hosts, hosts.pageClientId);
        await _addColumnIfMissing(m, hosts, hosts.pageServerFingerprint);
      }
      if (from < 11) {
        await _addColumnIfMissing(m, identities, identities.serviceType);
        final rows = await select(identities).get();
        final hostsUsingCredentials = await (select(
          hosts,
        )..where((h) => h.identityId.isNotNull())).get();
        final usage = <String, Set<ServiceType>>{};
        for (final h in hostsUsingCredentials) {
          if (h.isGateway && h.gatewayType != 'ssh') continue;
          final type = h.isGateway
              ? ServiceType.ssh
              : _parseLegacyServiceType(h.gatewayType);
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
              : _parseLegacyServiceType(h.gatewayType);
          final identityId = converted.bindings[(h.identityId!, type)];
          if (identityId != null && identityId != h.identityId) {
            await (update(hosts)..where((row) => row.id.equals(h.id))).write(
              HostsCompanion(identityId: Value(identityId)),
            );
          }
        }
      }
      if (from < 12) {
        // 转发改为归属网关；用户确认清除旧的服务映射，不推断新的目标地址。
        await customStatement("UPDATE hosts SET forward_ports_json = '[]'");
      }
    },
  );

  static ServiceType _parseLegacyServiceType(String raw) =>
      ServiceType.values.where((type) => type.name == raw).firstOrNull ??
      ServiceType.ssh;

  Future<bool> _hasTable(String name) async {
    final row = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      variables: [Variable.withString(name)],
    ).getSingleOrNull();
    return row != null;
  }

  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info("$table")').get();
    return rows.any((row) => row.read<String>('name') == column);
  }

  Future<void> _createTableIfMissing(
    Migrator m,
    TableInfo<Table, Object?> table,
  ) async {
    if (!await _hasTable(table.actualTableName)) {
      await m.createTable(table);
    }
  }

  Future<void> _addColumnIfMissing(
    Migrator m,
    TableInfo<Table, Object?> table,
    GeneratedColumn<Object> column,
  ) async {
    if (!await _hasColumn(table.actualTableName, column.$name)) {
      await m.addColumn(table, column);
    }
  }

  static Future<String?> _skipTempDirectory() async => null;

  static final _defaultNativeOptions = DriftNativeOptions(
    databaseDirectory: ApplicationDirectories.database,
    // Windows 下 SQLite 默认使用内存临时存储和原生 Win32 GetTempPathW，
    // 跳过写入 sqlite3_temp_directory 全局指针可避免跨 isolate/路径异常。
    tempDirectoryPath: Platform.isWindows ? _skipTempDirectory : null,
    setup: (db) {
      // 必须先设置 busy_timeout，再尝试切换 WAL，避免从旧版 DELETE 模式升级或
      // Windows 杀软/OneDrive/残留进程短暂占用时直接报 SQLITE_BUSY 导致整库打不开。
      db.execute('PRAGMA busy_timeout = 5000;');
      try {
        db
          ..execute('PRAGMA journal_mode = WAL;')
          ..execute('PRAGMA synchronous = NORMAL;');
      } on Object {
        // 网络盘、OneDrive 等不支持 WAL -shm 的目录降级保留默认日志模式，不阻断打开。
      }
    },
  );

  static QueryExecutor _open({
    Future<Object> Function()? directory,
    String? tempDirectory,
  }) => driftDatabase(
    name: 'pagashell',
    native: directory == null && tempDirectory == null
        ? _defaultNativeOptions
        : DriftNativeOptions(
            databaseDirectory: directory ?? ApplicationDirectories.database,
            tempDirectoryPath: tempDirectory == null
                ? (Platform.isWindows ? _skipTempDirectory : null)
                : () async => tempDirectory,
            setup: _defaultNativeOptions.setup,
          ),
  );
}
