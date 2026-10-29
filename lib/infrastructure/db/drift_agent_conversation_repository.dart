import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';

import '../../domain/ai/agent_conversation.dart';
import '../../domain/repositories/agent_conversation_repository.dart';
import '../../domain/vault/secret_store.dart';
import 'app_database.dart';

/// 对话密文保存在 SQLite，独立的数据密钥由凭据保险库管理。
class DriftAgentConversationRepository implements AgentConversationRepository {
  DriftAgentConversationRepository(this._db, this._secrets);

  static const keyPrefix = 'agent.chat.v1.';
  static const secretRef = 'pagashell-agent-history-key-v1';
  final AppDatabase _db;
  final SecretStore _secrets;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;

  Future<SecretKey> _unlock({required bool create}) async {
    if (_key != null) return _key!;
    final encoded = await _secrets.read(secretRef);
    if (encoded != null) {
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) throw const FormatException();
      return _key = SecretKey(bytes);
    }
    if (!create) throw const FormatException();
    final key = await _cipher.newSecretKey();
    await _secrets.put(secretRef, base64Encode(await key.extractBytes()));
    return _key = key;
  }

  @override
  Future<List<AgentConversation>> readAll() async {
    final rows = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.like('$keyPrefix%'))).get();
    if (rows.isEmpty) return [];
    final key = await _unlock(create: false);
    final result = <AgentConversation>[];
    for (final row in rows) {
      final box = SecretBox.fromConcatenation(
        base64Decode(row.value),
        nonceLength: _cipher.nonceLength,
        macLength: 16,
      );
      final bytes = await _cipher.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode(row.key),
      );
      final conversation = AgentConversation.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      if (row.key != '$keyPrefix${conversation.id}') {
        throw const FormatException();
      }
      result.add(conversation);
    }
    return result..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<void> save(AgentConversation conversation) async {
    // 有历史但密钥丢失时禁止生成新密钥覆盖旧记录。
    final existing =
        await (_db.select(_db.appSettings)
              ..where((s) => s.key.like('$keyPrefix%'))
              ..limit(1))
            .get();
    final key = await _unlock(create: existing.isEmpty);
    final rowKey = '$keyPrefix${conversation.id}';
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(conversation.toJson())),
      secretKey: key,
      aad: utf8.encode(rowKey),
    );
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: rowKey,
            value: base64Encode(box.concatenation()),
          ),
        );
  }

  @override
  Future<void> remove(String id) async {
    await (_db.delete(
      _db.appSettings,
    )..where((s) => s.key.equals('$keyPrefix$id'))).go();
  }
}
