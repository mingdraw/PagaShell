part of 'session_controller.dart';

/// 仅在当前进程保存的会话资源；UI 继续使用不可变的 Session 快照。
class _SessionRuntime {
  SshCredentials? credentials;
  SshGateway? gateway;
  Completer<void>? connectionCancel;
  Completer<bool>? hostKeyDecision;
  Completer<String?>? passwordDecision;
  StreamSubscription<Object?>? outputSubscription;
  StreamSubscription<PortForwardEvent>? forwardSubscription;
  Future<void>? forwardCleanup;
  Future<void>? proxyCleanup;
  Completer<void>? proxyStarting;
  DynamicProxySession? proxyHandle;
  SystemProxyLease? systemProxyLease;
  bool proxyRestoreFailed = false;
  Future<void>? tabCloseRequest;

  void cancelPending() {
    final cancellation = connectionCancel;
    connectionCancel = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final hostKey = takeHostKeyDecision();
    if (hostKey != null && !hostKey.isCompleted) hostKey.complete(false);
    final password = passwordDecision;
    passwordDecision = null;
    if (password != null && !password.isCompleted) password.complete(null);
    credentials = null;
    gateway = null;
  }

  Completer<bool>? takeHostKeyDecision() {
    final decision = hostKeyDecision;
    hostKeyDecision = null;
    return decision;
  }

  Future<void>? cancelOutputSubscription() {
    final cancellation = outputSubscription?.cancel();
    outputSubscription = null;
    return cancellation;
  }

  Future<void>? cancelForwardSubscription() {
    final cancellation = forwardSubscription?.cancel();
    forwardSubscription = null;
    return cancellation;
  }
}
