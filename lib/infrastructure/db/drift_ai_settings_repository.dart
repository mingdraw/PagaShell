import 'dart:convert';

import '../../domain/ai/ai_model.dart';
import '../../domain/repositories/ai_settings_repository.dart';
import 'app_database.dart';

class DriftAiSettingsRepository implements AiSettingsRepository {
  DriftAiSettingsRepository(this._db);
  final AppDatabase _db;
  static const settingsKey = 'ai_settings';

  @override
  Future<AiSettings> read() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(settingsKey))).getSingleOrNull();
    if (row == null) return const AiSettings();
    final Object? decoded = jsonDecode(row.value);
    // 不把损坏的已存配置当作空配置覆盖，保留恢复机会。
    if (decoded is! Map<String, dynamic> || decoded['models'] is! List) {
      throw const FormatException('Invalid AI settings');
    }
    final models = <AiModelConfig>[];
    for (final value in decoded['models'] as List<dynamic>) {
      final model = AiModelConfig.fromJson(value);
      if (model == null || models.any((m) => m.id == model.id)) {
        throw const FormatException('Invalid AI model');
      }
      models.add(model);
    }
    final width = decoded['panelWidth'];
    return AiSettings(
      models: List.unmodifiable(models),
      selectedModelId: decoded['selectedModelId'] as String?,
      panelVisible: decoded['panelVisible'] == true,
      panelWidth: width is num && width.isFinite
          ? width.toDouble().clamp(300, 640)
          : 360,
      pendingSecretDeletes: decoded['pendingSecretDeletes'] is List
          ? (decoded['pendingSecretDeletes'] as List<dynamic>)
                .whereType<String>()
                .toList()
          : const [],
      reasoningEffort:
          AiReasoningEffort.values
              .where((value) => value.name == decoded['reasoningEffort'])
              .firstOrNull ??
          AiReasoningEffort.auto,
      accessMode:
          AgentAccessMode.values
              .where((value) => value.name == decoded['accessMode'])
              .firstOrNull ??
          AgentAccessMode.requestApproval,
    );
  }

  @override
  Future<void> save(AiSettings settings) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: settingsKey,
          value: jsonEncode({
            'models': settings.models.map((m) => m.toJson()).toList(),
            'selectedModelId': settings.selectedModel?.id,
            'panelVisible': settings.panelVisible,
            'panelWidth': settings.panelWidth,
            'pendingSecretDeletes': settings.pendingSecretDeletes,
            'reasoningEffort': settings.reasoningEffort.name,
            'accessMode': settings.accessMode.name,
          }),
        ),
      );
}
