import 'dart:async';

import 'package:get/get.dart';
import 'package:xterm/xterm.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/repositories/known_host_repository.dart';
import '../../domain/ssh/host_key.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../transfer/transfer_controller.dart';
import 'session.dart';

/// 全局会话控制器：负责终端、文件传输与端口转发标签的创建、激活与关闭。
///
/// [SshEngine] 通过构造函数显式注入（装配见 AppBinding），
/// 测试中可直接 new 并传入假引擎，不依赖 Get 容器。
class SessionController extends GetxController {
  SessionController({
    required this._engine,
    this._knownHosts,
    this._transfers,
    this._rdpEngine,
    this._vncEngine,
  });

  final SshEngine _engine;
  final RdpEngine? _rdpEngine;
  final VncEngine? _vncEngine;
  final KnownHostRepository? _knownHosts;
  final TransferController? _transfers;
  final Map<String, Completer<bool>> _hostKeyDecisions = {};
  final Map<String, Completer<String?>> _passwordDecisions = {};
  final Map<String, Completer<void>> _connectionCancels = {};
  bool _disposed = false;

  final RxList<Session> sessions = <Session>[].obs;
  final RxnString activeSessionId = RxnString();

  /// 连接凭据仅保存在内存中（供断线/失败重试复用），随会话关闭清除。
  final Map<String, SshCredentials> _credentials = {};
  final Map<String, SshGateway> _gateways = {};
  final Map<String, StreamSubscription<String>> _outputSubs = {};
  final Map<String, StreamSubscription<PortForwardEvent>> _forwardSubs = {};
  final Map<String, Future<void>> _forwardCleanup = {};
  // 标签关闭后仍需按服务跟踪清理，重新启动必须等旧监听端口释放。
  final Map<String, Future<void>> _forwardHostCleanup = {};

  int _nextId = 1;

  /// 当前激活的会话（无则为 null）。在 Obx 中访问可响应变化。
  Session? get activeSession {
    final id = activeSessionId.value;
    return id == null ? null : _find(id);
  }

  /// 可接收批量命令的交互终端；SFTP 和转发连接不具有 shell。
  List<Session> get commandSessions => sessions.where(_canSendCommand).toList();

  static bool _canSendCommand(Session session) =>
      session.kind == SessionKind.terminal &&
      session.phase == SessionPhase.ready &&
      session.engineSession != null &&
      session.terminal?.onOutput != null;

  /// 只负责把输入排入各终端通道，不代表远端命令已执行成功。
  BatchCommandResult sendCommandToSessions(
    Iterable<String> sessionIds,
    String command,
  ) {
    if (_disposed || command.trim().isEmpty) {
      return const BatchCommandResult();
    }
    final text = command.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var sent = 0;
    var skipped = 0;
    var failed = 0;
    for (final id in sessionIds.toSet()) {
      final session = _find(id);
      if (session == null || !_canSendCommand(session)) {
        skipped++;
        continue;
      }
      final terminal = session.terminal!;
      // 一次写入包含粘贴和最终回车，避免异步通道拆包导致回车先到达。
      final input = terminal.bracketedPasteMode
          ? '\x1b[200~$text\x1b[201~\r'
          : '${text.replaceAll('\n', '\r')}${text.endsWith('\n') ? '' : '\r'}';
      try {
        terminal.textInput(input);
        sent++;
      } on Object {
        // 一个连接写入失败不能阻断其他目标，也不暴露输入及底层错误。
        failed++;
      }
    }
    return BatchCommandResult(sent: sent, skipped: skipped, failed: failed);
  }

  /// 为 [host] 打开一个新会话标签并发起连接。返回会话 id。
  Future<String> open(
    Host host,
    SshCredentials credentials, {
    SessionKind kind = SessionKind.terminal,
    SshGateway? gateway,
  }) async {
    if (kind == SessionKind.portForward) {
      throw ArgumentError('请通过端口转发页签手动启动');
    }
    if (host.isDesktop) {
      if (kind == SessionKind.fileTransfer) {
        throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
      }
      kind = SessionKind.remoteDesktop;
    }
    final id = 'ssn-${_nextId++}';
    sessions.add(
      Session(
        id: id,
        host: host,
        kind: kind,
        loginUsername: credentials.username ?? host.username,
      ),
    );
    activeSessionId.value = id;
    _credentials[id] = credentials;
    if (gateway != null) _gateways[id] = gateway;

    await _connect(id, host, credentials);
    return id;
  }

  /// 打开配置页签，不读取凭据、不建立连接。
  String openForward(Host host) {
    if (host.isDesktop) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    final existing = findByHost(host.id, kind: SessionKind.portForward);
    if (existing != null) {
      activate(existing.id);
      return existing.id;
    }
    final id = 'ssn-${_nextId++}';
    sessions.add(
      Session(
        id: id,
        host: host,
        kind: SessionKind.portForward,
        phase: SessionPhase.closed,
      ),
    );
    activeSessionId.value = id;
    return id;
  }

  /// 每次启动都由调用方重新准备服务、凭据及网关。
  Future<void> startForward(
    String id,
    Host host,
    SshCredentials credentials, {
    SshGateway? gateway,
  }) async {
    if (host.isDesktop) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.kind != SessionKind.portForward ||
        session.host.id != host.id ||
        session.phase.isAlive) {
      return;
    }
    ForwardPort.validateAll(host.forwardPorts, allowEmpty: false);
    _credentials[id] = credentials;
    _gateways.remove(id);
    if (gateway != null) _gateways[id] = gateway;
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: host,
        kind: s.kind,
        loginUsername: credentials.username ?? host.username,
      ),
    );
    await _connect(id, host, credentials);
  }

  void updateForwardHost(Host host) {
    final session = findByHost(host.id, kind: SessionKind.portForward);
    if (session != null && !session.phase.isAlive) {
      _update(session.id, (s) => s.copyWith(host: host));
    }
  }

  Future<void> closeForwardForHost(String hostId) async {
    final ids = sessions
        .where((s) => s.host.id == hostId && s.kind == SessionKind.portForward)
        .map((s) => s.id)
        .toList();
    await Future.wait(ids.map(close));
    await _forwardHostCleanup[hostId];
  }

  /// 认证失败后先重新输入密码；其他失败沿用当前会话凭据。
  Future<void> retry(String id) async {
    final session = _find(id);
    final credentials = _credentials[id];
    if (session == null ||
        session.kind == SessionKind.portForward ||
        session.phase != SessionPhase.failed ||
        credentials == null) {
      return;
    }
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        loginUsername: s.loginUsername,
      ),
    );
    await _connect(
      id,
      session.host,
      credentials,
      passwordRequest: session.passwordRequest,
    );
  }

  /// 仅清除本次失败涉及的旧 SSH 指纹，重连后仍须明确确认新指纹。
  Future<void> clearHostKeyAndRetry(String id) async {
    final session = _find(id);
    final review = session?.hostKeyFailure;
    final trusted = review?.trusted;
    final repository = _knownHosts;
    final credentials = _credentials[id];
    if (_disposed ||
        session == null ||
        session.kind == SessionKind.portForward ||
        session.phase != SessionPhase.failed ||
        review == null ||
        !review.hasChanged ||
        review.presented.isRdp ||
        trusted == null ||
        repository == null ||
        credentials == null) {
      return;
    }
    // 先进入过渡态，重复点击和普通重试不能与删除操作并发。
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.reconnecting,
        loginUsername: s.loginUsername,
      ),
    );
    try {
      if (!await repository.removeIfMatches(trusted) &&
          await repository.find(
                trusted.hostname,
                trusted.port,
                protocol: trusted.protocol,
              ) !=
              null) {
        throw const SshEngineException('指纹记录已更新，请重试连接');
      }
    } on Object catch (e) {
      if (!_disposed) {
        _update(
          id,
          (s) => s.copyWith(
            phase: SessionPhase.failed,
            error: e is SshEngineException ? e.message : '无法清除主机指纹，请重试',
            hostKeyFailure: review,
          ),
        );
      }
      return;
    }
    if (_disposed || _find(id) == null) return;
    await _connect(
      id,
      session.host,
      credentials,
      passwordRequest: session.passwordRequest,
    );
  }

  Future<void> _connect(
    String id,
    Host host,
    SshCredentials credentials, {
    RdpPasswordRequest? passwordRequest,
  }) async {
    if (passwordRequest != null &&
        !await _replaceRdpPassword(id, passwordRequest)) {
      return;
    }
    while (!_disposed && _find(id) != null) {
      final failure = await _connectOnce(
        id,
        host,
        _credentials[id] ?? credentials,
      );
      final session = _find(id);
      if (failure == null || _disposed || session == null) return;
      final login = _credentials[id];
      if (login == null) {
        _update(
          id,
          (s) => s.copyWith(phase: SessionPhase.failed, error: failure.message),
        );
        return;
      }
      final request = RdpPasswordRequest(
        host: host,
        username: login.username ?? host.username,
        error: failure.message,
      );
      if (!await _replaceRdpPassword(id, request)) return;
    }
  }

  Future<bool> _replaceRdpPassword(
    String id,
    RdpPasswordRequest request,
  ) async {
    if (_disposed || _find(id) == null) return false;
    final decision = Completer<String?>();
    _passwordDecisions[id] = decision;
    _update(
      id,
      (s) => s.copyWith(
        phase: SessionPhase.credentialsPending,
        error: request.error,
        passwordRequest: request,
      ),
    );
    String? password;
    try {
      password = await decision.future;
    } finally {
      if (identical(_passwordDecisions[id], decision)) {
        _passwordDecisions.remove(id);
      }
    }
    if (_disposed || _find(id) == null) return false;
    if (password == null) {
      _update(id, (s) => s.copyWith(phase: SessionPhase.failed));
      return false;
    }
    _credentials[id] = SshCredentials.password(
      password,
      username: _credentials[id]?.username,
    );
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        loginUsername: s.loginUsername,
      ),
    );
    return true;
  }

  void confirmRdpPassword(
    String id, {
    required RdpPasswordRequest request,
    String? password,
  }) {
    final decision = _passwordDecisions[id];
    if (decision == null ||
        decision.isCompleted ||
        !identical(_find(id)?.passwordRequest, request) ||
        (password != null && password.isEmpty)) {
      return;
    }
    decision.complete(password);
  }

  Future<DesktopAuthenticationException?> _connectOnce(
    String id,
    Host host,
    SshCredentials credentials,
  ) async {
    final cancellation = Completer<void>();
    _connectionCancels[id] = cancellation;
    try {
      final session = _find(id);
      final cleanup = session?.kind == SessionKind.portForward
          ? _forwardHostCleanup[host.id]
          : null;
      if (cleanup != null) {
        await cleanup;
        if (_disposed || _find(id) == null) return null;
      }
      if (host.gatewayId != null && _gateways[id]?.host.id != host.gatewayId) {
        throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
      }
      if (host.isDesktop) {
        final engine = host.isVnc ? _vncEngine : _rdpEngine;
        if (engine == null) throw const SshEngineException('当前引擎不支持远程桌面');
        final desktop = await engine.connectDesktop(
          host,
          credentials,
          verifyHostKey: (key) => _verifyHostKey(id, key),
          cancelled: cancellation.future,
          gateway: _gateways[id],
        );
        if (_disposed || _find(id) == null) {
          await desktop.close();
          return null;
        }
        _update(
          id,
          (s) => s.copyWith(phase: SessionPhase.ready, desktopSession: desktop),
        );
        return null;
      }
      final engineSession = await _engine.connect(
        host,
        credentials,
        verifyHostKey: (key) => _verifyHostKey(id, key),
        cancelled: cancellation.future,
        gateway: _gateways[id],
      );
      // 会话可能在 connect 期间被用户关闭。
      if (_disposed || _find(id) == null) {
        await engineSession.close();
        return null;
      }

      if (_find(id)!.kind == SessionKind.portForward) {
        _update(id, (s) => s.copyWith(engineSession: engineSession));
        if (engineSession is! PortForwardSession) {
          throw const SshEngineException('当前引擎不支持端口转发');
        }
        final forwarder = engineSession as PortForwardSession;
        _forwardSubs[id] = forwarder
            .startPortForwards(host.forwardPorts)
            .listen(
              (event) {
                if (event.kind == 'ready') {
                  _update(id, (s) => s.copyWith(phase: SessionPhase.ready));
                } else if (event.kind == 'connectionError') {
                  _update(
                    id,
                    (s) => s.copyWith(
                      error: '本地端口 ${event.localPort} 的目标连接失败，请检查服务端口和转发权限',
                    ),
                  );
                } else if (event.kind == 'closed') {
                  unawaited(_forwardFailed(id, '端口转发已断开'));
                }
              },
              onError: (Object e) => unawaited(
                _forwardFailed(
                  id,
                  e is SshEngineException ? e.message : e.toString(),
                ),
              ),
              onDone: () => unawaited(_forwardFailed(id, '端口转发已断开')),
            );
        return null;
      }

      // 文件传输标签持有独立连接，不启动 shell，也不依赖终端退出事件。
      Terminal? terminal;
      if (_find(id)!.kind == SessionKind.terminal) {
        terminal = Terminal(maxLines: 10000);
        final output = engineSession.startShell(
          cols: terminal.viewWidth,
          rows: terminal.viewHeight,
        );
        _outputSubs[id] = output.listen(
          terminal.write,
          onDone: () => _onShellEnded(id),
          onError: (Object _) => _onShellEnded(id),
        );
        terminal.onOutput = engineSession.write;
        terminal.onResize = (w, h, _, _) => engineSession.resizeTerminal(w, h);
      }

      _update(
        id,
        (s) => s.copyWith(
          phase: SessionPhase.ready,
          engineSession: engineSession,
          terminal: terminal,
        ),
      );
    } on DesktopAuthenticationException catch (e) {
      return e;
    } on Object catch (e) {
      final message = e is SshEngineException ? e.message : e.toString();
      if (_find(id)?.kind == SessionKind.portForward) {
        await _forwardFailed(id, message);
      } else {
        _update(
          id,
          (s) => s.copyWith(
            phase: SessionPhase.failed,
            error: message,
            hostKeyFailure: e is HostKeyChangedException ? e.review : null,
          ),
        );
      }
    } finally {
      _connectionCancels.remove(id);
      if (!cancellation.isCompleted) cancellation.complete();
    }
    return null;
  }

  Future<bool> _verifyHostKey(String id, SshHostKey key) async {
    final repository = _knownHosts;
    if (repository == null || _disposed || _find(id) == null) return false;
    final trusted = await repository.find(
      key.hostname,
      key.port,
      protocol: key.protocol,
    );
    if (_disposed || _find(id) == null) return false;
    if (trusted != null &&
        trusted.matches(key) &&
        (!key.isRdp || key.certificateError == null)) {
      _update(id, (s) => s.copyWith(phase: SessionPhase.authenticating));
      return true;
    }

    final review = HostKeyReview(presented: key, trusted: trusted);
    final decision = Completer<bool>();
    _hostKeyDecisions[id] = decision;
    _update(
      id,
      (s) =>
          s.copyWith(phase: SessionPhase.hostKeyPending, hostKeyReview: review),
    );
    bool accepted;
    try {
      accepted = await decision.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => false,
      );
    } finally {
      _hostKeyDecisions.remove(id);
    }
    if (review.hasChanged && !key.isRdp) {
      throw HostKeyChangedException(review, '主机指纹已变更，已拒绝连接；请通过可信渠道核验服务器密钥');
    }
    if (!accepted || _disposed || _find(id) == null) return false;
    if (key.isRdp && (review.hasChanged || key.certificateError != null)) {
      // Explicit exception applies only to this TLS connection, never silently
      // replacing the saved certificate or suppressing future PKI warnings.
      _update(id, (s) => s.copyWith(phase: SessionPhase.authenticating));
      return true;
    }
    // 原子保存：并发首次连接不能覆盖另一条已确认的指纹。
    if (!await repository.trustIfAbsent(key)) {
      if (key.isRdp) return _verifyHostKey(id, key);
      throw HostKeyChangedException(
        HostKeyReview(
          presented: key,
          trusted: await repository.find(
            key.hostname,
            key.port,
            protocol: key.protocol,
          ),
        ),
        '可信主机指纹已发生变化，已拒绝连接',
      );
    }
    if (_disposed || _find(id) == null) return false;
    _update(id, (s) => s.copyWith(phase: SessionPhase.authenticating));
    return true;
  }

  /// RDP 可确认本次证书例外；SSH 已变更密钥始终拒绝。
  void confirmHostKey(String id, {required bool trust}) {
    final decision = _hostKeyDecisions[id];
    final review = _find(id)?.hostKeyReview;
    if (decision == null || decision.isCompleted || review == null) return;
    decision.complete(trust && (review.presented.isRdp || !review.hasChanged));
  }

  /// 远端 shell 结束（exit / 断网）时自动关闭该标签。
  void _onShellEnded(String id) {
    final session = _find(id);
    if (session == null || session.phase != SessionPhase.ready) return;
    unawaited(close(id));
  }

  Future<void> desktopFailed(String id, String message) async {
    final session = _find(id);
    if (session == null ||
        session.kind != SessionKind.remoteDesktop ||
        session.phase != SessionPhase.ready) {
      return;
    }
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.failed,
        error: message,
        loginUsername: s.loginUsername,
      ),
    );
    await _releaseResources(session);
  }

  void activate(String id) {
    if (_find(id) == null) return;
    activeSessionId.value = id;
  }

  /// 按标签 ID 调整顺序，保留最新会话快照和当前激活项。
  /// 拖动期间关闭的标签不再插回，新增的标签保留在末尾。
  void reorder(Iterable<String> ids) {
    final remaining = {for (final session in sessions) session.id: session};
    final reordered = <Session>[];
    for (final id in ids) {
      final session = remaining.remove(id);
      if (session != null) reordered.add(session);
    }
    reordered.addAll(remaining.values);
    sessions.assignAll(reordered);
  }

  Future<void> _forwardFailed(String id, String message) async {
    final session = _find(id);
    if (session == null ||
        !session.phase.isAlive ||
        session.phase == SessionPhase.stopping) {
      return;
    }
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.failed,
        error: message,
        loginUsername: s.loginUsername,
      ),
    );
    await _cleanupForward(session);
  }

  Future<void> stopForward(String id) async {
    final session = _find(id);
    if (session == null ||
        session.kind != SessionKind.portForward ||
        session.phase != SessionPhase.ready) {
      return;
    }
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.stopping,
        loginUsername: s.loginUsername,
      ),
    );
    await _cleanupForward(session);
  }

  Future<void> _cleanupForward(Session session) async {
    final existing = _forwardCleanup[session.id];
    if (existing != null) {
      await existing;
      return;
    }
    final hostId = session.host.id;
    final previous = _forwardHostCleanup[hostId];
    final cleanup = () async {
      if (previous != null) await previous;
      try {
        await _releaseResources(session);
      } finally {
        if (_find(session.id)?.phase == SessionPhase.stopping) {
          _update(session.id, (s) => s.copyWith(phase: SessionPhase.closed));
        }
      }
    }();
    _forwardCleanup[session.id] = cleanup;
    _forwardHostCleanup[hostId] = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_forwardCleanup[session.id], cleanup)) {
        unawaited(_forwardCleanup.remove(session.id));
      }
      if (identical(_forwardHostCleanup[hostId], cleanup)) {
        unawaited(_forwardHostCleanup.remove(hostId));
      }
    }
  }

  /// 该主机的首个同类型会话（按标签顺序），无则返回 null。
  Session? findByHost(
    String hostId, {
    SessionKind kind = SessionKind.terminal,
  }) {
    for (final s in sessions) {
      if (s.host.id == hostId && s.kind == kind) return s;
    }
    return null;
  }

  /// 若该主机已有会话标签则激活之并返回 true；无则返回 false。
  ///
  /// 配合「默认每台主机一个标签」的策略：双击主机走此方法，
  /// 强制新开会话（右键「新建会话」）直接调用 [open]。
  bool focusExisting(String hostId, {SessionKind kind = SessionKind.terminal}) {
    final session = findByHost(hostId, kind: kind);
    if (session == null) return false;
    activate(session.id);
    return true;
  }

  Future<void> close(String id) async {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index == -1) return;
    final session = sessions[index];

    // 先同步移除标签：UI 即时响应，且天然去重——点击 ✕ 与断线自动关闭
    // 并发触发时，后到者查不到会话直接返回。绝不能在 await 之后再用
    // 事先算好的 index 访问列表：挂起期间列表可能已被其他关闭操作改动。
    sessions.removeAt(index);
    if (activeSessionId.value == id) {
      // 关闭当前激活标签时，激活其原先的邻位标签。
      activeSessionId.value = sessions.isEmpty
          ? null
          : sessions[index.clamp(0, sessions.length - 1)].id;
    }
    _credentials.remove(id);
    _gateways.remove(id);
    final cancellation = _connectionCancels.remove(id);
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final decision = _hostKeyDecisions.remove(id);
    if (decision != null && !decision.isCompleted) decision.complete(false);
    final password = _passwordDecisions.remove(id);
    if (password != null && !password.isCompleted) password.complete(null);

    if (session.kind == SessionKind.portForward) {
      await _cleanupForward(session);
    } else {
      await _releaseResources(session);
    }
  }

  Future<void> _releaseResources(Session session) async {
    // 先取消传输，让引擎清理半成品，再断开连接。
    await _transfers?.cancelSession(session.id);
    await _outputSubs.remove(session.id)?.cancel();
    // async* 流可能正等待 native 事件；先发起取消并断开 SSH，
    // native 转发结束后再等待取消完成，避免两边互相等待。
    final forwardCancellation = _forwardSubs.remove(session.id)?.cancel();
    try {
      await session.engineSession?.close();
      await session.desktopSession?.close();
    } on Object catch (_) {
      // 引擎侧可能已自行断开（shell 退出/网络中断），重复关闭报错可忽略。
    }
    if (forwardCancellation != null) await forwardCancellation;
  }

  Future<void> closeActive() async {
    final id = activeSessionId.value;
    if (id != null) await close(id);
  }

  /// 保留并激活指定标签，关闭操作发生时的其他标签。
  Future<void> closeOthers(String id) async {
    if (_find(id) == null) return;
    activate(id);
    final ids = sessions.where((s) => s.id != id).map((s) => s.id).toList();
    await Future.wait(ids.map(close));
  }

  /// 按快照关闭所有标签，沿用单个会话的取消和资源释放流程。
  Future<void> closeAll() async {
    final ids = sessions.map((s) => s.id).toList();
    await Future.wait(ids.map(close));
  }

  @override
  void onClose() {
    _disposed = true;
    for (final cancellation in _connectionCancels.values) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    _connectionCancels.clear();
    for (final decision in _hostKeyDecisions.values) {
      if (!decision.isCompleted) decision.complete(false);
    }
    _hostKeyDecisions.clear();
    for (final decision in _passwordDecisions.values) {
      if (!decision.isCompleted) decision.complete(null);
    }
    _passwordDecisions.clear();
    _credentials.clear();
    _gateways.clear();
    for (final session in sessions.toList()) {
      unawaited(_releaseResources(session));
      if (session.phase == SessionPhase.credentialsPending) {
        _update(session.id, (s) => s.copyWith(phase: SessionPhase.closed));
      }
    }
    super.onClose();
  }

  Session? _find(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _update(String id, Session Function(Session) transform) {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index == -1) return;
    sessions[index] = transform(sessions[index]);
  }
}

class BatchCommandResult {
  const BatchCommandResult({this.sent = 0, this.skipped = 0, this.failed = 0});

  final int sent;
  final int skipped;
  final int failed;
}
