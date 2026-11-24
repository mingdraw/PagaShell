class McpServerException implements Exception {
  const McpServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class McpToolAnnotations {
  const McpToolAnnotations({
    required this.readOnlyHint,
    required this.destructiveHint,
    required this.idempotentHint,
    required this.openWorldHint,
  });

  final bool readOnlyHint;
  final bool destructiveHint;
  final bool idempotentHint;
  final bool openWorldHint;

  Map<String, Object> toJson() => {
    'readOnlyHint': readOnlyHint,
    'destructiveHint': destructiveHint,
    'idempotentHint': idempotentHint,
    'openWorldHint': openWorldHint,
  };
}

class McpToolDefinition {
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.annotations,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final McpToolAnnotations annotations;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': annotations.toJson(),
  };
}

class McpToolResult {
  const McpToolResult({required this.text, this.isError = false});

  final String text;
  final bool isError;
}

class McpResourceDefinition {
  const McpResourceDefinition({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
  });

  final String uri;
  final String name;
  final String description;
  final String mimeType;

  Map<String, Object> toJson() => {
    'uri': uri,
    'name': name,
    'description': description,
    'mimeType': mimeType,
  };
}

class McpResourceContent {
  const McpResourceContent({
    required this.uri,
    required this.mimeType,
    required this.text,
  });

  final String uri;
  final String mimeType;
  final String text;

  Map<String, Object> toJson() => {
    'uri': uri,
    'mimeType': mimeType,
    'text': text,
  };
}

class McpPromptArgument {
  const McpPromptArgument({
    required this.name,
    required this.description,
    this.required = false,
  });

  final String name;
  final String description;
  final bool required;

  Map<String, Object> toJson() => {
    'name': name,
    'description': description,
    'required': required,
  };
}

class McpPromptDefinition {
  const McpPromptDefinition({
    required this.name,
    required this.description,
    this.arguments = const [],
  });

  final String name;
  final String description;
  final List<McpPromptArgument> arguments;

  Map<String, Object> toJson() => {
    'name': name,
    'description': description,
    if (arguments.isNotEmpty)
      'arguments': arguments.map((arg) => arg.toJson()).toList(),
  };
}

class McpPromptMessage {
  const McpPromptMessage({required this.role, required this.text});

  final String role;
  final String text;

  Map<String, Object> toJson() => {
    'role': role,
    'content': {'type': 'text', 'text': text},
  };
}

class McpPromptResult {
  const McpPromptResult({required this.description, required this.messages});

  final String description;
  final List<McpPromptMessage> messages;

  Map<String, Object> toJson() => {
    'description': description,
    'messages': messages.map((message) => message.toJson()).toList(),
  };
}

/// MCP 业务能力委派接口：将协议传输层与 PagaShell 会话/运维执行解耦。
abstract interface class McpServerDelegate {
  String get serverName;
  String get serverVersion;
  String get instructions;

  List<McpToolDefinition> listTools();

  Future<McpToolResult> callTool(String name, Map<String, dynamic> arguments);

  List<McpResourceDefinition> listResources();

  Future<McpResourceContent?> readResource(String uri);

  List<McpPromptDefinition> listPrompts();

  Future<McpPromptResult?> getPrompt(
    String name,
    Map<String, String> arguments,
  );
}

/// 已启动的本地 MCP HTTP 服务句柄。
abstract interface class McpServerHandle {
  int get port;
  int get activeSessionCount;
  Stream<int> get activeSessionCountStream;

  void updateToken(String token);
  void notifyToolsListChanged();
  Future<void> close();
}

/// 启动本地 MCP HTTP 服务的工厂接口（基础设施层实现，应用层仅依赖此抽象）。
abstract interface class McpServerFactory {
  Future<McpServerHandle> start({
    required int port,
    required String token,
    required McpServerDelegate delegate,
  });
}
