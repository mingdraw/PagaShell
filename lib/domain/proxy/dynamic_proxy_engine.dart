import '../entities/proxy_config.dart';
import '../ssh/host_key.dart';
import '../ssh/ssh_engine.dart';

abstract interface class DynamicProxyEngine {
  /// Binds all enabled listeners atomically through the selected gateway.
  Future<DynamicProxySession> startProxy(
    ProxyConfig config, {
    SshGateway? gateway,
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  });
}

abstract interface class DynamicProxySession {
  /// Completes when listeners end, with an error for unexpected termination.
  Future<void> get done;
  Future<void> close();
}
