import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../domain/vault/secret_store.dart';
import 'encrypted_vault_storage.dart';

/// macOS 只向钥匙串读取一把主密钥；服务、网关和凭证共用本地加密保险库。
///
/// 主密钥仅缓存在本实例内。旧版的逐项钥匙串记录按需迁移，只有加密文件
/// 持久化成功后才清理旧记录；没有权限时保留旧值并允许重试。
class EncryptedSecretStore implements SecretStore {
  EncryptedSecretStore({
    required this._keychain,
    required this._storage,
    this.keyRef = masterKeyRef,
  });

  static const masterKeyRef = 'pagashell-vault-key-v1';
  static final _header = utf8.encode('PagaShellVault1\n');
  static const _corrupt = SecretStoreException(
    '凭据保险库损坏或密钥不匹配，请保留保险库文件并检查系统钥匙串',
  );

  final SecretStore _keychain;
  final EncryptedVaultStorage _storage;
  final String keyRef;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;

  @override
  Future<String?> read(String ref) =>
      _run('无法读取凭据：本地保险库不可用，请检查文件权限后重试', (transaction) async {
        final entries = await _load(transaction);
        if (entries.containsKey(ref)) return entries[ref];
        // 旧条目的访问控制仍由 macOS 决定，无法用主密钥绕过首次授权。
        final legacy = await _keychain.read(ref);
        if (legacy == null) return null;
        entries[ref] = legacy;
        await _save(transaction, entries);
        await _keychain.delete(ref);
        return legacy;
      });

  @override
  Future<void> put(String ref, String secret) =>
      _run('无法保存凭据：本地保险库不可用，请检查文件权限后重试', (transaction) async {
        final entries = await _loadForChange(transaction, ref);
        // 先保证旧值已有加密副本，再清理旧项；清理失败不能提交替换值。
        await _keychain.delete(ref);
        entries[ref] = secret;
        await _save(transaction, entries);
      });

  @override
  Future<void> delete(String ref) =>
      _run('无法删除凭据：本地保险库不可用，请检查文件权限后重试', (transaction) async {
        final entries = await _loadForChange(transaction, ref);
        await _keychain.delete(ref);
        // 保留已删除标记：旧版本重新写入时，不能回退复活。
        entries[ref] = null;
        await _save(transaction, entries);
      });

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

  Future<Map<String, String?>> _loadForChange(
    VaultTransaction transaction,
    String ref,
  ) async {
    final entries = await _load(transaction);
    if (!entries.containsKey(ref)) {
      final legacy = await _keychain.read(ref);
      if (legacy != null) {
        entries[ref] = legacy;
        await _save(transaction, entries);
      }
    }
    return entries;
  }

  Future<SecretKey> _unlock({required bool create}) async {
    final cached = _key;
    if (cached != null) return cached;
    final encoded = await _keychain.read(keyRef);
    if (encoded != null) {
      try {
        final bytes = base64Decode(encoded);
        if (bytes.length != 32) throw const FormatException();
        return _key = SecretKey(bytes);
      } on FormatException {
        throw _corrupt;
      }
    }
    if (!create) {
      throw const SecretStoreException('无法解锁凭据保险库：系统钥匙串中的密钥缺失，请保留保险库文件');
    }
    final key = await _cipher.newSecretKey();
    await _keychain.put(keyRef, base64Encode(await key.extractBytes()));
    return _key = key;
  }

  Future<Map<String, String?>> _load(VaultTransaction transaction) async {
    final bytes = await transaction.read();
    if (bytes == null) return {};
    if (bytes.length < _header.length + _cipher.nonceLength + 16) {
      throw _corrupt;
    }
    for (var i = 0; i < _header.length; i++) {
      if (bytes[i] != _header[i]) throw _corrupt;
    }
    final key = await _unlock(create: false);
    try {
      final box = SecretBox.fromConcatenation(
        bytes.sublist(_header.length),
        nonceLength: _cipher.nonceLength,
        macLength: 16,
      );
      final plain = await _cipher.decrypt(box, secretKey: key, aad: _header);
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['entries'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return Map<String, String?>.from(
        decoded['entries'] as Map<String, dynamic>,
      );
    } on Object {
      throw _corrupt;
    }
  }

  Future<void> _save(
    VaultTransaction transaction,
    Map<String, String?> entries,
  ) async {
    final key = await _unlock(create: true);
    // 每次写入生成独立随机 nonce，格式版本同时作为认证数据。
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode({'version': 1, 'entries': entries})),
      secretKey: key,
      aad: _header,
    );
    await transaction.write([..._header, ...box.concatenation()]);
  }
}
