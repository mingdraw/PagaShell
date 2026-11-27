import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/system_proxy.dart';

abstract interface class SystemProxyBackend {
  Future<UpstreamProxyConfig?> inspectUpstream(ProxyConfig config);
  Future<UpstreamProxyConfig?> enable(String owner, ProxyConfig config);
  Future<void> restore(String owner);
}
