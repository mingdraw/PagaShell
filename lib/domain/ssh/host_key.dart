enum ServerIdentityProtocol { ssh, rdp }

/// 服务器身份摘要；历史名称保留，协议用于隔离 SSH 密钥与 RDP 证书。
class SshHostKey {
  const SshHostKey({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    this.protocol = ServerIdentityProtocol.ssh,
    this.certificateError,
  });

  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;
  final ServerIdentityProtocol protocol;

  /// RDP PKI verification failure code; never persisted as a trust decision.
  final String? certificateError;
  bool get isRdp => protocol == ServerIdentityProtocol.rdp;

  bool matches(SshHostKey other) =>
      protocol == other.protocol &&
      keyType == other.keyType &&
      fingerprint == other.fingerprint;
}

/// 待用户核验的身份；RDP 可明确确认本次例外，SSH 变更仍拒绝。
class HostKeyReview {
  const HostKeyReview({required this.presented, this.trusted});

  final SshHostKey presented;
  final SshHostKey? trusted;
  bool get hasChanged => trusted != null && !trusted!.matches(presented);
}

typedef HostKeyVerifier = Future<bool> Function(SshHostKey key);
