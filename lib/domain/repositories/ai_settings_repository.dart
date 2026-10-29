import '../ai/ai_model.dart';

abstract interface class AiSettingsRepository {
  Future<AiSettings> read();
  Future<void> save(AiSettings settings);
}
