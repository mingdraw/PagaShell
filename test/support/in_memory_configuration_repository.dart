import 'package:pagashell/infrastructure/db/stored_configuration_repository.dart';

class InMemoryConfigurationRepository extends StoredConfigurationRepository {
  InMemoryConfigurationRepository({
    required super.serviceFolders,
    required super.services,
    required super.gatewayFolders,
    required super.gateways,
    required super.identityFolders,
    required super.identities,
    required super.secretStore,
  });

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      Future<T>.sync(action);
}
