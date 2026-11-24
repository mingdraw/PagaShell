import '../mcp/mcp_models.dart';

enum AiApiFormat {
  openai,
  openaiResponses,
  anthropic;

  String get label => switch (this) {
    openai => 'OpenAI Chat Completions',
    openaiResponses => 'OpenAI Responses',
    anthropic => 'Anthropic Messages',
  };
}

enum AiReasoningEffort {
  auto,
  none,
  minimal,
  low,
  medium,
  high,
  xhigh,
  max;

  String get label => switch (this) {
    auto => '自动',
    none => '关闭思考',
    minimal => '极低',
    low => '低',
    medium => '中',
    high => '高',
    xhigh => '极高',
    max => '最高',
  };
}

enum AgentAccessMode {
  requestApproval('请求批准'),
  approveWrites('只读自动'),
  fullAccess('完全访问');

  const AgentAccessMode(this.label);
  final String label;
}

/// 服务商返回的模型能力，仅在运行内存中使用。
class AiAvailableModel {
  const AiAvailableModel(
    this.id, {
    this.maxOutputTokens,
    this.efforts,
    this.adaptiveThinking,
    this.budgetThinking,
  });
  final String id;
  final int? maxOutputTokens;
  // null 表示兼容 API 未提供能力信息，空集合表示明确不支持 effort。
  final Set<AiReasoningEffort>? efforts;
  final bool? adaptiveThinking;
  final bool? budgetThinking;

  bool get usesThinkingBudget =>
      adaptiveThinking == false && budgetThinking == true;

  List<AiReasoningEffort> reasoningOptions(AiApiFormat format) {
    final options = format == AiApiFormat.anthropic
        ? [
            AiReasoningEffort.low,
            AiReasoningEffort.medium,
            AiReasoningEffort.high,
            if (!usesThinkingBudget) ...[
              AiReasoningEffort.xhigh,
              AiReasoningEffort.max,
            ],
          ]
        : AiReasoningEffort.values.skip(1);
    return [
      AiReasoningEffort.auto,
      if (usesThinkingBudget) ...[
        if (maxOutputTokens != null && maxOutputTokens! > 1024) ...options,
      ] else
        for (final option in options)
          if (efforts == null || efforts!.contains(option)) option,
    ];
  }
}

/// 仅保存非敏感配置；API Key 经 secretRef 存入 SecretStore。
class AiModelConfig {
  const AiModelConfig({
    required this.id,
    required this.name,
    required this.format,
    required this.baseUrl,
    required this.model,
    required this.secretRef,
    this.cachedModels = const [],
  });

  final String id;
  final String name;
  final AiApiFormat format;
  final String baseUrl;
  final String model;
  final String secretRef;

  /// 最近一次从服务商拉取并缓存的可用模型 ID 列表（仅非敏感名称）。
  final List<String> cachedModels;

  static List<String> normalizeModelIds(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      final id = raw.trim();
      if (id.isNotEmpty && seen.add(id)) {
        result.add(id);
      }
    }
    return List.unmodifiable(result);
  }

  /// Agent 切换模型，保留当前 API 配置与缓存模型目录。
  AiModelConfig withModel(String value) => AiModelConfig(
    id: id,
    name: name,
    format: format,
    baseUrl: baseUrl,
    model: value,
    secretRef: secretRef,
    cachedModels: cachedModels,
  );

  AiModelConfig withCachedModels(Iterable<String> models) => AiModelConfig(
    id: id,
    name: name,
    format: format,
    baseUrl: baseUrl,
    model: model,
    secretRef: secretRef,
    cachedModels: normalizeModelIds(models),
  );

  /// 接受服务根地址、带 /v1 的地址或完整接口地址。
  Uri get endpoint => _endpoint(baseUrl, switch (format) {
    AiApiFormat.openai => '/chat/completions',
    AiApiFormat.openaiResponses => '/responses',
    AiApiFormat.anthropic => '/messages',
  });

  static Uri modelsEndpoint(String baseUrl) => _endpoint(baseUrl, '/models');

  static Uri _endpoint(String baseUrl, String suffix) {
    final uri = Uri.parse(baseUrl.trim());
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    for (final known in [
      '/chat/completions',
      '/responses',
      '/messages',
      '/models',
    ]) {
      if (path.endsWith(known)) {
        path = path.substring(0, path.length - known.length);
        break;
      }
    }
    return uri.replace(path: '${path.isEmpty ? '/v1' : path}$suffix');
  }

  static String? validateEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '请输入有效的 API 地址，不含账号、查询参数或片段';
    }
    // 本机代理允许 HTTP；远程模型的凭据必须经 TLS 传输。
    if (uri.scheme == 'http' &&
        !const ['localhost', '127.0.0.1', '::1'].contains(uri.host)) {
      return '远程 API 地址必须使用 HTTPS';
    }
    return null;
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'format': format.name,
    'baseUrl': baseUrl,
    'model': model,
    'secretRef': secretRef,
    if (cachedModels.isNotEmpty) 'cachedModels': cachedModels,
  };

  static AiModelConfig? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final format = AiApiFormat.values
        .where((f) => f.name == value['format'])
        .firstOrNull;
    for (final key in ['id', 'name', 'baseUrl', 'model', 'secretRef']) {
      if (value[key] is! String || (value[key] as String).trim().isEmpty) {
        return null;
      }
    }
    if (format == null ||
        validateEndpoint(value['baseUrl'] as String) != null) {
      return null;
    }
    final rawCached = value['cachedModels'];
    final cached = rawCached is List
        ? normalizeModelIds(rawCached.whereType<String>())
        : const <String>[];
    return AiModelConfig(
      id: value['id'] as String,
      name: value['name'] as String,
      format: format,
      baseUrl: value['baseUrl'] as String,
      model: value['model'] as String,
      secretRef: value['secretRef'] as String,
      cachedModels: cached,
    );
  }
}

class AiSettings {
  const AiSettings({
    this.models = const [],
    this.selectedModelId,
    this.panelVisible = false,
    this.panelWidth = 360,
    this.pendingSecretDeletes = const [],
    this.reasoningEffort = AiReasoningEffort.auto,
    this.accessMode = AgentAccessMode.requestApproval,
    this.mcp = const McpServerConfig(),
  });

  final List<AiModelConfig> models;
  final String? selectedModelId;
  final bool panelVisible;
  final double panelWidth;
  final List<String> pendingSecretDeletes;
  final AiReasoningEffort reasoningEffort;
  final AgentAccessMode accessMode;
  final McpServerConfig mcp;

  AiModelConfig? get selectedModel =>
      models.where((m) => m.id == selectedModelId).firstOrNull ??
      models.firstOrNull;

  // 兼容旧多配置存储，直接编辑原先选中的 API，保留其他密钥引用。
  AiModelConfig? get apiConfig => selectedModel;

  AiSettings copyWith({
    List<AiModelConfig>? models,
    String? selectedModelId,
    bool? panelVisible,
    double? panelWidth,
    List<String>? pendingSecretDeletes,
    AiReasoningEffort? reasoningEffort,
    AgentAccessMode? accessMode,
    McpServerConfig? mcp,
  }) => AiSettings(
    models: models ?? this.models,
    selectedModelId: selectedModelId ?? this.selectedModelId,
    panelVisible: panelVisible ?? this.panelVisible,
    panelWidth: panelWidth ?? this.panelWidth,
    pendingSecretDeletes: pendingSecretDeletes ?? this.pendingSecretDeletes,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    accessMode: accessMode ?? this.accessMode,
    mcp: mcp ?? this.mcp,
  );
}
