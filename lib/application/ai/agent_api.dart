part of 'agent_controller.dart';

class _AgentApiState {
  final capabilityRevision = 0.obs;
  final modelLimits = <(String, String), int>{};
  final modelDetails = <(String, String), AiAvailableModel>{};
  String? scope;
}

extension _AgentApiOperations on AgentController {
  Future<AgentReply> _request(
    AiModelConfig model,
    String key,
    String system,
    List<AgentTurn> turns, {
    int? anthropicMaxTokens,
    AiReasoningEffort effort = AiReasoningEffort.auto,
    AiAvailableModel? capabilities,
    String? anthropicScope,
  }) async {
    final response = await _connect
        .post<dynamic>(
          model.endpoint.toString(),
          AgentApiCodec.request(
            model,
            system,
            turns,
            anthropicMaxTokens: anthropicMaxTokens,
            effort: effort,
            capabilities: capabilities,
            anthropicScope: anthropicScope,
          ),
          contentType: 'application/json',
          headers: _headers(model.format, key),
        )
        .timeout(const Duration(seconds: 120));
    if (!response.isOk ||
        response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300) {
      if (model.format == AiApiFormat.anthropic &&
          anthropicMaxTokens == null &&
          (response.statusCode == 400 || response.statusCode == 422) &&
          jsonEncode(response.body).contains('max_tokens')) {
        throw const AgentApiException('无法读取 Anthropic 模型输出上限，请检查服务商的模型接口');
      }
      if (effort != AiReasoningEffort.auto &&
          (response.statusCode == 400 || response.statusCode == 422) &&
          RegExp(
            r'reasoning|effort|thinking|budget_tokens',
            caseSensitive: false,
          ).hasMatch(jsonEncode(response.body))) {
        throw const AgentApiException('当前模型不支持所选思考强度，请选择自动或其他强度');
      }
      throw AgentApiException(switch (response.statusCode) {
        401 || 403 => 'AI API 认证失败，请检查 API Key',
        429 => 'AI API 请求受限，请稍后重试',
        400 || 404 || 422 => 'AI API 拒绝请求，请检查地址、模型和工具调用支持',
        _ => 'AI API 连接失败，请检查网络或服务状态',
      });
    }
    return AgentApiCodec.parse(
      model.format,
      response.body,
      responsesScope: AgentApiCodec.responsesScope(model),
      anthropicScope: anthropicScope,
    );
  }

  Map<String, String> _headers(AiApiFormat format, String key) =>
      format == AiApiFormat.anthropic
      ? {'x-api-key': key, 'anthropic-version': '2023-06-01'}
      : {'Authorization': 'Bearer $key'};

  (String, String) _capabilityScope(AiModelConfig model) => (
    '${AiModelConfig.modelsEndpoint(model.baseUrl)}#${model.secretRef}',
    model.model,
  );

  void _rememberModels(AiModelConfig api, Iterable<AiAvailableModel> models) {
    final namespace = _capabilityScope(api).$1;
    _api.modelDetails.removeWhere((scope, _) => scope.$1 == namespace);
    _api.modelLimits.removeWhere((scope, _) => scope.$1 == namespace);
    for (final model in models) {
      final scope = (namespace, model.id);
      _api.modelDetails[scope] = model;
      if (model.maxOutputTokens != null) {
        _api.modelLimits[scope] = model.maxOutputTokens!;
      }
    }
    _api.capabilityRevision.value++;
  }

  Future<Map<String, dynamic>> _getModelData(
    Uri uri,
    AiApiFormat format,
    String key,
  ) async {
    try {
      final response = await _connect
          .get<dynamic>(uri.toString(), headers: _headers(format, key))
          .timeout(const Duration(seconds: 30));
      if (!response.isOk ||
          response.statusCode == null ||
          response.statusCode! < 200 ||
          response.statusCode! >= 300) {
        throw AgentApiException(switch (response.statusCode) {
          401 || 403 => 'AI API 认证失败，请检查 API Key',
          429 => 'AI API 请求受限，请稍后重试',
          _ => '模型列表获取失败，请检查 API 地址或手动填写模型 ID',
        });
      }
      final body = response.body;
      return (body is String ? jsonDecode(body) : body) as Map<String, dynamic>;
    } on AgentApiException {
      rethrow;
    } on Object {
      throw const AgentApiException('模型列表获取失败，请检查 API 地址或手动填写模型 ID');
    }
  }

  /// 读取服务商模型目录；编辑时留空的 Key 从保险库读取。
  Future<List<AiAvailableModel>> _fetchModels({
    required AiApiFormat format,
    required String baseUrl,
    String? apiKey,
    String? modelConfigId,
  }) async {
    final invalid = AiModelConfig.validateEndpoint(baseUrl);
    if (invalid != null) throw AgentApiException(invalid);
    try {
      final enteredKey = apiKey?.trim();
      var key = enteredKey;
      AiModelConfig? saved;
      if (modelConfigId != null) {
        await _settings.ready;
        saved = _settings.state.value.models
            .where((model) => model.id == modelConfigId)
            .firstOrNull;
        if ((key == null || key.isEmpty) && saved != null) {
          key = await _secretStore.read(saved.secretRef);
        }
      }
      if (key == null || key.trim().isEmpty) {
        throw const AgentApiException('请输入 API Key');
      }
      final endpoint = AiModelConfig.modelsEndpoint(baseUrl);
      final models = <String, AiAvailableModel>{};
      final cursors = <String>{};
      String? after;
      for (var page = 0; page < 100; page++) {
        final data = await _getModelData(
          endpoint.replace(
            queryParameters: {
              if (format == AiApiFormat.anthropic) 'limit': '1000',
              'after_id': ?after,
            },
          ),
          format,
          key,
        );
        final items = data['data'];
        if (items is! List) throw const FormatException();
        for (final item in items) {
          if (item is! Map<String, dynamic> ||
              item['id'] is! String ||
              (item['id'] as String).trim().isEmpty) {
            throw const FormatException();
          }
          final id = item['id'] as String;
          models[id] = _modelInfo(item);
        }
        if (data['has_more'] != true) {
          // 未保存表单的目录不污染运行配置；替换 Key 后缓存也相互隔离。
          if (!isClosed &&
              saved != null &&
              (enteredKey == null || enteredKey.isEmpty) &&
              saved.format == format &&
              AiModelConfig.modelsEndpoint(saved.baseUrl) == endpoint &&
              _settings.state.value.models.any(
                (model) => identical(model, saved),
              )) {
            _rememberModels(saved, models.values);
          }
          return models.values.toList()..sort((a, b) => a.id.compareTo(b.id));
        }
        final cursor = data['last_id'];
        if (cursor is! String || cursor.isEmpty || !cursors.add(cursor)) {
          throw const FormatException();
        }
        after = cursor;
      }
      throw const FormatException();
    } on AgentApiException {
      rethrow;
    } on Object {
      throw const AgentApiException('模型列表获取失败，请检查 API 地址或手动填写模型 ID');
    }
  }

  AiAvailableModel _modelInfo(Map<String, dynamic> data) {
    final capabilities = data['capabilities'];
    final effort = capabilities is Map ? capabilities['effort'] : null;
    final thinking = capabilities is Map ? capabilities['thinking'] : null;
    final types = thinking is Map ? thinking['types'] : null;
    bool? supported(Object? item) => item is Map && item['supported'] is bool
        ? item['supported'] as bool
        : null;
    final limit = data['max_tokens'];
    return AiAvailableModel(
      data['id'] as String,
      maxOutputTokens: limit is int && limit > 0 ? limit : null,
      efforts: effort is Map
          ? {
              if (effort['supported'] != false)
                for (final value in AiReasoningEffort.values.skip(1))
                  if (supported(effort[value.name]) == true) value,
            }
          : null,
      adaptiveThinking: supported(thinking) == false
          ? false
          : types is Map
          ? supported(types['adaptive'])
          : null,
      budgetThinking: supported(thinking) == false
          ? false
          : types is Map
          ? supported(types['enabled'])
          : null,
    );
  }

  Future<int?> _anthropicMaxTokens(
    AiModelConfig model,
    String key, {
    bool cache = true,
  }) async {
    if (model.format != AiApiFormat.anthropic) return null;
    final endpoint = AiModelConfig.modelsEndpoint(model.baseUrl);
    final scope = _capabilityScope(model);
    if (cache && _api.modelLimits.containsKey(scope)) {
      return _api.modelLimits[scope];
    }
    try {
      final data = await _getModelData(
        endpoint.replace(pathSegments: [...endpoint.pathSegments, model.model]),
        model.format,
        key,
      );
      if (cache) {
        _api.modelDetails[scope] = _modelInfo({...data, 'id': model.model});
        _api.capabilityRevision.value++;
      }
      final limit = data['max_tokens'];
      if (limit is int && limit > 0) {
        if (cache) _api.modelLimits[scope] = limit;
        return limit;
      }
    } on AgentApiException catch (error) {
      if (error.message == 'AI API 认证失败，请检查 API Key' ||
          error.message == 'AI API 请求受限，请稍后重试') {
        rethrow;
      }
    }
    // 有些兼容服务仅提供列表，或由服务端默认输出上限；目录失败不阻止手输模型。
    try {
      final models = await fetchModels(
        format: model.format,
        baseUrl: model.baseUrl,
        apiKey: key,
      );
      if (cache) _rememberModels(model, models);
      return models
          .where((item) => item.id == model.model)
          .firstOrNull
          ?.maxOutputTokens;
    } on AgentApiException catch (error) {
      if (error.message == 'AI API 认证失败，请检查 API Key' ||
          error.message == 'AI API 请求受限，请稍后重试') {
        rethrow;
      }
    }
    return cache ? _api.modelLimits[scope] : null;
  }

  Future<void> _testConnection(AiModelConfig model, {String? apiKey}) async {
    try {
      final endpointError = AiModelConfig.validateEndpoint(model.baseUrl);
      if (endpointError != null) throw AgentApiException(endpointError);
      if (model.model.trim().isEmpty) {
        throw const AgentApiException('请输入模型 ID');
      }
      final enteredKey = apiKey?.trim();
      final key = enteredKey != null && enteredKey.isNotEmpty
          ? enteredKey
          : model.secretRef.isEmpty
          ? null
          : await _secretStore.read(model.secretRef);
      if (key == null || key.trim().isEmpty) {
        throw AgentApiException(
          model.secretRef.isEmpty ? '请输入 API Key' : 'API Key 不可用，请在设置中重新保存',
        );
      }
      final limit = await _anthropicMaxTokens(model, key, cache: false);
      await _request(model, key, 'Reply briefly with OK. Do not call tools.', [
        const AgentTurn('user', 'Connection test.'),
      ], anthropicMaxTokens: limit);
    } on AgentApiException {
      rethrow;
    } on Object {
      throw const AgentApiException('AI API 连接失败，请检查网络或服务状态');
    }
  }
}
