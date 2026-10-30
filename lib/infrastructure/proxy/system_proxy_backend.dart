import '../../domain/entities/proxy_config.dart';

abstract interface class SystemProxyBackend {
  Future<void> enable(String owner, ProxyConfig config);
  Future<void> restore(String owner);
}
