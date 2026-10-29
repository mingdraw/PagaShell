import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';

import '../../domain/ai/ai_model.dart';
import '../../domain/repositories/ai_settings_repository.dart';
import '../../domain/vault/secret_store.dart';

class AiSettingsException implements Exception {
  const AiSettingsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AiSettingsController extends GetxController {
  AiSettingsController({required this._repository, required this._secretStore});

  final AiSettingsRepository _repository;
  final SecretStore _secretStore;
  final state = const AiSettings().obs;
  final isLoaded = false.obs;
  final loadFailed = false.obs;
  late final Future<void> ready = _load();
  Future<void> _pending = Future<void>.value();

  @override
  void onInit() {
    super.onInit();
    unawaited(ready);
  }

  Future<void> _load() async {
    try {
      final saved = await _repository.read();
      if (!isClosed) state.value = saved;
    } on Object {
      if (!isClosed) loadFailed.value = true;
    }
    if (!isClosed) isLoaded.value = true;
  }

  Future<void> reload() => _queue(() async {
    final saved = await _repository.read();
    state.value = saved;
    loadFailed.value = false;
    await _cleanSecrets();
  }, allowFailedLoad: true);

  Future<void> _queue(
    Future<void> Function() action, {
    bool allowFailedLoad = false,
  }) {
    final result = _pending.then((_) async {
      await ready;
      if (isClosed) return;
      if (loadFailed.value && !allowFailedLoad) {
        throw const AiSettingsException('AI 设置读取失败，请重试');
      }
      try {
        await action();
      } on AiSettingsException {
        rethrow;
      } on Object {
        throw const AiSettingsException('AI 设置保存失败，请重试');
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String _id() => base64UrlEncode(
    List<int>.generate(18, (_) => Random.secure().nextInt(256)),
  );

  Future<void> saveModel({
    String? id,
    required String name,
    required AiApiFormat format,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) => _queue(
    () => _saveModel(
      id: id,
      name: name,
      format: format,
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
    ),
  );

  Future<void> saveApi({
    required AiApiFormat format,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  }) => _queue(
    () => _saveModel(
      id: state.value.apiConfig?.id,
      name: format.label,
      format: format,
      baseUrl: baseUrl,
      model: defaultModel,
      apiKey: apiKey,
    ),
  );

  Future<void> _saveModel({
    String? id,
    required String name,
    required AiApiFormat format,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    final old = state.value.models.where((m) => m.id == id).firstOrNull;
    final endpointError = AiModelConfig.validateEndpoint(baseUrl);
    if (endpointError != null) throw AiSettingsException(endpointError);
    if (name.trim().isEmpty || model.trim().isEmpty) {
      throw const AiSettingsException('请填写有效的模型配置');
    }
    if (id != null && old == null) throw const AiSettingsException('模型配置已不存在');
    final key = apiKey?.trim();
    if (old == null && (key == null || key.isEmpty)) {
      throw const AiSettingsException('请输入 API Key');
    }
    final replacingKey = key != null && key.isNotEmpty;
    final ref = replacingKey ? 'ai-api-${_id()}' : old!.secretRef;
    final config = AiModelConfig(
      id: old?.id ?? _id(),
      name: name.trim(),
      format: format,
      baseUrl: baseUrl.trim(),
      model: model.trim(),
      secretRef: ref,
    );
    if (replacingKey) {
      // 先记录新引用再写密文；后续任一步失败或进程退出后仍可发现并清理。
      await _commit(
        state.value.copyWith(
          pendingSecretDeletes: [...state.value.pendingSecretDeletes, ref],
        ),
      );
      try {
        await _secretStore.put(ref, key);
      } on Object {
        await _cleanSecrets();
        rethrow;
      }
    }
    final models = [...state.value.models];
    if (old == null) {
      models.add(config);
    } else {
      models[models.indexOf(old)] = config;
    }
    final next = state.value.copyWith(
      models: List.unmodifiable(models),
      selectedModelId: state.value.selectedModel?.id ?? config.id,
      pendingSecretDeletes: [
        ...state.value.pendingSecretDeletes.where((pending) => pending != ref),
        if (replacingKey && old != null) old.secretRef,
      ],
    );
    try {
      await _repository.save(next);
    } on Object {
      if (replacingKey) await _cleanSecrets();
      rethrow;
    }
    if (!isClosed) state.value = next;
    await _cleanSecrets();
  }

  Future<void> removeModel(String id) => _queue(() async {
    final old = state.value.models.where((m) => m.id == id).firstOrNull;
    if (old == null) return;
    final models = state.value.models.where((m) => m.id != id).toList();
    await _commit(
      state.value.copyWith(
        models: List.unmodifiable(models),
        selectedModelId: state.value.selectedModelId == id
            ? models.firstOrNull?.id
            : null,
        pendingSecretDeletes: [
          ...state.value.pendingSecretDeletes,
          old.secretRef,
        ],
      ),
    );
    await _cleanSecrets();
  });

  Future<void> selectModel(String id) => _queue(() async {
    if (!state.value.models.any((m) => m.id == id)) return;
    await _commit(state.value.copyWith(selectedModelId: id));
  });

  Future<void> setPanel({bool? visible, double? width}) => _queue(() async {
    await _commit(
      state.value.copyWith(
        panelVisible: visible,
        panelWidth: width?.clamp(300, 640),
      ),
    );
  });

  Future<void> setAgentModes({
    required AiReasoningEffort reasoningEffort,
    required AgentAccessMode accessMode,
  }) => _queue(
    () => _commit(
      state.value.copyWith(
        reasoningEffort: reasoningEffort,
        accessMode: accessMode,
      ),
    ),
  );

  Future<void> _commit(AiSettings next) async {
    await _repository.save(next);
    if (!isClosed) state.value = next;
  }

  /// 删除失败的密文引用保留在设置中，下一次编辑或重新加载时继续清理。
  Future<void> _cleanSecrets() async {
    final remaining = <String>[];
    for (final ref in state.value.pendingSecretDeletes.toSet()) {
      if (state.value.models.any((m) => m.secretRef == ref)) continue;
      try {
        await _secretStore.delete(ref);
      } on Object {
        remaining.add(ref);
      }
    }
    if (remaining.length != state.value.pendingSecretDeletes.length) {
      try {
        await _commit(state.value.copyWith(pendingSecretDeletes: remaining));
      } on Object {
        /* 已保存待删引用，重启后重试。 */
      }
    }
  }
}
