import 'dart:async';

import 'package:get/get.dart';
import 'package:pagashell/terminal/core.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/proxy/dynamic_proxy_engine.dart';
import '../../domain/proxy/system_proxy.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/repositories/known_host_repository.dart';
import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/host_key.dart';
import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../transfer/transfer_controller.dart';
import 'server_status_connection.dart';
import 'session.dart';
import 'session_layout.dart';

part 'session_runtime.dart';
part 'session_tabs.dart';

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
    this._systemProxy,
  });

  final SshEngine _engine;
  final RdpEngine? _rdpEngine;
  final VncEngine? _vncEngine;
  final SystemProxy? _systemProxy;
  final KnownHostRepository? _knownHosts;
  final TransferController? _transfers;
  bool _disposed = false;

  final RxList<Session> sessions = <Session>[].obs;
  final RxnString activeSessionId = RxnString();
  final _tabState = _SessionTabs();

  List<SessionTab> get tabs => _tabState.list(sessions);
  String? get activeTabId => tabForSession(activeSessionId.value)?.id;

  SessionTab? tabForSession(String? id) =>
      tabs.where((tab) => tab.sessionIds.contains(id)).firstOrNull;

  SessionTab? tabById(String id) =>
      tabs.where((tab) => tab.id == id).firstOrNull;

  bool _canReuseTerminalConnection(String id) =>
      !_disposed &&
      _find(id)?.kind.isInteractiveTerminal == true &&
      _find(id)?.phase == SessionPhase.ready &&
      _runtimes[id]?.credentials != null;

  bool canSplitTerminal(String id) => _canReuseTerminalConnection(id);

  /// 同一页签所有窗格共用一条独立采集连接，选中窗格变化不替换数据源。
  ServerStatusSource? serverStatusSource(String tabId) =>
      _monitoringConnection(tabId, (session) => session is ServerStatusSource);

  ProcessManagerSource? processManagerSource(String tabId) =>
      _monitoringConnection(
        tabId,
        (session) => session is ProcessManagerSource,
      );

  DockerManagerSource? dockerManagerSource(String tabId) =>
      _monitoringConnection(tabId, (session) => session is DockerManagerSource);

  NetworkPortsSource? networkPortsSource(String tabId) =>
      _monitoringConnection(tabId, (session) => session is NetworkPortsSource);

  ServerStatusConnection? _monitoringConnection(
    String tabId,
    bool Function(SshEngineSession?) supports,
  ) {
    if (_disposed) return null;
    final tab = tabById(tabId);
    if (tab == null ||
        _find(tab.sessionIds.first)?.kind != SessionKind.terminal) {
      return null;
    }
    final existing = _serverStatusConnections[tabId];
    if (existing != null) return existing;
    for (final id in tab.sessionIds) {
      if (!_canReuseTerminalConnection(id)) continue;
      final session = _find(id)!;
      if (!supports(session.engineSession)) continue;
      final runtime = _runtimes[id]!;
      final host = session.host;
      final credentials = runtime.credentials!;
      final gateway = runtime.gateway;
      return _serverStatusConnections[tabId] = ServerStatusConnection(
        connect: (cancelled) => _engine.connect(
          host,
          credentials,
          gateway: gateway,
          cancelled: cancelled,
          verifyHostKey: (key) => _verifyStatusHostKey(tabId, key),
        ),
      );
    }
    return null;
  }

  Future<bool> _verifyStatusHostKey(String tabId, SshHostKey key) async {
    final repository = _knownHosts;
    bool cancelled() => _disposed || tabById(tabId) == null;
    if (repository == null || cancelled()) return false;
    final trusted = await repository.find(
      key.hostname,
      key.port,
      protocol: key.protocol,
    );
    if (cancelled()) return false;
    if (trusted == null) return false;
    if (!trusted.matches(key)) {
      throw HostKeyChangedException(
        HostKeyReview(presented: key, trusted: trusted),
        '主机指纹已变更，已拒绝连接；请通过可信渠道核验服务器密钥',
      );
    }
    return true;
  }

  /// 使用当前连接的运行时凭据和网关，为同一主机建立独立 SSH 连接。
  Future<String?> splitTerminal(String id, SessionSplitAxis axis) async {
    if (!canSplitTerminal(id)) return null;
    final session = _find(id)!;
    final runtime = _runtimes[id]!;
    return _openSession(
      session.host,
      runtime.credentials!,
      kind: session.kind,
      gateway: runtime.gateway,
      splitFrom: id,
      splitAxis: axis,
      dockerTarget: session.dockerTarget,
    );
  }

  bool canOpenDockerTerminal(String id) =>
      _find(id)?.kind == SessionKind.terminal &&
      _canReuseTerminalConnection(id) &&
      _find(id)?.engineSession is DockerTerminalSource;

  static final _dockerContainerId = RegExp(r'^[a-fA-F0-9]{12,64}$');

  Future<String?> openDockerTerminal(
    String id,
    DockerResource container,
  ) async {
    if (!canOpenDockerTerminal(id) ||
        container.kind != DockerResourceKind.container ||
        container.fields[DockerField.state] != 'running' ||
        !_dockerContainerId.hasMatch(container.id)) {
      return null;
    }
    final source = _find(id)!;
    final runtime = _runtimes[id]!;
    return _openSession(
      source.host,
      runtime.credentials!,
      kind: SessionKind.containerTerminal,
      gateway: runtime.gateway,
      dockerTarget: DockerTerminalTarget(
        id: container.id,
        name: container.name,
      ),
    );
  }

  bool canOpenFileTransfer(String id) {
    final source = _find(id);
    if (_disposed ||
        source == null ||
        source.kind != SessionKind.terminal ||
        source.dockerTarget != null) {
      return false;
    }
    return findByHost(source.host.id, kind: SessionKind.fileTransfer) != null ||
        _canReuseTerminalConnection(id);
  }

  /// 聚焦同主机已有传输标签，或复用终端的实际登录信息建立独立 SFTP 连接。
  Future<String?> openFileTransfer(String id) async {
    if (!canOpenFileTransfer(id)) return null;
    final source = _find(id)!;
    final existing = findByHost(source.host.id, kind: SessionKind.fileTransfer);
    if (existing != null) {
      activate(existing.id);
      return existing.id;
    }
    final runtime = _runtimes[id]!;
    return _openSession(
      source.host,
      runtime.credentials!,
      kind: SessionKind.fileTransfer,
      gateway: runtime.gateway,
    );
  }

  final Map<String, _SessionRuntime> _runtimes = {};
  final Map<String, ServerStatusConnection> _serverStatusConnections = {};
  // 跨标签共享的网关清理队列；重新启动必须等旧监听端口释放。
  final Map<String, Future<void>> _forwardHostCleanup = {};
  final Map<String, Future<void>> _proxyHostCleanup = {};
  Future<void>? _tabCloseConfirmation;

  bool proxyNeedsCleanup(String id) =>
      _runtimes[id]?.proxyRestoreFailed ?? false;

  int _nextId = 1;

  /// 当前激活的会话（无则为 null）。在 Obx 中访问可响应变化。
  Session? get activeSession {
    final id = activeSessionId.value;
    return id == null ? null : _find(id);
  }

  /// 可接收批量命令的交互终端；SFTP 和转发连接不具有 shell。
  List<Session> get commandSessions => sessions.where(_canSendCommand).toList();

  static bool _canSendCommand(Session session) =>
      session.kind.isInteractiveTerminal &&
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
  }) => _openSession(host, credentials, kind: kind, gateway: gateway);

  Future<String> _openSession(
    Host host,
    SshCredentials credentials, {
    SessionKind kind = SessionKind.terminal,
    SshGateway? gateway,
    String? splitFrom,
    SessionSplitAxis splitAxis = SessionSplitAxis.horizontal,
    DockerTerminalTarget? dockerTarget,
  }) async {
    if (kind == SessionKind.portForward || kind == SessionKind.dynamicProxy) {
      throw ArgumentError('请通过端口转发页签手动启动');
    }
    if (kind == SessionKind.containerTerminal && dockerTarget == null) {
      throw ArgumentError('Container terminal requires a container target');
    }
    if (host.isDesktop) {
      if (kind == SessionKind.fileTransfer) {
        throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
      }
      kind = SessionKind.remoteDesktop;
    }
    final id = 'ssn-${_nextId++}';
    _runtimes[id] = _SessionRuntime();
    final session = Session(
      id: id,
      host: host,
      kind: kind,
      loginUsername: credentials.username ?? host.username,
      dockerTarget: dockerTarget,
    );
    final targetTab = tabForSession(splitFrom);
    if (targetTab != null) {
      _tabState.split(targetTab, splitFrom!, id, splitAxis);
      final index = sessions.indexWhere((item) => item.id == splitFrom);
      sessions.insert(index + 1, session);
    } else {
      sessions.add(session);
    }
    activeSessionId.value = id;
    _runtimes[id]?.credentials = credentials;
    if (gateway != null) _runtimes[id]?.gateway = gateway;

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
    _runtimes[id] = _SessionRuntime();
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

  /// 每次启动都由调用方重新准备网关配置和网关凭据。
  Future<void> startForward(String id, SshGateway gateway) async {
    final host = gateway.host;
    final credentials = gateway.credentials;
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
    _runtimes[id]?.credentials = credentials;
    _runtimes[id]?.gateway = null;
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

  String openProxy(Host host) {
    final existing = findByHost(host.id, kind: SessionKind.dynamicProxy);
    if (existing != null) {
      activate(existing.id);
      return existing.id;
    }
    final id = 'ssn-${_nextId++}';
    _runtimes[id] = _SessionRuntime();
    sessions.add(
      Session(
        id: id,
        host: host,
        kind: SessionKind.dynamicProxy,
        phase: SessionPhase.closed,
      ),
    );
    activeSessionId.value = id;
    return id;
  }

  void updateProxyHost(Host host) {
    final session = findByHost(host.id, kind: SessionKind.dynamicProxy);
    if (session != null && !session.phase.isAlive) {
      _update(session.id, (s) => s.copyWith(host: host));
    }
  }

  Future<void> startProxy(String id, Host host, {SshGateway? gateway}) async {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.kind != SessionKind.dynamicProxy ||
        session.host.id != host.id ||
        session.phase.isAlive) {
      return;
    }
    host.proxyConfig.validate(forStart: true);
    if (gateway?.host.id != host.id) {
      throw const SshEngineException('所选网关不可用');
    }
    _update(id, (s) => Session(id: id, host: host, kind: s.kind));
    final cancellation = Completer<void>();
    final completed = Completer<void>();
    _runtimes[id]?.proxyStarting = completed;
    _runtimes[id]?.connectionCancel = cancellation;
    try {
      await _proxyHostCleanup[host.id];
      if (cancellation.isCompleted ||
          _disposed ||
          _find(id) == null ||
          _find(id)?.phase == SessionPhase.stopping) {
        return;
      }
      final engine = _engine;
      if (engine is! DynamicProxyEngine) {
        throw const SshEngineException('当前引擎不支持动态代理');
      }
      final proxy = await (engine as DynamicProxyEngine).startProxy(
        host.proxyConfig,
        gateway: gateway,
        verifyHostKey: (key) => _verifyHostKey(id, key),
        cancelled: cancellation.future,
      );
      _runtimes[id]?.proxyHandle = proxy;
      Future<void> ended(String message) async {
        if (!identical(_runtimes[id]?.proxyHandle, proxy)) return;
        if (!completed.isCompleted && !cancellation.isCompleted) {
          cancellation.complete();
        }
        await _proxyFailed(id, message);
      }

      unawaited(
        proxy.done.then(
          (_) => ended('动态代理监听已断开'),
          onError: (Object error) =>
              ended(error is SshEngineException ? error.message : '动态代理监听已断开'),
        ),
      );
      if (!cancellation.isCompleted && host.proxyConfig.autoSystemProxy) {
        final systemProxy = _systemProxy;
        if (systemProxy == null) {
          throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
        }
        final lease = systemProxy.createLease(host.proxyConfig);
        _runtimes[id]?.systemProxyLease = lease;
        await lease.enable();
      }
      if (cancellation.isCompleted ||
          _disposed ||
          _find(id) == null ||
          _find(id)?.phase == SessionPhase.stopping) {
        await _releaseProxyResources(id);
        return;
      }
      _update(
        id,
        (s) => s.copyWith(phase: SessionPhase.ready, proxySession: proxy),
      );
    } on Object catch (e) {
      Object failure = e;
      try {
        await _releaseProxyResources(id);
      } on SystemProxyException catch (restoreError) {
        failure = restoreError;
        _runtimes[id]?.proxyRestoreFailed = true;
      }
      final current = _find(id);
      if (((_runtimes[id]?.proxyRestoreFailed ?? false) ||
              !cancellation.isCompleted) &&
          current != null &&
          current.phase != SessionPhase.stopping) {
        _update(
          id,
          (s) => Session(
            id: s.id,
            host: s.host,
            kind: s.kind,
            phase: (_runtimes[id]?.proxyRestoreFailed ?? false)
                ? SessionPhase.ready
                : SessionPhase.failed,
            error: _displayFailure(failure, '动态代理启动失败，请检查网关配置和网络'),
            proxySession: _runtimes[id]?.proxyHandle,
            hostKeyFailure: e is HostKeyChangedException ? e.review : null,
          ),
        );
      }
    } finally {
      _runtimes[id]?.connectionCancel = null;
      if (!cancellation.isCompleted) cancellation.complete();
      _runtimes[id]?.proxyStarting = null;
      completed.complete();
    }
  }

  Future<void> _proxyFailed(String id, String message) async {
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
      ),
    );
    try {
      await _cleanupProxy(session);
    } on SystemProxyException {
      // The cleanup error is shown on the retained proxy tab for retry.
    }
  }

  Future<void> stopProxy(String id) async {
    final session = _find(id);
    if (session == null ||
        session.kind != SessionKind.dynamicProxy ||
        (!session.phase.isAlive &&
            _runtimes[id]?.proxyHandle == null &&
            _runtimes[id]?.systemProxyLease == null)) {
      return;
    }
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.stopping,
      ),
    );
    final cancellation = _runtimes[id]?.connectionCancel;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final decision = _runtimes[id]?.takeHostKeyDecision();
    if (decision != null && !decision.isCompleted) decision.complete(false);
    try {
      await _cleanupProxy(session);
    } on SystemProxyException {
      // Keep the listener and tab available until settings can be restored.
    }
  }

  Future<void> _cleanupProxy(Session session) async {
    final existing = _runtimes[session.id]?.proxyCleanup;
    if (existing != null) return existing;
    final hostId = session.host.id;
    final previous = _proxyHostCleanup[hostId];
    final starting = _runtimes[session.id]?.proxyStarting?.future;
    final cleanup = () async {
      await previous;
      await starting;
      try {
        await _releaseResources(session);
        _runtimes[session.id]?.proxyRestoreFailed = false;
        if (_find(session.id)?.phase == SessionPhase.stopping) {
          _update(
            session.id,
            (s) => Session(
              id: s.id,
              host: s.host,
              kind: s.kind,
              phase: SessionPhase.closed,
            ),
          );
        }
      } on SystemProxyException catch (error) {
        _runtimes[session.id]?.proxyRestoreFailed = true;
        _update(
          session.id,
          (s) => s.copyWith(
            phase: SessionPhase.ready,
            error: error.message,
            proxySession: _runtimes[session.id]?.proxyHandle,
          ),
        );
        rethrow;
      }
    }();
    _runtimes[session.id]?.proxyCleanup = cleanup;
    _proxyHostCleanup[hostId] = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_runtimes[session.id]?.proxyCleanup, cleanup)) {
        _runtimes[session.id]?.proxyCleanup = null;
      }
      if (identical(_proxyHostCleanup[hostId], cleanup)) {
        unawaited(_proxyHostCleanup.remove(hostId));
      }
    }
  }

  Future<void> closeProxyForHost(String hostId) async {
    final ids = sessions
        .where((s) => s.host.id == hostId && s.kind == SessionKind.dynamicProxy)
        .map((s) => s.id)
        .toList();
    await Future.wait(ids.map(close));
    await _proxyHostCleanup[hostId];
    if (sessions.any(
      (s) => s.host.id == hostId && s.kind == SessionKind.dynamicProxy,
    )) {
      throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
    }
  }

  /// 认证失败后先重新输入密码；其他失败沿用当前会话凭据。
  Future<void> retry(String id) async {
    final session = _find(id);
    final credentials = _runtimes[id]?.credentials;
    if (session == null ||
        session.kind == SessionKind.portForward ||
        session.kind == SessionKind.dynamicProxy ||
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
        dockerTarget: s.dockerTarget,
      ),
    );
    await _runtimes[id]?.shellCleanup;
    if (_disposed || _find(id) == null) return;
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
    final credentials = _runtimes[id]?.credentials;
    if (_disposed ||
        session == null ||
        session.kind == SessionKind.portForward ||
        session.kind == SessionKind.dynamicProxy ||
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
        dockerTarget: s.dockerTarget,
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
        _runtimes[id]?.credentials ?? credentials,
      );
      final session = _find(id);
      if (failure == null || _disposed || session == null) return;
      final login = _runtimes[id]?.credentials;
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
    _runtimes[id]?.passwordDecision = decision;
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
      if (identical(_runtimes[id]?.passwordDecision, decision)) {
        _runtimes[id]?.passwordDecision = null;
      }
    }
    if (_disposed || _find(id) == null) return false;
    if (password == null) {
      _update(id, (s) => s.copyWith(phase: SessionPhase.failed));
      return false;
    }
    _runtimes[id]?.credentials = SshCredentials.password(
      password,
      username: _runtimes[id]?.credentials?.username,
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
    final decision = _runtimes[id]?.passwordDecision;
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
    _runtimes[id]?.connectionCancel = cancellation;
    try {
      final session = _find(id);
      final cleanup = session?.kind == SessionKind.portForward
          ? _forwardHostCleanup[host.id]
          : null;
      if (cleanup != null) {
        await cleanup;
        if (_disposed || _find(id) == null) return null;
      }
      if (host.gatewayId != null &&
          _runtimes[id]?.gateway?.host.id != host.gatewayId) {
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
          gateway: _runtimes[id]?.gateway,
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
      if (_find(id)!.kind == SessionKind.portForward) {
        final engine = _engine;
        if (engine is! GatewayForwardEngine) {
          throw const SshEngineException('当前引擎不支持端口转发');
        }
        final forwarder = await (engine as GatewayForwardEngine).connectForward(
          SshGateway(host: host, credentials: credentials),
          verifyHostKey: (key) => _verifyHostKey(id, key),
          cancelled: cancellation.future,
        );
        if (_disposed || _find(id) == null) {
          await forwarder.close();
          return null;
        }
        _update(id, (s) => s.copyWith(forwardSession: forwarder));
        _runtimes[id]?.forwardSubscription = forwarder
            .startPortForwards(host.forwardPorts)
            .listen(
              (event) {
                if (event.kind == 'ready') {
                  _update(id, (s) => s.copyWith(phase: SessionPhase.ready));
                } else if (event.kind == 'connectionError') {
                  _update(
                    id,
                    (s) => s.copyWith(
                      error:
                          '本地端口 ${event.localPort} 的目标连接失败，请检查目标地址、端口和网关转发权限',
                    ),
                  );
                } else if (event.kind == 'closed') {
                  unawaited(_forwardFailed(id, '端口转发已断开'));
                }
              },
              onError: (Object e) =>
                  unawaited(_forwardFailed(id, _displayFailure(e, '端口转发已断开'))),
              onDone: () => unawaited(_forwardFailed(id, '端口转发已断开')),
            );
        return null;
      }

      final engineSession = await _engine.connect(
        host,
        credentials,
        verifyHostKey: (key) => _verifyHostKey(id, key),
        cancelled: cancellation.future,
        gateway: _runtimes[id]?.gateway,
      );
      // 会话可能在 connect 期间被用户关闭。
      if (_disposed || _find(id) == null) {
        await engineSession.close();
        return null;
      }

      // 文件传输标签持有独立连接，不启动 shell，也不依赖终端退出事件。
      Terminal? terminal;
      if (_find(id)!.kind.isInteractiveTerminal) {
        if (engineSession is! TerminalScreenSource) {
          await engineSession.close();
          throw SshEngineException('终端引擎不支持屏幕帧'.tr);
        }
        final display = Terminal();
        terminal = display;
        final source = engineSession as TerminalScreenSource;
        final dockerTarget = _find(id)!.dockerTarget;
        if (dockerTarget != null && engineSession is! DockerTerminalSource) {
          display.dispose();
          await engineSession.close();
          throw const SshEngineException('此连接不支持容器终端');
        }
        display.onOutput = engineSession.write;
        display.onResize = (w, h, _, _) => engineSession.resizeTerminal(w, h);
        _update(
          id,
          (s) => s.copyWith(
            phase: SessionPhase.ready,
            engineSession: engineSession,
            terminal: display,
          ),
        );
        bool canApplyFrame() =>
            !_disposed &&
            !display.isDisposed &&
            identical(_find(id)?.terminal, display);
        void shellEnded() {
          if (identical(_find(id)?.terminal, display)) _onShellEnded(id);
        }

        final frames = dockerTarget == null
            ? source.startTerminalShell(
                cols: display.viewWidth,
                rows: display.viewHeight,
              )
            : (engineSession as DockerTerminalSource).startDockerTerminalShell(
                target: dockerTarget,
                cols: display.viewWidth,
                rows: display.viewHeight,
              );
        _runtimes[id]?.outputSubscription = frames
            .asyncMap((frame) async {
              if (!canApplyFrame()) return frame;
              display.applyFrame(frame);
              // applyFrame 完成（含同步监听器）后确认；关闭中的显示不再放行。
              if (canApplyFrame()) {
                await source.acknowledgeTerminalFrame(frame.frameId);
              }
              return frame;
            })
            .listen(
              (_) {},
              onDone: shellEnded,
              onError: (Object error) {
                if (dockerTarget == null) {
                  shellEnded();
                } else {
                  _onDockerShellFailed(id, display, error);
                }
              },
            );
      }

      if (terminal == null) {
        _update(
          id,
          (s) => s.copyWith(
            phase: SessionPhase.ready,
            engineSession: engineSession,
          ),
        );
      }
    } on DesktopAuthenticationException catch (e) {
      return e;
    } on Object catch (e) {
      final message = _displayFailure(e, '连接失败，请检查连接配置和网络后重试');
      if (_find(id)?.kind == SessionKind.portForward) {
        await _forwardFailed(id, message);
      } else if (_find(id) case final session?
          when session.dockerTarget != null && session.terminal != null) {
        _onDockerShellFailed(id, session.terminal!, e);
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
      _runtimes[id]?.connectionCancel = null;
      if (!cancellation.isCompleted) cancellation.complete();
    }
    return null;
  }

  Future<bool> _verifyHostKey(String id, SshHostKey key) async {
    final repository = _knownHosts;
    bool cancelled() =>
        _disposed ||
        _find(id) == null ||
        _find(id)?.phase == SessionPhase.stopping;
    if (repository == null || cancelled()) return false;
    final trusted = await repository.find(
      key.hostname,
      key.port,
      protocol: key.protocol,
    );
    if (cancelled()) return false;
    if (trusted != null &&
        trusted.matches(key) &&
        (!key.isRdp || key.certificateError == null)) {
      _update(id, (s) => s.copyWith(phase: SessionPhase.authenticating));
      return true;
    }

    final review = HostKeyReview(presented: key, trusted: trusted);
    final decision = Completer<bool>();
    _runtimes[id]?.hostKeyDecision = decision;
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
      _runtimes[id]?.hostKeyDecision = null;
    }
    if (review.hasChanged && !key.isRdp) {
      throw HostKeyChangedException(review, '主机指纹已变更，已拒绝连接；请通过可信渠道核验服务器密钥');
    }
    if (!accepted || cancelled()) return false;
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
    if (cancelled()) return false;
    _update(id, (s) => s.copyWith(phase: SessionPhase.authenticating));
    return true;
  }

  /// RDP 可确认本次证书例外；SSH 已变更密钥始终拒绝。
  void confirmHostKey(String id, {required bool trust}) {
    final decision = _runtimes[id]?.hostKeyDecision;
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

  void _onDockerShellFailed(String id, Terminal terminal, Object error) {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.phase == SessionPhase.failed ||
        !identical(session.terminal, terminal)) {
      return;
    }
    _update(
      id,
      (current) => current.copyWith(
        phase: SessionPhase.failed,
        error: _displayFailure(error, '无法打开容器终端，请重试'),
      ),
    );
    final cleanup = _releaseResources(session).catchError((Object _) {});
    _runtimes[id]?.shellCleanup = cleanup;
    unawaited(
      cleanup.whenComplete(() {
        if (identical(_runtimes[id]?.shellCleanup, cleanup)) {
          _runtimes[id]?.shellCleanup = null;
        }
      }),
    );
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
    _tabState.activate(id);
    activeSessionId.value = id;
  }

  void activateTab(String id) {
    final tab = tabById(id);
    if (tab != null) activate(tab.selectedSessionId);
  }

  /// 按标签 ID 调整顺序，保留最新会话快照和当前激活项。
  /// 拖动期间关闭的标签不再插回，新增的标签保留在末尾。
  void reorder(Iterable<String> ids) {
    final remaining = {for (final session in sessions) session.id: session};
    final reordered = <Session>[];
    final currentTabs = {for (final tab in tabs) tab.id: tab};
    for (final id in ids) {
      for (final sessionId in currentTabs[id]?.sessionIds ?? [id]) {
        final session = remaining.remove(sessionId);
        if (session != null) reordered.add(session);
      }
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
    final existing = _runtimes[session.id]?.forwardCleanup;
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
    _runtimes[session.id]?.forwardCleanup = cleanup;
    _forwardHostCleanup[hostId] = cleanup;
    try {
      await cleanup;
    } finally {
      if (identical(_runtimes[session.id]?.forwardCleanup, cleanup)) {
        _runtimes[session.id]?.forwardCleanup = null;
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
      if (s.host.id == hostId && s.kind == kind) {
        return s;
      }
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
    activateTab(tabForSession(session.id)!.id);
    return true;
  }

  /// 用户关闭标签前确认运行中的转发和代理；批量操作取消时保留所有标签。
  Future<void> requestTabClose(
    Iterable<String> sessionIds, {
    required Future<bool> Function(List<Session> running) confirm,
    String? keepSessionId,
  }) {
    final pending = <Future<void>>{};
    final ids = <String>{};
    final kept = keepSessionId == null
        ? <String>{}
        : (tabById(keepSessionId) ?? tabForSession(keepSessionId))?.sessionIds
                  .toSet() ??
              {keepSessionId};
    final expandedIds = <String>{
      for (final id in sessionIds)
        ...(tabById(id) ?? tabForSession(id))?.sessionIds ?? [id],
    };
    for (final id in expandedIds) {
      if (kept.contains(id)) continue;
      final existing = _runtimes[id]?.tabCloseRequest;
      if (existing != null) {
        pending.add(existing);
      } else {
        ids.add(id);
      }
    }
    if (ids.isNotEmpty) {
      // 确认框逐个展示；连接清理只阻止同一标签的重复请求。
      final previousConfirmation = _tabCloseConfirmation;
      final confirmationDone = Completer<void>();
      _tabCloseConfirmation = confirmationDone.future;
      late final Future<void> request;
      request =
          (() async {
            try {
              if (previousConfirmation != null) await previousConfirmation;
              if (keepSessionId != null &&
                  !sessions.any((s) => kept.contains(s.id))) {
                return;
              }
              final running = sessions
                  .where(
                    (s) => ids.contains(s.id) && _needsTabCloseConfirmation(s),
                  )
                  .toList(growable: false);
              if (running.isNotEmpty && !await confirm(running)) return;
              if (keepSessionId != null) {
                final keptTab =
                    tabById(keepSessionId) ?? tabForSession(keepSessionId);
                if (keptTab == null) return;
                activate(keptTab.selectedSessionId);
              }
            } finally {
              confirmationDone.complete();
              if (identical(_tabCloseConfirmation, confirmationDone.future)) {
                _tabCloseConfirmation = null;
              }
            }
            await Future.wait(ids.map(close));
          })().whenComplete(() {
            for (final id in ids) {
              if (identical(_runtimes[id]?.tabCloseRequest, request)) {
                _runtimes[id]?.tabCloseRequest = null;
                _forgetClosedRuntime(id);
              }
            }
          });
      for (final id in ids) {
        _runtimes[id]?.tabCloseRequest = request;
      }
      pending.add(request);
    }
    if (pending.length == 1) return pending.single;
    return Future.wait(pending).then((_) {});
  }

  bool _needsTabCloseConfirmation(Session session) => switch (session.kind) {
    SessionKind.portForward =>
      session.phase.isAlive || _runtimes[session.id]?.forwardCleanup != null,
    SessionKind.dynamicProxy =>
      session.phase.isAlive ||
          _runtimes[session.id]?.proxyHandle != null ||
          _runtimes[session.id]?.systemProxyLease != null ||
          _runtimes[session.id]?.proxyStarting != null ||
          _runtimes[session.id]?.proxyCleanup != null,
    _ => false,
  };

  Future<void> close(String id) async {
    final current = _find(id);
    if (current?.kind == SessionKind.dynamicProxy &&
        (current!.host.proxyConfig.autoSystemProxy ||
            _runtimes[id]?.systemProxyLease != null)) {
      await stopProxy(id);
      if (_runtimes[id]?.proxyHandle != null ||
          _runtimes[id]?.systemProxyLease != null) {
        return;
      }
    }
    final index = sessions.indexWhere((s) => s.id == id);
    if (index == -1) return;
    final session = sessions[index];
    final tab = tabForSession(id)!;
    final tabIndex = tabs.indexWhere((item) => item.id == tab.id);

    // 先同步移除标签：UI 即时响应，且天然去重——点击 ✕ 与断线自动关闭
    // 并发触发时，后到者查不到会话直接返回。绝不能在 await 之后再用
    // 事先算好的 index 访问列表：挂起期间列表可能已被其他关闭操作改动。
    _tabState.remove(id);
    sessions.removeAt(index);
    if (activeSessionId.value == id) {
      final remaining = tabs;
      final sameTab = tabById(tab.id);
      activeSessionId.value =
          sameTab?.selectedSessionId ??
          (remaining.isEmpty
              ? null
              : remaining[tabIndex.clamp(0, remaining.length - 1)]
                    .selectedSessionId);
    }
    _runtimes[id]?.cancelPending();
    final statusClose = tabById(tab.id) == null
        ? _serverStatusConnections.remove(tab.id)?.close()
        : null;

    try {
      if (session.kind == SessionKind.portForward) {
        await _cleanupForward(session);
      } else if (session.kind == SessionKind.dynamicProxy) {
        await _cleanupProxy(session);
      } else {
        await _releaseResources(session);
        // 标签已关闭，其传输记录不会再显示；连接失败重连时保留，因此只在这里清理。
        _transfers?.clearFinished(sessionId: id);
      }
    } finally {
      await statusClose;
      _forgetClosedRuntime(id);
    }
  }

  void _forgetClosedRuntime(String id) {
    final runtime = _runtimes[id];
    if (_find(id) == null &&
        runtime?.tabCloseRequest == null &&
        runtime?.systemProxyLease == null) {
      _runtimes.remove(id);
    }
  }

  Future<void> _releaseResources(Session session) async {
    final shellCleanup = _runtimes[session.id]?.shellCleanup;
    if (shellCleanup != null) {
      await shellCleanup;
      return;
    }
    if (session.kind == SessionKind.dynamicProxy) {
      await _releaseProxyResources(session.id);
    }
    // 先取消传输，让引擎清理半成品，再断开连接。
    await _transfers?.cancelSession(session.id);
    // 原生输出或 async* 转发流可能需要断开连接后才结束；先发起取消，
    // 同时断开连接，再一起等待，避免取消与断开互相等待。
    final outputCancellation = _runtimes[session.id]
        ?.cancelOutputSubscription();
    final terminal = session.terminal;
    terminal?.dispose();
    final forwardCancellation = _runtimes[session.id]
        ?.cancelForwardSubscription();
    await Future.wait([
      ?outputCancellation,
      ?forwardCancellation,
      () async {
        try {
          await session.forwardSession?.close();
          await session.engineSession?.close();
          await session.desktopSession?.close();
        } on Object catch (_) {
          // 引擎侧可能已自行断开（shell 退出/网络中断），重复关闭报错可忽略。
        }
      }(),
    ]);
  }

  Future<void> _releaseProxyResources(String id) async {
    // Restore first: a failed restore must not leave the system pointing at a dead listener.
    await _runtimes[id]?.systemProxyLease?.restore();
    _runtimes[id]?.systemProxyLease = null;
    _runtimes[id]?.proxyRestoreFailed = false;
    final proxy = _runtimes[id]?.proxyHandle;
    if (proxy != null) {
      try {
        await proxy.close();
      } on Object {
        // An unexpectedly terminated listener can already be closed.
      }
      if (identical(_runtimes[id]?.proxyHandle, proxy)) {
        _runtimes[id]?.proxyHandle = null;
      }
    }
  }

  Future<void> closeActive() async {
    final id = activeSessionId.value;
    if (id == null) return;
    final ids = tabForSession(id)?.sessionIds.toList() ?? [id];
    await Future.wait(ids.map(close));
  }

  /// 保留并激活指定标签，关闭操作发生时的其他标签。
  Future<void> closeOthers(String id) async {
    final tab = tabById(id) ?? tabForSession(id);
    if (tab == null) return;
    activate(tab.selectedSessionId);
    final kept = tab.sessionIds.toSet();
    final ids = sessions
        .where((s) => !kept.contains(s.id))
        .map((s) => s.id)
        .toList();
    await Future.wait(ids.map(close));
  }

  /// 按快照关闭所有标签，沿用单个会话的取消和资源释放流程。
  Future<void> closeAll() async {
    final ids = sessions.map((s) => s.id).toList();
    await Future.wait(ids.map(close));
    if (_runtimes.values.any((runtime) => runtime.systemProxyLease != null)) {
      throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
    }
  }

  @override
  void onClose() {
    _disposed = true;
    for (final connection in _serverStatusConnections.values) {
      unawaited(connection.close());
    }
    _serverStatusConnections.clear();
    for (final runtime in _runtimes.values) {
      runtime.cancelPending();
    }
    for (final session in sessions.toList()) {
      unawaited(
        _releaseResources(session).catchError((Object _) {}).whenComplete(() {
          _runtimes.remove(session.id);
        }),
      );
      if (session.phase == SessionPhase.credentialsPending) {
        _update(session.id, (s) => s.copyWith(phase: SessionPhase.closed));
      }
    }
    super.onClose();
  }

  static String _displayFailure(Object error, String fallback) =>
      switch (error) {
        SshEngineException(:final message) => message,
        SystemProxyException(:final message) => message,
        _ => fallback,
      };

  Session? _find(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _update(String id, Session Function(Session) transform) {
    final index = sessions.indexWhere((s) => s.id == id);
    if (index == -1) return;
    final current = sessions[index];
    final next = transform(current);
    // 内容不变时不写回：RxList 的下标赋值总会通知全部监听者，
    // 端口转发错误等高频事件会让所有标签与工作区跟着重建。
    if (_sameSnapshot(current, next)) return;
    sessions[index] = next;
  }

  /// [Session.==] 不比较引擎句柄与终端，这里额外按实例比较它们。
  static bool _sameSnapshot(Session a, Session b) =>
      identical(a, b) ||
      (a == b &&
          identical(a.engineSession, b.engineSession) &&
          identical(a.forwardSession, b.forwardSession) &&
          identical(a.proxySession, b.proxySession) &&
          identical(a.desktopSession, b.desktopSession) &&
          identical(a.terminal, b.terminal));
}

class BatchCommandResult {
  const BatchCommandResult({this.sent = 0, this.skipped = 0, this.failed = 0});

  final int sent;
  final int skipped;
  final int failed;
}
