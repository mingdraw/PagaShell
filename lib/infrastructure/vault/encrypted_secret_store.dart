import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../domain/vault/secret_store.dart';
import 'encrypted_vault_storage.dart';

/// macOS 只向钥匙串读取一把主密钥；服务、网关和凭证共用本地加密保险库。
///
/// 主密钥仅缓存在本实例内。旧版的逐项钥匙串记录按需迁移，只有加密文件
/// 持久化成功后才清理旧记录；没有权限时保留旧值并允许重试。
class EncryptedSecretStore implements BatchSecretStore {
  EncryptedSecretStore({
    required this._keychain,
    required this._storage,
    this.keyRef = masterKeyRef,
  });

  static const masterKeyRef = 'pagashell-vault-key-v1';
  static const _corrupt = SecretStoreException(
    '凭据保险库损坏或密钥不匹配，请保留保险库文件并检查系统钥匙串',
  );

  final SecretStore _keychain;
  final EncryptedVaultStorage _storage;
  final String keyRef;
  Uint8List? _key;
  Uint8List? _cachedCiphertext;
  Map<String, String?>? _cachedEntries;

  @override
  Future<String?> read(String ref) async => (await readMany([ref]))[ref];

  @override
  Future<Map<String, String?>> readMany(Iterable<String> refs) {
    final requested = refs.toSet();
    if (requested.isEmpty) return Future.value({});
    return _run('无法读取凭据：本地保险库不可用，请检查文件权限后重试', (transaction) async {
      final entries = await _load(transaction);
      final legacy = await _legacyEntries(entries, requested);
      if (legacy.isNotEmpty) {
        await _save(transaction, {...entries, ...legacy});
        for (final ref in legacy.keys) {
          await _keychain.delete(ref);
        }
      }
      return {for (final ref in requested) ref: legacy[ref] ?? entries[ref]};
    });
  }

  @override
  Future<void> put(String ref, String secret) async {
    await replaceMany({ref: secret});
  }

  @override
  Future<void> delete(String ref) async {
    await _replace({ref: null}, '无法删除凭据：本地保险库不可用，请检查文件权限后重试');
  }

  @override
  Future<Map<String, String?>> replaceMany(Map<String, String?> changes) =>
      _replace(Map.of(changes), '无法保存凭据：本地保险库不可用，请检查文件权限后重试');

  Future<Map<String, String?>> _replace(
    Map<String, String?> changes,
    String failure,
  ) {
    if (changes.isEmpty) return Future.value({});
    return _run(failure, (transaction) async {
      final entries = await _load(transaction);
      final legacy = await _legacyEntries(entries, changes.keys);
      final baseline = legacy.isEmpty ? entries : {...entries, ...legacy};
      // Protect legacy values before deleting their keychain copies. A failure
      // to remove a legacy key cannot commit the replacement batch.
      if (legacy.isNotEmpty) await _save(transaction, baseline);
      for (final ref in changes.keys) {
        await _keychain.delete(ref);
      }
      // Null is a tombstone, so a legacy item cannot resurrect a deleted key.
      await _save(transaction, {...baseline, ...changes});
      return {for (final ref in changes.keys) ref: baseline[ref]};
    });
  }

  Future<T> _run<T>(
    String failure,
    Future<T> Function(VaultTransaction) action,
  ) async {
    try {
      return await _storage.transaction(action);
    } on SecretStoreException {
      rethrow;
    } on Object {
      throw SecretStoreException(failure);
    }
  }

  Future<Map<String, String>> _legacyEntries(
    Map<String, String?> entries,
    Iterable<String> refs,
  ) async {
    final legacy = <String, String>{};
    for (final ref in refs) {
      if (entries.containsKey(ref)) continue;
      // The original keychain record can still require macOS authorization.
      final value = await _keychain.read(ref);
      if (value != null) legacy[ref] = value;
    }
    return legacy;
  }

  Future<Uint8List> _unlock({required bool create}) async {
    final cached = _key;
    if (cached != null) return cached;
    final encoded = await _keychain.read(keyRef);
    if (encoded != null) {
      try {
        final bytes = base64Decode(encoded);
        if (bytes.length != 32) throw const FormatException();
        return _key = bytes;
      } on FormatException {
        throw _corrupt;
      }
    }
    if (!create) {
      throw const SecretStoreException('无法解锁凭据保险库：系统钥匙串中的密钥缺失，请保留保险库文件');
    }
    final key = await AesGcm.with256bits().newSecretKey();
    final bytes = Uint8List.fromList(await key.extractBytes());
    await _keychain.put(keyRef, base64Encode(bytes));
    return _key = bytes;
  }

  Future<Map<String, String?>> _load(VaultTransaction transaction) async {
    final bytes = await transaction.read();
    if (bytes == null) {
      _cachedCiphertext = null;
      _cachedEntries = null;
      return const {};
    }
    // Compare under the file lock. A same-size replacement with the same mtime
    // must still invalidate the plaintext cache.
    if (listEquals(_cachedCiphertext, bytes)) {
      return _cachedEntries!;
    }
    _cachedCiphertext = null;
    _cachedEntries = null;
    if (bytes.length < _header.length + AesGcm.with256bits().nonceLength + 16) {
      throw _corrupt;
    }
    for (var i = 0; i < _header.length; i++) {
      if (bytes[i] != _header[i]) throw _corrupt;
    }
    final key = await _unlock(create: false);
    try {
      final snapshot = Uint8List.fromList(bytes);
      final entries = await _decodeInWorker(snapshot, key);
      _cachedCiphertext = snapshot;
      return _cachedEntries = entries;
    } on Object {
      throw _corrupt;
    }
  }

  Future<void> _save(
    VaultTransaction transaction,
    Map<String, String?> entries,
  ) async {
    final bytes = await _encodeInWorker(entries, await _unlock(create: true));
    await transaction.write(bytes);
    _cachedCiphertext = Uint8List.fromList(bytes);
    _cachedEntries = entries;
  }
}

final _header = utf8.encode('PagaShellVault1\n');

Future<Map<String, String?>> _decodeInWorker(Uint8List bytes, Uint8List key) =>
    Isolate.run(() async {
      final cipher = AesGcm.with256bits();
      final box = SecretBox.fromConcatenation(
        Uint8List.sublistView(bytes, _header.length),
        nonceLength: cipher.nonceLength,
        macLength: 16,
      );
      final plain = await cipher.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: _header,
      );
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['entries'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return Map<String, String?>.from(
        decoded['entries'] as Map<String, dynamic>,
      );
    });

Future<Uint8List> _encodeInWorker(
  Map<String, String?> entries,
  Uint8List key,
) => Isolate.run(() async {
  // A fresh random nonce for every write; the header is authenticated.
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode({'version': 1, 'entries': entries})),
    secretKey: SecretKey(key),
    aad: _header,
  );
  return Uint8List.fromList([..._header, ...box.concatenation()]);
});
