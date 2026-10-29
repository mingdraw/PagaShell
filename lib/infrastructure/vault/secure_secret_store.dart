import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/vault/secret_store.dart';

/// 基于系统钥匙串的密文存储：
/// macOS Keychain / Windows DPAPI / Linux Secret Service（libsecret）。
///
/// 密码/私钥密文只进操作系统安全存储，绝不明文落盘到应用数据库或日志。
///
/// 钥匙串不可用时明确失败，不伪装保存成功，也不记录平台异常原文。
class SecureSecretStore implements SecretStore {
  const SecureSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<void> put(String ref, String secret) async {
    try {
      await _storage.write(key: ref, value: secret);
    } on Object {
      throw const SecretStoreException('无法保存凭据：系统钥匙串不可用，请解锁钥匙串后重试');
    }
  }

  @override
  Future<String?> read(String ref) async {
    try {
      return await _storage.read(key: ref);
    } on Object {
      throw const SecretStoreException('无法读取凭据：系统钥匙串不可用，请解锁钥匙串后重试');
    }
  }

  @override
  Future<void> delete(String ref) async {
    try {
      // 先读后删：flutter_secure_storage 在 macOS 传统钥匙串上删除
      // 不存在的条目会误报 -34018（其内部先以 synchronizable=true 探测，
      // 该查询在传统钥匙串上必然失败，条目不存在时此错误被当作结果上抛）。
      // 条目本就不存在时无需删除，也避免了这一噪声。
      if (await _storage.read(key: ref) == null) return;
      await _storage.delete(key: ref);
    } on Object {
      throw const SecretStoreException('无法删除凭据：系统钥匙串不可用，请解锁钥匙串后重试');
    }
  }
}
