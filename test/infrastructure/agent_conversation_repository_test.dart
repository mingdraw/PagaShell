import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/ai/agent_api_codec.dart';
import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_agent_conversation_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

AgentConversation _conversation() => AgentConversation(
  id: '0123456789abcdef0123456789abcdef',
  title: 'Check terminal output',
  createdAt: DateTime.utc(2026, 10, 27, 9),
  updatedAt: DateTime.utc(2026, 10, 27, 10),
  model: 'test-model',
  messages: const [
    AgentMessage(AgentEntryKind.user, 'Private chat request'),
    AgentMessage(
      AgentEntryKind.command,
      'Check working directory',
      command: AgentArchivedCommand(
        command: 'pwd',
        purpose: 'Check working directory',
        target: 'Private host',
        state: AgentCommandState.sent,
      ),
    ),
    AgentMessage(AgentEntryKind.assistant, 'Private terminal output'),
  ],
  turns: [
    const AgentTurn('user', 'Private chat request').toJson(),
    const AgentTurn(
      'assistant',
      '',
      calls: [
        AgentToolCall(
          id: 'call-1',
          name: 'read_terminal_output',
          arguments: {'lines': 120},
        ),
      ],
      responsesOutput: [
        {'type': 'reasoning', 'encrypted_content': 'reasoning-bytes'},
      ],
      responsesScope: 'responses-scope',
      anthropicContent: [
        {'type': 'thinking', 'thinking': '', 'signature': 'signed-thinking'},
        {'type': 'redacted_thinking', 'data': 'redacted-bytes'},
      ],
      anthropicScope: 'anthropic-scope',
    ).toJson(),
    const AgentTurn(
      'tool',
      'Private terminal output',
      toolCallId: 'call-1',
    ).toJson(),
    const AgentTurn('assistant', 'Done').toJson(),
  ],
);

void main() {
  test('对话加密落库，关闭重开后恢复消息和完整协议上下文，删除不复活', () async {
    final directory = await Directory.systemTemp.createTemp('pagashell-chat-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/history.sqlite');
    final secrets = InMemorySecretStore();
    await secrets.put('test-api-key', 'private-provider-api-key');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var repository = DriftAgentConversationRepository(db, secrets);
    expect(await repository.readAll(), isEmpty);
    expect(
      await secrets.read(DriftAgentConversationRepository.secretRef),
      isNull,
    );
    final conversation = _conversation();
    await repository.save(conversation);
    final rows = await db.select(db.appSettings).get();
    expect(rows, hasLength(1));
    for (final text in [
      'Private chat request',
      'Private terminal output',
      'Private host',
      'private-provider-api-key',
      'signed-thinking',
    ]) {
      expect(rows.single.value, isNot(contains(text)));
    }
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    repository = DriftAgentConversationRepository(db, secrets);
    final restored = (await repository.readAll()).single;
    expect(restored.toJson(), conversation.toJson());
    final turns = restored.turns.map(AgentTurn.fromJson).toList();
    expect(turns[1].calls.single.id, turns[2].toolCallId);
    expect(
      turns[1].responsesOutput.single['encrypted_content'],
      'reasoning-bytes',
    );
    expect(turns[1].anthropicContent.first['signature'], 'signed-thinking');
    await repository.remove(restored.id);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      await DriftAgentConversationRepository(db, secrets).readAll(),
      isEmpty,
    );
  });

  test('密钥缺失或密文损坏时读取失败并保留原记录，不覆盖旧密钥', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final secrets = InMemorySecretStore();
    final conversation = _conversation();
    await DriftAgentConversationRepository(db, secrets).save(conversation);
    final original = (await db.select(db.appSettings).get()).single;
    final key = await secrets.read(DriftAgentConversationRepository.secretRef);
    await secrets.delete(DriftAgentConversationRepository.secretRef);
    final missing = DriftAgentConversationRepository(db, secrets);
    await expectLater(missing.readAll(), throwsA(isA<FormatException>()));
    await expectLater(
      missing.save(conversation),
      throwsA(isA<FormatException>()),
    );
    expect(
      (await db.select(db.appSettings).get()).single.value,
      original.value,
    );
    expect(
      await secrets.read(DriftAgentConversationRepository.secretRef),
      isNull,
    );
    await secrets.put(DriftAgentConversationRepository.secretRef, key!);
    final damaged = base64Decode(original.value);
    damaged[damaged.length - 1] ^= 1;
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: original.key,
            value: base64Encode(damaged),
          ),
        );
    await expectLater(
      DriftAgentConversationRepository(db, secrets).readAll(),
      throwsA(isA<Exception>()),
    );
    expect(
      (await db.select(db.appSettings).get()).single.value,
      base64Encode(damaged),
    );
  });
}
