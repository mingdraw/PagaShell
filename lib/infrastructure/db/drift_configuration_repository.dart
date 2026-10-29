import '../../domain/entities/connection_configuration.dart';
import '../../domain/vault/secret_store.dart';
import 'app_database.dart';
import 'drift_folder_repository.dart';
import 'drift_host_repository.dart';
import 'drift_identity_folder_repository.dart';
import 'drift_identity_repository.dart';
import 'stored_configuration_repository.dart';

class DriftConfigurationRepository extends StoredConfigurationRepository {
  DriftConfigurationRepository(this._db, SecretStore secretStore)
    : super(
        serviceFolders: DriftFolderRepository(_db),
        services: DriftHostRepository(_db),
        gatewayFolders: DriftFolderRepository(_db, gateways: true),
        gateways: DriftHostRepository(_db, gateways: true),
        identityFolders: DriftIdentityFolderRepository(_db),
        identities: DriftIdentityRepository(_db),
        secretStore: secretStore,
      );

  final AppDatabase _db;

  @override
  Future<void> validateImportNamespace(ConnectionConfiguration incoming) async {
    final hostGroups = {
      for (final host in incoming.services) host.id: false,
      for (final host in incoming.gateways) host.id: true,
    };
    final folderGroups = {
      for (final folder in incoming.serviceFolders) folder.id: false,
      for (final folder in incoming.gatewayFolders) folder.id: true,
    };
    // 包括已停用、界面不再展示的旧网关行，不能跨分组覆盖这些 ID。
    for (final row in await _db.select(_db.hosts).get()) {
      if (hostGroups.containsKey(row.id) &&
          hostGroups[row.id] != row.isGateway) {
        throw const ConfigurationException('配置文件内容无效或引用不完整');
      }
    }
    for (final row in await _db.select(_db.folders).get()) {
      if (folderGroups.containsKey(row.id) &&
          folderGroups[row.id] != row.isGateway) {
        throw const ConfigurationException('配置文件内容无效或引用不完整');
      }
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);
}
