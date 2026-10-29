/// 密文存取的抽象接口：密码 / 私钥 / passphrase 一律经此存取，
/// 禁止出现在实体、普通存储或日志中。
///
/// macOS 使用钥匙串托管主密钥 + AES-256-GCM 保险库；其他平台直接使用
/// 系统安全存储。普通数据库只保留引用，内存版仅供测试。
abstract interface class SecretStore {
  Future<void> put(String ref, String secret);

  /// 不存在时返回 null。
  Future<String?> read(String ref);

  Future<void> delete(String ref);
}

/// 仅包含可展示的操作说明，不保留可能含敏感信息的平台异常原文。
class SecretStoreException implements Exception {
  const SecretStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
