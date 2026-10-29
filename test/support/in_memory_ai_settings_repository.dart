import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/repositories/ai_settings_repository.dart';

class InMemoryAiSettingsRepository implements AiSettingsRepository {
  AiSettings value = const AiSettings();
  bool failSave = false;
  bool failRead = false;
  @override
  Future<AiSettings> read() async {
    if (failRead) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> save(AiSettings settings) async {
    if (failSave) throw StateError('save failed');
    value = settings;
  }
}
