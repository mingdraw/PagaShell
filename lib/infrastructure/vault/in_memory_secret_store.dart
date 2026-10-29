import '../../domain/vault/secret_store.dart';

/// 内存版密文存储：进程退出即失，仅用于加密 Vault（M2）落地前。
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _secrets = {};

  @override
  Future<void> put(String ref, String secret) async {
    _secrets[ref] = secret;
  }

  @override
  Future<String?> read(String ref) async => _secrets[ref];

  @override
  Future<void> delete(String ref) async {
    _secrets.remove(ref);
  }
}
