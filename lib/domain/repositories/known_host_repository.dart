import '../ssh/host_key.dart';

abstract interface class KnownHostRepository {
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  });

  /// 原子地保存首次确认的密钥。已有不同密钥时返回 false，禁止覆盖。
  Future<bool> trustIfAbsent(SshHostKey key);

  /// 只删除端点和指纹均与旧记录一致的密钥，避免清除并发更新后的信任。
  Future<bool> removeIfMatches(SshHostKey key);
}
