import 'package:xterm/xterm.dart';

import '../../domain/entities/host.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/host_key.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 会话生命周期状态机。
///
/// connecting → hostKeyPending → authenticating → ready
///      └───────────────┴──────────────┴────→ failed
/// ready → reconnecting → ready / failed
/// 端口转发 ready → stopping → closed
/// 任意状态 → closed
enum SessionPhase {
  connecting,
  authenticating,
  hostKeyPending,
  credentialsPending,
  ready,
  reconnecting,
  stopping,
  failed,
  closed;

  /// 会话是否仍占用连接资源。
  bool get isAlive => this != failed && this != closed;

  /// 是否处于过渡态（UI 显示加载指示）。
  bool get isBusy =>
      this == connecting ||
      this == hostKeyPending ||
      this == credentialsPending ||
      this == authenticating ||
      this == reconnecting ||
      this == stopping;
}

enum SessionKind { terminal, fileTransfer, portForward, remoteDesktop }

/// 一个终端、文件传输或端口转发标签对应的会话快照（不可变）。
class Session {
  const Session({
    required this.id,
    required this.host,
    this.loginUsername,
    this.kind = SessionKind.terminal,
    this.phase = SessionPhase.connecting,
    this.error,
    this.engineSession,
    this.terminal,
    this.hostKeyReview,
    this.hostKeyFailure,
    this.desktopSession,
    this.passwordRequest,
  });

  final String id;
  final Host host;

  /// 实际连接的目标用户名；与服务配置分开保留，不包含密码或密钥。
  final String? loginUsername;

  String get address {
    final username = loginUsername ?? host.username;
    return host.port == 22
        ? '$username@${host.hostname}'
        : '$username@${host.hostname}:${host.port}';
  }

  final SessionKind kind;
  String get title => host.name;
  final SessionPhase phase;

  /// [SessionPhase.failed] 时的原因描述。
  final String? error;

  final HostKeyReview? hostKeyReview;

  /// 失败连接中发生变化的 SSH 端点，可能属于目标服务器或网关。
  final HostKeyReview? hostKeyFailure;
  final RdpPasswordRequest? passwordRequest;

  /// ready 后持有的引擎会话句柄。
  final SshEngineSession? engineSession;
  final RdpEngineSession? desktopSession;

  /// ready 后与 [engineSession] 双向绑定的 xterm 终端（跨快照复用同一实例）。
  final Terminal? terminal;

  Session copyWith({
    Host? host,
    String? loginUsername,
    SessionPhase? phase,
    String? error,
    SshEngineSession? engineSession,
    Terminal? terminal,
    HostKeyReview? hostKeyReview,
    HostKeyReview? hostKeyFailure,
    RdpEngineSession? desktopSession,
    RdpPasswordRequest? passwordRequest,
  }) {
    return Session(
      id: id,
      host: host ?? this.host,
      loginUsername: loginUsername ?? this.loginUsername,
      kind: kind,
      phase: phase ?? this.phase,
      error: error ?? this.error,
      engineSession: engineSession ?? this.engineSession,
      desktopSession: desktopSession ?? this.desktopSession,
      terminal: terminal ?? this.terminal,
      hostKeyReview: (phase ?? this.phase) == SessionPhase.hostKeyPending
          ? hostKeyReview ?? this.hostKeyReview
          : null,
      hostKeyFailure: (phase ?? this.phase) == SessionPhase.failed
          ? hostKeyFailure ?? this.hostKeyFailure
          : null,
      passwordRequest: switch (phase ?? this.phase) {
        SessionPhase.credentialsPending ||
        SessionPhase.failed => passwordRequest ?? this.passwordRequest,
        _ => null,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.id == id &&
      identical(other.host, host) &&
      other.loginUsername == loginUsername &&
      other.kind == kind &&
      other.phase == phase &&
      other.error == error &&
      other.hostKeyReview == hostKeyReview &&
      other.hostKeyFailure == hostKeyFailure &&
      other.passwordRequest == passwordRequest;

  @override
  int get hashCode => Object.hash(
    id,
    identityHashCode(host),
    loginUsername,
    kind,
    phase,
    error,
    hostKeyReview,
    hostKeyFailure,
    passwordRequest,
  );
}

/// 仅包含弹框所需的目标与错误信息，不含被拒绝的密码。
class RdpPasswordRequest {
  const RdpPasswordRequest({
    required this.host,
    required this.username,
    required this.error,
  });

  final Host host;
  final String username;
  final String error;
}
