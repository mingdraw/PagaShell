import 'dart:io';

/// 应用全局网络代理模式。
enum AppProxyMode { auto, off, manual }

/// 手动代理及系统解析支持的代理协议。
enum AppProxyProtocol {
  http('HTTP'),
  https('HTTPS'),
  socks5('SOCKS5');

  const AppProxyProtocol(this.label);

  final String label;
}

/// 解析后的单跳代理连接目标，凭据仅存于内存。
class AppProxyEndpoint {
  const AppProxyEndpoint({
    required this.protocol,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
  });

  final AppProxyProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String password;

  bool get hasCredentials => username.isNotEmpty || password.isNotEmpty;

  String get formattedHost => host.contains(':') ? '[$host]' : host;

  String get address => '$formattedHost:$port';

  String get cacheKey =>
      '${protocol.name}|$host|$port|$username|${password.length}:${password.hashCode}';

  @override
  bool operator ==(Object other) =>
      other is AppProxyEndpoint &&
      other.protocol == protocol &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(protocol, host, port, username, password);
}

/// 应用全局代理设置；密码仅以 [passwordSecretRef] 引用系统凭据存储。
class AppProxySettings {
  const AppProxySettings({
    this.mode = AppProxyMode.auto,
    this.protocol = AppProxyProtocol.http,
    this.address = '',
    this.username = '',
    this.passwordSecretRef = '',
    this.pendingSecretDeletes = const [],
  });

  final AppProxyMode mode;
  final AppProxyProtocol protocol;
  final String address;
  final String username;
  final String passwordSecretRef;
  final List<String> pendingSecretDeletes;

  bool get hasSavedPassword => passwordSecretRef.isNotEmpty;

  AppProxySettings copyWith({
    AppProxyMode? mode,
    AppProxyProtocol? protocol,
    String? address,
    String? username,
    String? passwordSecretRef,
    List<String>? pendingSecretDeletes,
  }) => AppProxySettings(
    mode: mode ?? this.mode,
    protocol: protocol ?? this.protocol,
    address: address ?? this.address,
    username: username ?? this.username,
    passwordSecretRef: passwordSecretRef ?? this.passwordSecretRef,
    pendingSecretDeletes: pendingSecretDeletes ?? this.pendingSecretDeletes,
  );

  /// 解析 `host:port` 或 `[ipv6]:port`，校验失败返回 null。
  static AppProxyEndpoint? parseAddress(
    String raw,
    AppProxyProtocol protocol, {
    String username = '',
    String password = '',
  }) {
    final parsed = _parseHostAndPort(raw);
    if (parsed == null) return null;
    return AppProxyEndpoint(
      protocol: protocol,
      host: parsed.$1,
      port: parsed.$2,
      username: username,
      password: password,
    );
  }

  /// 校验手动代理地址，返回中文校验错误键或 null。
  static String? validateAddress(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '必填';
    if (_hasControlOrWhitespace(text) ||
        text.contains('://') ||
        text.contains('/') ||
        text.contains('?') ||
        text.contains('#') ||
        text.contains('@')) {
      return '请填写主机与端口，例如 127.0.0.1:7890';
    }
    if (text.startsWith('[')) {
      final close = text.indexOf(']');
      if (close <= 1 || close + 1 >= text.length || text[close + 1] != ':') {
        return 'IPv6 地址请使用方括号，例如 [::1]:1080';
      }
      final host = text.substring(1, close);
      final ip = InternetAddress.tryParse(host);
      if (ip == null ||
          ip.type != InternetAddressType.IPv6 ||
          host.contains('%')) {
        return '请填写有效的代理地址';
      }
      final port = _parsePort(text.substring(close + 2));
      if (port == null) return '请填写有效的端口（1-65535）';
      return null;
    }
    final firstColon = text.indexOf(':');
    final lastColon = text.lastIndexOf(':');
    if (firstColon != lastColon) {
      return 'IPv6 地址请使用方括号，例如 [::1]:1080';
    }
    if (lastColon <= 0) {
      return '请填写包含端口的代理地址，例如 127.0.0.1:7890';
    }
    final host = text.substring(0, lastColon);
    if (!_isValidHost(host)) {
      return '请填写有效的代理地址';
    }
    if (_parsePort(text.substring(lastColon + 1)) == null) {
      return '请填写有效的端口（1-65535）';
    }
    return null;
  }

  /// 校验可选代理用户名或密码，禁止控制字符以防协议头注入。
  static String? validateCredential(String raw) {
    for (final unit in raw.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) {
        return '用户名或密码不能包含换行或控制字符';
      }
    }
    return null;
  }

  static (String, int)? _parseHostAndPort(String raw) {
    if (validateAddress(raw) != null) return null;
    final text = raw.trim();
    if (text.startsWith('[')) {
      final close = text.indexOf(']');
      final host = text.substring(1, close);
      final port = int.parse(text.substring(close + 2));
      return (host, port);
    }
    final colon = text.lastIndexOf(':');
    return (text.substring(0, colon), int.parse(text.substring(colon + 1)));
  }

  static int? _parsePort(String raw) {
    if (raw.isEmpty || !RegExp(r'^\d+$').hasMatch(raw)) return null;
    final port = int.tryParse(raw);
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  static bool _isValidHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    if (InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4) {
      return true;
    }
    return RegExp(r'^[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.?$').hasMatch(host);
  }

  static bool _hasControlOrWhitespace(String text) =>
      text.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f);
}
