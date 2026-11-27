import '../entities/proxy_config.dart';

enum UpstreamProxyProtocol { http, socks5 }

class UpstreamProxyEndpoint {
  const UpstreamProxyEndpoint({
    required this.protocol,
    required this.host,
    required this.port,
  });

  final UpstreamProxyProtocol protocol;
  final String host;
  final int port;

  String get address => host.contains(':') ? '[$host]:$port' : '$host:$port';

  String get displayLabel => switch (protocol) {
    UpstreamProxyProtocol.http => address,
    UpstreamProxyProtocol.socks5 => 'socks5://$address',
  };

  Map<String, Object?> toEngineJson() => {
    'protocol': protocol.name,
    'host': host,
    'port': port,
  };

  @override
  bool operator ==(Object other) =>
      other is UpstreamProxyEndpoint &&
      other.protocol == protocol &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(protocol, host, port);
}

/// Active system proxy captured before takeover so unmatched requests continue
/// through existing proxy tools (such as Clash or v2rayN).
class UpstreamProxyConfig {
  const UpstreamProxyConfig({
    this.http,
    this.https,
    this.socks5,
    this.bypass = const [],
    this.excludeSimpleHostnames = false,
  });

  final UpstreamProxyEndpoint? http;
  final UpstreamProxyEndpoint? https;
  final UpstreamProxyEndpoint? socks5;
  final List<String> bypass;
  final bool excludeSimpleHostnames;

  bool get hasEndpoint => http != null || https != null || socks5 != null;

  String get displaySummary {
    final labels = <String>{
      if (http case final ep?) ep.displayLabel,
      if (https case final ep?) ep.displayLabel,
      if (socks5 case final ep?) ep.displayLabel,
    };
    return labels.join(', ');
  }

  Map<String, Object?> toEngineJson() => {
    if (http case final ep?) 'http': ep.toEngineJson(),
    if (https case final ep?) 'https': ep.toEngineJson(),
    if (socks5 case final ep?) 'socks5': ep.toEngineJson(),
    'bypass': bypass,
    'excludeSimpleHostnames': excludeSimpleHostnames,
  };

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is UpstreamProxyConfig &&
      other.http == http &&
      other.https == https &&
      other.socks5 == socks5 &&
      other.excludeSimpleHostnames == excludeSimpleHostnames &&
      _sameList(other.bypass, bypass);

  @override
  int get hashCode => Object.hash(
    http,
    https,
    socks5,
    excludeSimpleHostnames,
    Object.hashAll(bypass),
  );
}

/// User-session network proxy settings. No environment variables or TUN device.
abstract interface class SystemProxy {
  /// Inspects the active system proxy without modifying OS settings.
  Future<UpstreamProxyConfig?> inspectUpstream(ProxyConfig config);

  /// Create a handle before enabling so partial writes can always be restored.
  SystemProxyLease createLease(ProxyConfig config);
}

abstract interface class SystemProxyLease {
  Future<void> enable();

  /// The previously active system proxy chained as upstream after [enable], if any.
  UpstreamProxyConfig? get chainedUpstream;

  /// Restore only settings still owned by this handle. Safe to retry on error.
  Future<void> restore();
}

class SystemProxyException implements Exception {
  const SystemProxyException(this.message);
  final String message;
  @override
  String toString() => message;
}
