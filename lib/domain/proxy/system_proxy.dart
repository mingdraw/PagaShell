import '../entities/proxy_config.dart';

/// User-session network proxy settings. No environment variables or TUN device.
abstract interface class SystemProxy {
  /// Create a handle before enabling so partial writes can always be restored.
  SystemProxyLease createLease(ProxyConfig config);
}

abstract interface class SystemProxyLease {
  Future<void> enable();

  /// Restore only settings still owned by this handle. Safe to retry on error.
  Future<void> restore();
}

class SystemProxyException implements Exception {
  const SystemProxyException(this.message);
  final String message;
  @override
  String toString() => message;
}
