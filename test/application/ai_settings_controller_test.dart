import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_ai_settings_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/in_memory_ai_settings_repository.dart';

class _Store extends InMemorySecretStore {
  bool failDelete = false;
  @override
  Future<void> delete(String ref) async {
    if (failDelete) throw StateError('delete');
    await super.delete(ref);
  }
}

class _CommitFailureRepository extends InMemoryAiSettingsRepository {
  bool failModelCommit = false;
  @override
  Future<void> save(AiSettings settings) async {
    if (failModelCommit &&
        settings.models.isNotEmpty &&
        settings.models.first.secretRef != value.models.first.secretRef) {
      throw StateError('model commit failed');
    }
    await super.save(settings);
  }
}

void main() {
  Future<void> save(
    AiSettingsController controller, {
    String? id,
    String? key = 'test-secret',
    String name = 'Provider',
  }) => controller.saveModel(
    id: id,
    name: name,
    format: AiApiFormat.openai,
    baseUrl: 'https://provider.test/v1',
    model: 'my-model',
    apiKey: key,
  );

  test('模型配置仅含密文引用，空 Key 保留，替换删除旧 Key', () async {
    final repository = InMemoryAiSettingsRepository();
    final store = _Store();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    await save(controller);
    final first = controller.state.value.selectedModel!;
    expect(jsonEncode(first.toJson()), isNot(contains('test-secret')));
    expect(await store.read(first.secretRef), 'test-secret');
    await save(controller, id: first.id, key: '', name: 'Renamed');
    expect(controller.state.value.selectedModel!.secretRef, first.secretRef);
    await save(controller, id: first.id, key: 'replacement');
    final replaced = controller.state.value.selectedModel!;
    expect(replaced.secretRef, isNot(first.secretRef));
    expect(await store.read(first.secretRef), isNull);
    expect(await store.read(replaced.secretRef), 'replacement');
    await controller.removeModel(first.id);
    expect(controller.state.value.models, isEmpty);
    expect(await store.read(replaced.secretRef), isNull);
  });

  test('元数据保存失败保留原模型和密文', () async {
    final repository = InMemoryAiSettingsRepository();
    final store = _Store();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    await save(controller);
    final old = controller.state.value.selectedModel!;
    repository.failSave = true;
    await expectLater(
      save(controller, id: old.id, key: 'new-secret'),
      throwsA(isA<AiSettingsException>()),
    );
    expect(controller.state.value.selectedModel, same(old));
    expect(await store.read(old.secretRef), 'test-secret');
    repository.failSave = false;
    await save(controller, id: old.id, key: '', name: 'Recovered');
    expect(controller.state.value.selectedModel!.name, 'Recovered');
  });

  test('直接 API 设置沿用旧选中配置，保留其他配置及密钥，默认模型独立保存', () async {
    final repository = InMemoryAiSettingsRepository();
    final store = _Store();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    addTearDown(controller.onClose);
    await save(controller, name: 'First');
    final first = controller.state.value.apiConfig!;
    await save(controller, name: 'Second', key: 'second-key');
    final second = controller.state.value.models.last;
    await controller.selectModel(second.id);
    await controller.saveApi(
      format: AiApiFormat.openaiResponses,
      baseUrl: 'https://updated.test/v1',
      defaultModel: 'new-default',
      apiKey: '',
    );
    final current = controller.state.value.apiConfig!;
    expect(current.id, second.id);
    expect(current.secretRef, second.secretRef);
    expect(current.model, 'new-default');
    expect(current.format, AiApiFormat.openaiResponses);
    expect(controller.state.value.models.first, same(first));
    expect(await store.read(first.secretRef), 'test-secret');
    expect(await store.read(current.secretRef), 'second-key');
    expect(
      jsonEncode(repository.value.models.map((m) => m.toJson()).toList()),
      isNot(contains('second-key')),
    );
  });

  test('密文删除失败保存待删引用并可恢复清理，不删除仍使用的 Key', () async {
    final repository = InMemoryAiSettingsRepository();
    final store = _Store();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    await save(controller);
    final old = controller.state.value.selectedModel!;
    store.failDelete = true;
    await controller.removeModel(old.id);
    expect(repository.value.pendingSecretDeletes, [old.secretRef]);
    expect(await store.read(old.secretRef), 'test-secret');
    store.failDelete = false;
    await controller.reload();
    expect(await store.read(old.secretRef), isNull);
    expect(repository.value.pendingSecretDeletes, isEmpty);
  });

  test('新密钥写入后模型提交与回滚删除同时失败，重建控制器后仍可清理', () async {
    final repository = _CommitFailureRepository();
    final store = _Store();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    await save(controller);
    final old = controller.state.value.selectedModel!;
    repository.failModelCommit = true;
    store.failDelete = true;
    await expectLater(
      save(controller, id: old.id, key: 'new-secret'),
      throwsA(isA<AiSettingsException>()),
    );
    expect(repository.value.selectedModel!.secretRef, old.secretRef);
    final abandonedRef = repository.value.pendingSecretDeletes.single;
    expect(abandonedRef, isNot(old.secretRef));
    expect(await store.read(abandonedRef), 'new-secret');
    final restarted = AiSettingsController(
      repository: repository,
      secretStore: store,
    );
    await restarted.ready;
    store.failDelete = false;
    await restarted.reload();
    expect(await store.read(abandonedRef), isNull);
    expect(await store.read(old.secretRef), 'test-secret');
    expect(repository.value.pendingSecretDeletes, isEmpty);
  });

  test('模型选择、面板显隐宽度并发提交不丢失', () async {
    final repository = InMemoryAiSettingsRepository();
    final controller = AiSettingsController(
      repository: repository,
      secretStore: _Store(),
    );
    await save(controller);
    await save(controller, name: 'Second');
    final id = controller.state.value.models.last.id;
    await Future.wait([
      controller.selectModel(id),
      controller.setPanel(visible: true),
      controller.setPanel(width: 999),
      controller.setAgentModes(
        reasoningEffort: AiReasoningEffort.high,
        accessMode: AgentAccessMode.fullAccess,
      ),
    ]);
    expect(repository.value.selectedModel?.id, id);
    expect(repository.value.panelVisible, isTrue);
    expect(repository.value.panelWidth, 640);
    expect(repository.value.reasoningEffort, AiReasoningEffort.high);
    expect(repository.value.accessMode, AgentAccessMode.fullAccess);
    await controller.removeModel(id);
    expect(repository.value.selectedModel?.name, 'Provider');
  });

  test('读取失败阻止默认配置覆盖，重试后可以继续保存', () async {
    final repository = InMemoryAiSettingsRepository()..failRead = true;
    final controller = AiSettingsController(
      repository: repository,
      secretStore: _Store(),
    );
    await controller.ready;
    expect(controller.loadFailed.value, isTrue);
    await expectLater(save(controller), throwsA(isA<AiSettingsException>()));
    expect(repository.value.models, isEmpty);
    repository.failRead = false;
    await controller.reload();
    await save(controller);
    expect(repository.value.models, hasLength(1));
  });

  test('设置关闭 SQLite 再打开后恢复，API Key 不出现在数据库内容中', () async {
    final directory = await Directory.systemTemp.createTemp('pagashell-ai-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final controller = AiSettingsController(
      repository: DriftAiSettingsRepository(db),
      secretStore: _Store(),
    );
    await save(controller);
    await controller.setPanel(visible: true, width: 430);
    await controller.setAgentModes(
      reasoningEffort: AiReasoningEffort.xhigh,
      accessMode: AgentAccessMode.fullAccess,
    );
    final rows = await db.select(db.appSettings).get();
    expect(rows.single.value, isNot(contains('test-secret')));
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final saved = await DriftAiSettingsRepository(reopened).read();
    expect(saved.selectedModel!.model, 'my-model');
    expect(saved.panelVisible, isTrue);
    expect(saved.panelWidth, 430);
    expect(saved.reasoningEffort, AiReasoningEffort.xhigh);
    expect(saved.accessMode, AgentAccessMode.fullAccess);
  });

  test('旧配置和无效模式回退为自动思考与请求批准', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final modes in [
      <String, Object?>{},
      {'reasoningEffort': 'unknown', 'accessMode': 'unrestricted'},
    ]) {
      await db
          .into(db.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(
              key: DriftAiSettingsRepository.settingsKey,
              value: jsonEncode({'models': <Object?>[], ...modes}),
            ),
          );
      final saved = await DriftAiSettingsRepository(db).read();
      expect(saved.reasoningEffort, AiReasoningEffort.auto);
      expect(saved.accessMode, AgentAccessMode.requestApproval);
    }
  });

  test('损坏 AI 配置读取报错并保留原文', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: 'ai_settings', value: '{broken'),
        );
    await expectLater(
      DriftAiSettingsRepository(db).read(),
      throwsFormatException,
    );
    expect((await db.select(db.appSettings).get()).single.value, '{broken');
  });

  test('三种协议正确规范根地址、/v1、路径前缀和完整接口及模型列表地址', () {
    AiModelConfig config(AiApiFormat format, String url) => AiModelConfig(
      id: 'm',
      name: 'm',
      format: format,
      baseUrl: url,
      model: 'm',
      secretRef: 'ref',
    );
    for (final format in AiApiFormat.values) {
      final suffix = switch (format) {
        AiApiFormat.openai => '/chat/completions',
        AiApiFormat.openaiResponses => '/responses',
        AiApiFormat.anthropic => '/messages',
      };
      expect(
        config(format, 'https://p.test').endpoint.toString(),
        'https://p.test/v1$suffix',
      );
      expect(
        config(format, 'https://p.test/v1/').endpoint.toString(),
        'https://p.test/v1$suffix',
      );
      expect(
        config(format, 'https://p.test/custom/v1$suffix/').endpoint.toString(),
        'https://p.test/custom/v1$suffix',
      );
      expect(
        AiModelConfig.modelsEndpoint('https://p.test/custom/v1$suffix/')
            .toString(),
        'https://p.test/custom/v1/models',
      );
      for (final oldSuffix in [
        '/messages',
        '/chat/completions',
        '/responses',
      ]) {
        expect(
          config(
            format,
            'https://p.test/custom/v1$oldSuffix',
          ).endpoint.toString(),
          'https://p.test/custom/v1$suffix',
        );
      }
    }
    expect(AiModelConfig.validateEndpoint('http://localhost:3000/v1'), isNull);
    for (final url in [
      'file:///tmp/key',
      'https://user:pass@p.test',
      'https://p.test/v1?key=secret',
      'http://remote.test',
      '',
    ]) {
      expect(AiModelConfig.validateEndpoint(url), isNotNull);
    }
  });

  test('存量最大输出配置可读取但不再保存，Responses 协议可往返', () {
    for (final format in AiApiFormat.values) {
      final model = AiModelConfig.fromJson({
        'id': 'old',
        'name': 'old',
        'format': format.name,
        'baseUrl': 'https://p.test/v1',
        'model': 'custom-model',
        'secretRef': 'ref',
        'maxTokens': 1024,
      });
      expect(model, isNotNull);
      expect(model!.format, format);
      expect(model.toJson(), isNot(contains('maxTokens')));
      expect(AiModelConfig.fromJson(model.toJson())!.format, format);
    }
  });
}
