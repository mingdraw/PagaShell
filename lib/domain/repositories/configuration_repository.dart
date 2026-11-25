import '../entities/connection_configuration.dart';

abstract interface class ConfigurationRepository {
  Future<ConnectionConfiguration> read({
    ConfigurationExportScope scope = const ConfigurationExportScope.all(),
  });

  /// 合并配置，不删除本机独有项；元数据失败时恢复原凭据。
  Future<void> merge(ConnectionConfiguration configuration);
}
