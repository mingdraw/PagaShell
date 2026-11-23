import 'dart:convert';
import 'dart:isolate';

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
  static const summaryPrefix = 'agent.chat.summary.v1.';
  static const secretRef = 'pagashell-agent-history-key-v1';
  final AppDatabase _db;
  final SecretStore _secrets;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;
  Future<SecretKey>? _unlocking;

  Future<SecretKey> _unlock({required bool create}) {
    if (_key case final key?) return Future.value(key);
    return _unlocking ??= _readKey(create: create).whenComplete(() {
      _unlocking = null;
    });
  }

  static String _prefixEnd(String prefix) =>
      '${prefix.substring(0, prefix.length - 1)}/';

  Expression<bool> _keyRange(String prefix) =>
      _db.appSettings.key.isBiggerOrEqualValue(prefix) &
      _db.appSettings.key.isSmallerThanValue(_prefixEnd(prefix));

  Future<SecretKey> _readKey({required bool create}) async {
    final encoded = await _secrets.read(secretRef);
    if (encoded != null) {
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) throw const FormatException();
      return _key = SecretKey(bytes);
    }
    if (!create) throw const FormatException();
    final existing = _db.selectOnly(_db.appSettings)
      ..addColumns([_db.appSettings.key])
      ..where(_keyRange(keyPrefix) | _keyRange(summaryPrefix))
      ..limit(1);
    // If the vault key has been lost, generating a replacement cannot recover history.
    if (await existing.getSingleOrNull() != null) throw const FormatException();
    final key = await _cipher.newSecretKey();
    await _secrets.put(secretRef, base64Encode(await key.extractBytes()));
    return _key = key;
  }

  @override
  Future<List<AgentConversationSummary>> readSummaries() async {
    await _backfillSummaries();
    final rows = await (_db.select(
      _db.appSettings,
    )..where((_) => _keyRange(summaryPrefix))).get();
    if (rows.isEmpty) return [];
    final key = await _unlock(create: false);
    return _decodeSummaries(await key.extractBytes(), [
      for (final row in rows) (row.key, row.value),
    ]);
  }

  Future<void> _backfillSummaries() async {
    var after = keyPrefix;
    while (true) {
      // Only legacy records without a summary transfer the body from SQLite.
      final rows = await _db
          .customSelect(
            '''SELECT body.key, body.value FROM app_settings AS body
           WHERE body.key > ? AND body.key < ?
             AND NOT EXISTS (SELECT 1 FROM app_settings AS summary
               WHERE summary.key = ? || substr(body.key, ?))
           ORDER BY body.key LIMIT 12''',
            variables: [
              Variable(after),
              Variable(_prefixEnd(keyPrefix)),
              const Variable(summaryPrefix),
              Variable(keyPrefix.length + 1),
            ],
            readsFrom: {_db.appSettings},
          )
          .get();
      if (rows.isEmpty) return;
      final sealed = [
        for (final row in rows)
          (row.read<String>('key'), row.read<String>('value')),
      ];
      final key = await _unlock(create: false);
      final values = await _summarizeLegacy(await key.extractBytes(), sealed);
      await _db.batch((batch) {
        for (var i = 0; i < sealed.length; i++) {
          final (rowKey, body) = sealed[i];
          // Don't resurrect a removed record, overwrite a newer summary, or edit its body.
          batch.customStatement(
            '''INSERT INTO app_settings (key, value) SELECT ?, ?
               WHERE EXISTS (SELECT 1 FROM app_settings WHERE key = ? AND value = ?)
               ON CONFLICT(key) DO NOTHING''',
            [
              '$summaryPrefix${rowKey.substring(keyPrefix.length)}',
              values[i],
              rowKey,
              body,
            ],
          );
        }
      });
      after = sealed.last.$1;
    }
  }

  @override
  Future<AgentConversation?> read(String id) async {
    final rowKey = '$keyPrefix$id';
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(rowKey))).getSingleOrNull();
    if (row == null) return null;
    final key = await _unlock(create: false);
    return _decodeConversation(await key.extractBytes(), (rowKey, row.value));
  }

  @override
  Future<void> save(AgentConversation conversation) async {
    final key = await _unlock(create: true);
    final rows = await _encodeConversation(
      await key.extractBytes(),
      conversation,
    );
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(_db.appSettings, [
        for (final (key, value) in rows)
          AppSettingsCompanion.insert(key: key, value: value),
      ]);
    });
  }

  @override
  Future<void> remove(String id) async {
    await (_db.delete(
      _db.appSettings,
    )..where((s) => s.key.isIn(['$keyPrefix$id', '$summaryPrefix$id']))).go();
  }
}

// 以下函数在后台 isolate 中运行，只接收可传递的纯数据。

final _isolateCipher = AesGcm.with256bits();
typedef _SealedRow = (String, String);

Future<List<_SealedRow>> _encodeConversation(
  List<int> keyBytes,
  AgentConversation conversation,
) => Isolate.run(() async {
  final key = SecretKey(keyBytes);
  final bodyKey =
      '${DriftAgentConversationRepository.keyPrefix}${conversation.id}';
  final summaryKey =
      '${DriftAgentConversationRepository.summaryPrefix}${conversation.id}';
  return [
    (bodyKey, await _seal(key, bodyKey, conversation.toJson())),
    (summaryKey, await _seal(key, summaryKey, conversation.summary.toJson())),
  ];
});

Future<AgentConversation> _decodeConversation(
  List<int> keyBytes,
  _SealedRow row,
) => Isolate.run(() async {
  final conversation = AgentConversation.fromJson(
    await _open(SecretKey(keyBytes), row),
  );
  if (row.$1 !=
      '${DriftAgentConversationRepository.keyPrefix}${conversation.id}') {
    throw const FormatException();
  }
  return conversation;
});

Future<List<AgentConversationSummary>> _decodeSummaries(
  List<int> keyBytes,
  List<_SealedRow> rows,
) => Isolate.run(() async {
  final key = SecretKey(keyBytes);
  final result = <AgentConversationSummary>[];
  for (final row in rows) {
    final summary = AgentConversationSummary.fromJson(await _open(key, row));
    if (row.$1 !=
        '${DriftAgentConversationRepository.summaryPrefix}${summary.id}') {
      throw const FormatException();
    }
    result.add(summary);
  }
  return result..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
});

Future<List<String>> _summarizeLegacy(
  List<int> keyBytes,
  List<_SealedRow> rows,
) => Isolate.run(() async {
  final key = SecretKey(keyBytes);
  final result = <String>[];
  for (final row in rows) {
    final json = await _open(key, row);
    json['messageCount'] = (json['messages'] as List<Object?>).length;
    final summary = AgentConversationSummary.fromJson(json);
    if (row.$1 !=
        '${DriftAgentConversationRepository.keyPrefix}${summary.id}') {
      throw const FormatException();
    }
    final summaryKey =
        '${DriftAgentConversationRepository.summaryPrefix}${summary.id}';
    result.add(await _seal(key, summaryKey, summary.toJson()));
  }
  return result;
});

Future<String> _seal(
  SecretKey key,
  String rowKey,
  Map<String, dynamic> json,
) async {
  final box = await _isolateCipher.encrypt(
    utf8.encode(jsonEncode(json)),
    secretKey: key,
    aad: utf8.encode(rowKey),
  );
  return base64Encode(box.concatenation());
}

Future<Map<String, dynamic>> _open(SecretKey key, _SealedRow row) async {
  final (rowKey, value) = row;
  final bytes = await _isolateCipher.decrypt(
    SecretBox.fromConcatenation(
      base64Decode(value),
      nonceLength: _isolateCipher.nonceLength,
      macLength: 16,
    ),
    secretKey: key,
    aad: utf8.encode(rowKey),
  );
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}
