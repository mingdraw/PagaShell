import 'dart:convert';

enum McpAccessMode {
  fullAccess('完全放行'),
  readOnly('只读模式');

  const McpAccessMode(this.label);

  final String label;
}

/// 本地 MCP 服务配置；仅存非敏感元数据，Bearer 令牌经 tokenSecretRef 存入 SecretStore。
class McpServerConfig {
  const McpServerConfig({
    this.enabled = false,
    this.port = defaultPort,
    this.accessMode = McpAccessMode.fullAccess,
    this.tokenSecretRef,
  });

  static const int defaultPort = 47321;
  static const int minPort = 1024;
  static const int maxPort = 65535;
  static const String loopbackHost = '127.0.0.1';
  static const String mcpPath = '/mcp';

  final bool enabled;
  final int port;
  final McpAccessMode accessMode;
  final String? tokenSecretRef;

  String get endpointUrl => 'http://$loopbackHost:$port$mcpPath';

  static int? parsePort(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < minPort || parsed > maxPort) return null;
    return parsed;
  }

  static String? validatePort(String raw) =>
      parsePort(raw) == null ? '请输入 1024–65535 之间的有效端口号' : null;

  /// 生成可直接粘贴到 `~/.codex/config.toml` 的 OpenAI Codex CLI 配置片段。
  String codexTomlSnippet(String token, {int? effectivePort}) {
    final url = 'http://$loopbackHost:${effectivePort ?? port}$mcpPath';
    final escapedToken = _escapeTomlString(token);
    return '[mcp_servers.pagashell]\n'
        'url = "$url"\n'
        'http_headers = { "Authorization" = "Bearer $escapedToken" }\n';
  }

  /// 生成适用于 Claude Code、Cursor 等客户端的通用 MCP HTTP 配置 JSON。
  String mcpJsonSnippet(String token, {int? effectivePort}) {
    final url = 'http://$loopbackHost:${effectivePort ?? port}$mcpPath';
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'pagashell': {
          'type': 'http',
          'url': url,
          'headers': {'Authorization': 'Bearer $token'},
        },
      },
    });
  }

  static String _escapeTomlString(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\r', '')
      .replaceAll('\n', '');

  static const _unset = Object();

  McpServerConfig copyWith({
    bool? enabled,
    int? port,
    McpAccessMode? accessMode,
    Object? tokenSecretRef = _unset,
  }) => McpServerConfig(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    accessMode: accessMode ?? this.accessMode,
    tokenSecretRef: identical(tokenSecretRef, _unset)
        ? this.tokenSecretRef
        : tokenSecretRef as String?,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'port': port,
    'accessMode': accessMode.name,
    'tokenSecretRef': tokenSecretRef,
  };

  static McpServerConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return const McpServerConfig();
    final rawPort = value['port'];
    final port = rawPort is int && rawPort >= minPort && rawPort <= maxPort
        ? rawPort
        : defaultPort;
    final accessMode =
        McpAccessMode.values
            .where((mode) => mode.name == value['accessMode'])
            .firstOrNull ??
        McpAccessMode.fullAccess;
    final rawRef = value['tokenSecretRef'];
    final tokenSecretRef = rawRef is String && rawRef.trim().isNotEmpty
        ? rawRef.trim()
        : null;
    return McpServerConfig(
      enabled: value['enabled'] == true,
      port: port,
      accessMode: accessMode,
      tokenSecretRef: tokenSecretRef,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is McpServerConfig &&
      other.enabled == enabled &&
      other.port == port &&
      other.accessMode == accessMode &&
      other.tokenSecretRef == tokenSecretRef;

  @override
  int get hashCode => Object.hash(enabled, port, accessMode, tokenSecretRef);
}

enum McpAuditStatus { success, denied, error }

/// 单次外部 MCP 工具调用的脱敏审计记录，仅保留在运行内存中。
class McpAuditEntry {
  const McpAuditEntry({
    required this.timestamp,
    required this.toolName,
    required this.status,
    required this.durationMs,
    this.target,
    this.summary = '',
  });

  final DateTime timestamp;
  final String toolName;
  final String? target;
  final McpAuditStatus status;
  final int durationMs;
  final String summary;
}
