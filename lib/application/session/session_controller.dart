import 'dart:async';

import 'package:get/get.dart';
import 'package:pagashell/terminal/core.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/dynamic_proxy_engine.dart';
import '../../domain/proxy/system_proxy.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/repositories/known_host_repository.dart';
import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/firewall.dart';
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

enum TerminalInsertResult {
  inserted,
  unavailable,
  requiresBracketedPaste,
  invalidText,
}

enum SessionCloseStep {
  systemProxy,
  dynamicProxy,
  portForward,
  fileTransfer,
  connection,
}

typedef HostSessionActivity = ({
  bool active,
  int count,
  bool ready,
  bool connecting,
});

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
    this._shouldCloseTerminalOnDisconnect,
  }) {
    _sessionsChanged = sessions.listen((snapshot) {
      _tabState.updateSessions(snapshot);
      _updateHostActivity(snapshot, activeSessionId.value);
    });
    _activeChanged = activeSessionId.listen((id) {
      _updateHostActivity(sessions(), id);
    });
  }

  final SshEngine _engine;
  final RdpEngine? _rdpEngine;
  final VncEngine? _vncEngine;
  final SystemProxy? _systemProxy;
  final KnownHostRepository? _knownHosts;
  final TransferController? _transfers;
  final bool Function()? _shouldCloseTerminalOnDisconnect;
  bool _disposed = false;

  final RxList<Session> sessions = <Session>[].obs;
  final RxnString activeSessionId = RxnString();
  final RxList<String> recentHostIds = <String>[].obs;
  final _tabState = _SessionTabs();
  final _inputSync = Rxn<({String tabId, Map<String, Terminal> targets})>();
  late final StreamSubscription<List<Session>> _sessionsChanged;
  late final StreamSubscription<String?> _activeChanged;
  Map<(String, bool), HostSessionActivity> _hostActivity = {};
  static const _noHostActivity = (
    active: false,
    count: 0,
    ready: false,
    connecting: false,
  );

  static Object hostActivityUpdateId(String hostId, {required bool gateway}) =>
      ('session-host-activity', hostId, gateway);

  HostSessionActivity hostActivity(String hostId, {required bool gateway}) =>
      _hostActivity[(hostId, gateway)] ?? _noHostActivity;

  void _updateHostActivity(List<Session> snapshot, String? active) {
    final next = <(String, bool), HostSessionActivity>{};
    for (final session in snapshot) {
      final key = (
        session.host.id,
        session.kind == SessionKind.portForward ||
            session.kind == SessionKind.dynamicProxy,
      );
      final included =
          session.kind != SessionKind.containerTerminal &&
          session.phase != SessionPhase.closed;
      final previous = next[key] ?? _noHostActivity;
      if (!included && session.id != active) continue;
      next[key] = (
        active: previous.active || session.id == active,
        count: previous.count + (included ? 1 : 0),
        ready:
            previous.ready || (included && session.phase == SessionPhase.ready),
        connecting: previous.connecting || (included && session.phase.isBusy),
      );
    }
    final previous = _hostActivity;
    _hostActivity = next;
    final changed = [
      for (final (hostId, gateway) in {...previous.keys, ...next.keys})
        if (previous[(hostId, gateway)] != next[(hostId, gateway)])
          hostActivityUpdateId(hostId, gateway: gateway),
    ];
    if (changed.isNotEmpty) update(changed);
  }

  void _recordRecentHost(String hostId) {
    recentHostIds.remove(hostId);
    recentHostIds.insert(0, hostId);
    if (recentHostIds.length > 20) {
      recentHostIds.removeRange(20, recentHostIds.length);
    }
  }

  List<SessionTab> get tabs => _tabState.list();
  String? get activeTabId => tabForSession(activeSessionId.value)?.id;

  SessionTab? tabForSession(String? id) => _tabState.forSession(id);

  SessionTab? tabById(String id) => _tabState.byId(id);

  bool _canReuseTerminalConnection(String id) =>
      !_disposed &&
      _find(id)?.kind.isInteractiveTerminal == true &&
      _find(id)?.phase == SessionPhase.ready &&
      _runtimes[id]?.credentials != null;

  bool canSplitTerminal(String id) => _canReuseTerminalConnection(id);

  /// 同页签的同主机窗格共用采集连接。混排时随当前主机切换数据源。
  ServerStatusSource? serverStatusSource(String tabId, {String? hostId}) =>
      _monitoringConnection(
        tabId,
        hostId,
        (session) => session is ServerStatusSource,
      );

  ProcessManagerSource? processManagerSource(String tabId, {String? hostId}) =>
      _monitoringConnection(
        tabId,
        hostId,
        (session) => session is ProcessManagerSource,
      );

  DockerManagerSource? dockerManagerSource(String tabId, {String? hostId}) =>
      _monitoringConnection(
        tabId,
        hostId,
        (session) => session is DockerManagerSource,
      );

  NetworkPortsSource? networkPortsSource(String tabId, {String? hostId}) =>
      _monitoringConnection(
        tabId,
        hostId,
        (session) => session is NetworkPortsSource,
      );

  FirewallSource? firewallSource(String tabId, {String? hostId}) =>
      _monitoringConnection(
        tabId,
        hostId,
        (session) => session is FirewallSource,
      );

  ServerStatusConnection? _monitoringConnection(
    String tabId,
    String? hostId,
    bool Function(SshEngineSession?) supports,
  ) {
    if (_disposed) return null;
    final tab = tabById(tabId);
    if (tab == null) return null;
    final target = hostId ?? _find(tab.selectedSessionId)?.host.id;
    if (target == null) return null;
    final key = (tabId, target);
    final existing = _serverStatusConnections[key];
    Session? source;
    for (final id in tab.sessionIds) {
      if (!_canReuseTerminalConnection(id)) continue;
      final session = _find(id)!;
      if (session.host.id != target || session.kind != SessionKind.terminal) {
        continue;
      }
      if (!supports(session.engineSession)) continue;
      source = session;
      if (id == tab.selectedSessionId) break;
    }
    if (source == null) return null;
    if (existing != null) return existing;
    final runtime = _runtimes[source.id]!;
    final host = source.host;
    final credentials = runtime.credentials!;
    final gateway = runtime.gateway;
    return _serverStatusConnections[key] = ServerStatusConnection(
      connect: (cancelled) => _engine.connect(
        host,
        credentials,
        gateway: gateway,
        cancelled: cancelled,
        verifyHostKey: (key) => _verifyStatusHostKey(tabId, key),
      ),
    );
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
  Future<String?> splitTerminal(
    String id,
    SessionSplitAxis axis, {
    bool before = false,
  }) async {
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
      splitBefore: before,
      dockerTarget: session.dockerTarget,
      temporary: runtime.temporary,
    );
  }

  bool canSplitToHost(String id, Host host) {
    final current = _find(id);
    return current?.kind == SessionKind.terminal &&
        !host.isDesktop &&
        canSplitTerminal(id);
  }

  Future<String?> splitToHost(
    String id,
    Host host,
    SshCredentials credentials, {
    required SessionSplitEdge edge,
    SshGateway? gateway,
    bool temporary = false,
  }) async {
    if (!canSplitToHost(id, host)) return null;
    return _openSession(
      host,
      credentials,
      gateway: gateway,
      splitFrom: id,
      splitAxis: edge.axis,
      splitBefore: edge.before,
      temporary: temporary,
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
      temporary: runtime.temporary,
    );
  }

  final Map<String, _SessionRuntime> _runtimes = {};
  final _pendingCloses = <String, _PendingSessionClose>{};

  Set<SessionCloseStep> get pendingCloseSteps => {
    for (final close in _pendingCloses.values) close.step,
    if (_runtimes.values.any((runtime) => runtime.systemProxyLease != null))
      SessionCloseStep.systemProxy,
  };

  String? get systemProxyRestoreError => sessions
      .firstWhereOrNull((session) => proxyNeedsCleanup(session.id))
      ?.error;
  final Map<(String, String), ServerStatusConnection> _serverStatusConnections =
      {};
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

  static bool _canSendCommand(Session session) =>
      session.kind.isInteractiveTerminal &&
      session.phase == SessionPhase.ready &&
      session.engineSession != null &&
      session.terminal?.onOutput != null;

  Terminal? _commandTerminal(String id) {
    if (_disposed) return null;
    final session = _find(id);
    return session != null && _canSendCommand(session)
        ? session.terminal
        : null;
  }

  bool canSendCommandToSession(String id) => _commandTerminal(id) != null;

  bool isInputSyncEnabled(String tabId) => _inputSync.value?.tabId == tabId;

  Map<String, Terminal>? _inputTargets(String tabId) {
    if (_disposed || activeTabId != tabId) return null;
    final tab = tabById(tabId);
    if (tab == null || tab.layout is! SessionSplit) return null;
    final targets = <String, Terminal>{};
    for (final id in tab.sessionIds) {
      final pane = _find(id);
      if (pane == null || !_canSendCommand(pane)) return null;
      targets[id] = pane.terminal!;
    }
    return targets;
  }

  bool canSyncInput(String tabId) => _inputTargets(tabId) != null;

  void toggleInputSync(String tabId) {
    if (isInputSyncEnabled(tabId)) {
      _inputSync.value = null;
      return;
    }
    final targets = _inputTargets(tabId);
    if (targets != null) _inputSync.value = (tabId: tabId, targets: targets);
  }

  void stopInputSync(String tabId) {
    if (isInputSyncEnabled(tabId)) _inputSync.value = null;
  }

  List<String> inputSyncPaneNames(String sourceId) {
    final sync = _inputSync.value;
    if (sync == null || activeSessionId.value != sourceId) return const [];
    final live = _inputTargets(sync.tabId);
    if (live == null || !_matchesInputTargets(sync.targets, live)) {
      return const [];
    }
    return [for (final id in live.keys) _find(id)!.title];
  }

  bool _matchesInputTargets(
    Map<String, Terminal> expected,
    Map<String, Terminal> live,
  ) =>
      expected.length == live.length &&
      live.entries.every(
        (entry) => identical(entry.value, expected[entry.key]),
      );

  /// Only keyboard, IME and accepted paste from the selected view use this path.
  /// Re-encode keys and bracketed paste for each terminal's own input modes.
  void syncUserInput(String sourceId, void Function(Terminal) send) {
    final sync = _inputSync.value;
    if (sync == null || activeSessionId.value != sourceId) return;
    final live = _inputTargets(sync.tabId);
    if (live == null || !_matchesInputTargets(sync.targets, live)) {
      _inputSync.value = null;
      return;
    }
    for (final entry in live.entries) {
      if (entry.key == sourceId) continue;
      try {
        send(entry.value);
      } on Object {
        _inputSync.value = null;
        return;
      }
    }
  }

  void _selectSession(String? id) {
    final sync = _inputSync.value;
    if (sync != null && !sync.targets.containsKey(id)) _inputSync.value = null;
    activeSessionId.value = id;
  }

  /// 只将输入排入指定终端，不代表远端命令已执行成功。
  bool sendCommandToSession(String id, String command) {
    final terminal = _commandTerminal(id);
    if (terminal == null || command.trim().isEmpty) return false;
    final text = command.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 一次写入包含粘贴和最终回车，避免异步通道拆包导致回车先到达。
    final input = terminal.bracketedPasteMode
        ? '\x1b[200~$text\x1b[201~\r'
        : '${text.replaceAll('\n', '\r')}${text.endsWith('\n') ? '' : '\r'}';
    try {
      terminal.textInput(input);
      return true;
    } on Object {
      return false;
    }
  }

  /// 去除末尾换行；仅在远端启用括号粘贴时填入带内部换行的文本。
  TerminalInsertResult insertTextToSession(String sessionId, String text) {
    final terminal = _commandTerminal(sessionId);
    if (terminal == null) return TerminalInsertResult.unavailable;
    final cleaned = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst(RegExp(r'\n+$'), '');
    // 拒绝擦除、提交或提前退出括号粘贴的控制字符。
    if (cleaned.trim().isEmpty ||
        RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]').hasMatch(cleaned)) {
      return TerminalInsertResult.invalidText;
    }
    if (cleaned.contains('\n') && !terminal.bracketedPasteMode) {
      return TerminalInsertResult.requiresBracketedPaste;
    }
    try {
      terminal.paste(cleaned);
      return TerminalInsertResult.inserted;
    } on Object {
      return TerminalInsertResult.unavailable;
    }
  }

  /// 为 [host] 打开一个新会话标签并发起连接。返回会话 id。
  Future<String> open(
    Host host,
    SshCredentials credentials, {
    SessionKind kind = SessionKind.terminal,
    SshGateway? gateway,
    bool temporary = false,
    bool requireTrustedHostKey = false,
  }) => _openSession(
    host,
    credentials,
    kind: kind,
    gateway: gateway,
    temporary: temporary,
    requireTrustedHostKey: requireTrustedHostKey,
  );

  /// 复制仍有会话凭据的连接，在独立标签中建立新的连接。
  Future<String?> duplicateSession(String id) async {
    final session = _find(id);
    final runtime = _runtimes[id];
    final credentials = runtime?.credentials;
    if (_disposed ||
        session == null ||
        (session.kind != SessionKind.terminal &&
            session.kind != SessionKind.remoteDesktop) ||
        (session.phase != SessionPhase.ready &&
            session.phase != SessionPhase.closed) ||
        credentials == null) {
      return null;
    }
    return open(
      session.host,
      credentials,
      kind: session.kind,
      gateway: runtime?.gateway,
      temporary: runtime?.temporary ?? false,
    );
  }

  bool isTemporarySession(String id) => _runtimes[id]?.temporary ?? false;

  Future<String> _openSession(
    Host host,
    SshCredentials credentials, {
    SessionKind kind = SessionKind.terminal,
    SshGateway? gateway,
    String? splitFrom,
    SessionSplitAxis splitAxis = SessionSplitAxis.horizontal,
    bool splitBefore = false,
    DockerTerminalTarget? dockerTarget,
    bool temporary = false,
    bool requireTrustedHostKey = false,
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
    _runtimes[id] = _SessionRuntime(
      temporary: temporary,
      requireTrustedHostKey: requireTrustedHostKey,
    );
    final session = Session(
      id: id,
      host: host,
      kind: kind,
      loginUsername: credentials.username ?? host.username,
      dockerTarget: dockerTarget,
    );
    final targetTab = tabForSession(splitFrom);
    if (targetTab != null) {
      _tabState.split(
        targetTab,
        splitFrom!,
        id,
        splitAxis,
        before: splitBefore,
      );
      final index = sessions.indexWhere((item) => item.id == splitFrom);
      sessions.insert(splitBefore ? index : index + 1, session);
    } else {
      sessions.add(session);
    }
    if (!temporary && kind != SessionKind.containerTerminal) {
      _recordRecentHost(host.id);
    }
    _selectSession(id);
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
    _selectSession(id);
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
    final runtime = _runtimes[id]!;
    final starting = runtime.forwardStarting = Completer<void>();
    runtime.credentials = credentials;
    runtime.gateway = null;
    runtime.forwardErrorPort = null;
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: host,
        kind: s.kind,
        loginUsername: credentials.username ?? host.username,
      ),
    );
    try {
      await _connect(id, host, credentials);
    } finally {
      runtime.forwardStarting = null;
      starting.complete();
    }
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
    _selectSession(id);
    return id;
  }

  void updateProxyHost(Host host, {bool allowReady = false}) {
    final session = findByHost(host.id, kind: SessionKind.dynamicProxy);
    if (session != null &&
        (!session.phase.isAlive ||
            (allowReady && session.phase == SessionPhase.ready))) {
      _update(session.id, (s) => s.copyWith(host: host));
    }
  }

  bool canHotReloadProxy(String id) {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.kind != SessionKind.dynamicProxy ||
        session.phase != SessionPhase.ready ||
        proxyNeedsCleanup(id)) {
      return false;
    }
    final handle = _runtimes[id]?.proxyHandle ?? session.proxySession;
    return handle is DynamicProxyHotReload;
  }

  /// 热更新运行中动态代理的模式与规则，不触碰本地监听端口和系统代理。
  Future<void> applyLiveProxyRouting(String id, ProxyConfig config) async {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.kind != SessionKind.dynamicProxy ||
        session.phase != SessionPhase.ready ||
        proxyNeedsCleanup(id)) {
      throw StateError('请先停止动态代理再编辑配置');
    }
    final handle = _runtimes[id]?.proxyHandle ?? session.proxySession;
    if (handle case final DynamicProxyHotReload reloader) {
      await reloader.updateRouting(config);
      return;
    }
    throw StateError('请先停止动态代理再编辑配置');
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

  bool canRetry(String id) {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        session.kind == SessionKind.portForward ||
        session.kind == SessionKind.dynamicProxy ||
        _runtimes[id]?.credentials == null) {
      return false;
    }
    if (session.kind == SessionKind.fileTransfer &&
        session.engineSession != null) {
      return !session.phase.isBusy;
    }
    return session.phase == SessionPhase.failed ||
        session.phase == SessionPhase.closed;
  }

  bool canReconnect(String id) {
    if (canRetry(id)) return true;
    final session = _find(id);
    return !_disposed &&
        session != null &&
        session.phase == SessionPhase.ready &&
        (session.kind.isInteractiveTerminal ||
            session.kind == SessionKind.remoteDesktop) &&
        _runtimes[id]?.credentials != null;
  }

  /// 认证失败后先重新输入密码；其他失败或已断开会话沿用当前会话凭据。
  Future<void> retry(String id) => _reconnect(id, allowReady: false);

  /// 在原标签和窗格中重新连接，允许用户主动替换仍存活的连接。
  Future<void> reconnect(String id) => _reconnect(id, allowReady: true);

  /// 用重新准备的凭据重试失败的服务。协议改变导致视图不兼容时另开标签。
  Future<void> retryWithLogin(
    String id,
    Host host,
    SshCredentials credentials, {
    SshGateway? gateway,
  }) async {
    final session = _find(id);
    if (session == null ||
        session.host.id != host.id ||
        !canRetry(id) ||
        session.kind == SessionKind.containerTerminal ||
        isTemporarySession(id)) {
      return;
    }
    if (session.kind == SessionKind.fileTransfer && host.isDesktop) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    if (host.isDesktop != (session.kind == SessionKind.remoteDesktop)) {
      await close(id);
      if (!_disposed) await open(host, credentials, gateway: gateway);
      return;
    }
    final runtime = _runtimes[id]!;
    runtime.credentials = credentials;
    runtime.gateway = gateway;
    await _reconnect(id, allowReady: false, updatedHost: host);
  }

  Future<void> _reconnect(
    String id, {
    required bool allowReady,
    Host? updatedHost,
  }) async {
    if (!(allowReady ? canReconnect(id) : canRetry(id))) return;
    final session = _find(id);
    if (session?.kind == SessionKind.fileTransfer &&
        session?.engineSession != null) {
      try {
        await _startFileTransferReconnect(id, updatedHost: updatedHost);
      } on SshEngineException {
        // 失败状态已写入会话，继续使用既有失败界面。
      }
      return;
    }
    final credentials = _runtimes[id]?.credentials;
    if (session == null || credentials == null) return;
    final host = updatedHost ?? session.host;
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: host,
        kind: s.kind,
        loginUsername: updatedHost == null
            ? s.loginUsername
            : credentials.username ?? host.username,
        dockerTarget: s.dockerTarget,
      ),
    );
    if (session.phase == SessionPhase.closed ||
        session.phase == SessionPhase.ready) {
      await _releaseResources(session);
    } else {
      await _runtimes[id]?.shellCleanup;
    }
    if (_disposed || _find(id) == null) return;
    await _connect(
      id,
      host,
      credentials,
      passwordRequest: updatedHost == null ? session.passwordRequest : null,
    );
  }

  /// 文件传输独立重连：同一标签的重复请求共用一次连接尝试。
  Future<SshEngineSession> reconnectFileTransfer(String id) =>
      _startFileTransferReconnect(id);

  Future<SshEngineSession> _startFileTransferReconnect(
    String id, {
    Host? updatedHost,
  }) {
    final runtime = _runtimes[id];
    if (runtime?.fileTransferReconnect case final pending?) return pending;
    final session = _find(id);
    final credentials = runtime?.credentials;
    if (_disposed ||
        session == null ||
        session.kind != SessionKind.fileTransfer ||
        session.engineSession == null ||
        session.phase.isBusy ||
        credentials == null) {
      return Future.error(const SshEngineException('无法重新连接，请关闭文件传输标签后重试'));
    }
    final pending = _reconnectFileTransfer(
      session,
      updatedHost ?? session.host,
      credentials,
    );
    runtime!.fileTransferReconnect = pending;
    void clear() {
      if (identical(runtime.fileTransferReconnect, pending)) {
        runtime.fileTransferReconnect = null;
      }
    }

    unawaited(pending.then((_) => clear(), onError: (Object _) => clear()));
    return pending;
  }

  Future<SshEngineSession> _reconnectFileTransfer(
    Session previous,
    Host host,
    SshCredentials credentials,
  ) async {
    final id = previous.id;
    _update(
      id,
      (s) => s.copyWith(
        host: host,
        loginUsername: credentials.username ?? host.username,
        phase: SessionPhase.reconnecting,
      ),
    );
    try {
      await _transfers?.interruptSession(id);
      try {
        await previous.engineSession!.close();
      } on Object {
        // 旧连接已经失效，仍继续通过正常认证流程建立新连接。
      }
      if (_disposed || _find(id) == null) {
        throw const SshEngineException('文件传输标签已关闭');
      }
      await _connect(id, host, credentials);
      final current = _find(id);
      if (current != null &&
          current.phase == SessionPhase.ready &&
          current.engineSession != null) {
        return current.engineSession!;
      }
      throw SshEngineException(current?.error ?? '重新连接失败，请刷新重试');
    } on Object catch (e) {
      final failure = e is SshEngineException
          ? e
          : const SshEngineException('重新连接失败，请刷新重试');
      if (!_disposed) {
        _update(
          id,
          (s) => s.copyWith(phase: SessionPhase.failed, error: failure.message),
        );
      }
      throw failure;
    }
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

  /// 仅清除失败网关转发或动态代理会话涉及的旧 SSH 指纹；调用方随后按最新配置重新启动。
  Future<bool> clearGatewayHostKey(String id) async {
    final session = _find(id);
    final review = session?.hostKeyFailure;
    final trusted = review?.trusted;
    final repository = _knownHosts;
    if (_disposed ||
        session == null ||
        !session.kind.usesGatewayEndpoint ||
        session.phase != SessionPhase.failed ||
        review == null ||
        !review.hasChanged ||
        review.presented.isRdp ||
        trusted == null ||
        repository == null) {
      return false;
    }
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
      return false;
    }
    if (_disposed || _find(id) == null) return false;
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.closed,
        loginUsername: s.loginUsername,
      ),
    );
    return true;
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
        domain: login.rdpDomain ?? host.rdpDomain,
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
      rdpDomain: _runtimes[id]?.credentials?.rdpDomain,
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
        if (_disposed || _find(id) == null || cancellation.isCompleted) {
          return null;
        }
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
          verifyHostKey: (key) => _verifyHostKey(
            id,
            key,
            connectionCancelled: () => cancellation.isCompleted,
          ),
          cancelled: cancellation.future,
        );
        if (_disposed || _find(id) == null || cancellation.isCompleted) {
          await forwarder.close();
          return null;
        }
        final enabledPorts = [
          for (final port in host.forwardPorts)
            if (port.enabled) port,
        ];
        if (enabledPorts.isEmpty) {
          throw const SshEngineException('请至少启用一组端口映射');
        }
        _update(id, (s) => s.copyWith(forwardSession: forwarder));
        _runtimes[id]?.forwardSubscription = forwarder
            .startPortForwards(enabledPorts)
            .listen(
              (event) {
                if (!identical(_find(id)?.forwardSession, forwarder)) return;
                if (event.kind == 'ready') {
                  _runtimes[id]?.forwardErrorPort = null;
                  _update(
                    id,
                    (s) =>
                        s.copyWith(phase: SessionPhase.ready, clearError: true),
                  );
                } else if (event.kind == 'connectionRecovered') {
                  if (_runtimes[id]?.forwardErrorPort == event.localPort) {
                    _runtimes[id]?.forwardErrorPort = null;
                    _update(id, (s) => s.copyWith(clearError: true));
                  }
                } else if (event.kind == 'connectionError') {
                  _runtimes[id]?.forwardErrorPort = event.localPort;
                  final detail = event.message?.trim();
                  _update(
                    id,
                    (s) => s.copyWith(
                      error: detail != null && detail.isNotEmpty
                          ? '本地端口 ${event.localPort} 的目标连接失败：$detail'
                          : '本地端口 ${event.localPort} 的目标连接失败，请检查目标地址、端口和网关转发权限',
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
        if (_find(id)?.kind == SessionKind.fileTransfer) {
          _transfers?.bindSession(id, engineSession);
        }
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
        await _forwardFailed(
          id,
          message,
          hostKeyFailure: e is HostKeyChangedException ? e.review : null,
        );
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

  Future<bool> _verifyHostKey(
    String id,
    SshHostKey key, {
    bool Function()? connectionCancelled,
  }) async {
    final repository = _knownHosts;
    bool cancelled() =>
        _disposed ||
        connectionCancelled?.call() == true ||
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
    if (_runtimes[id]?.requireTrustedHostKey == true) {
      if (trusted != null) {
        throw HostKeyChangedException(
          HostKeyReview(presented: key, trusted: trusted),
          '主机指纹已变更，已拒绝连接；请通过可信渠道核验服务器密钥',
        );
      }
      throw const SshEngineException('主机指纹尚未信任，请先在 PagaShell 中手动连接并确认主机指纹');
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
      if (identical(_runtimes[id]?.hostKeyDecision, decision)) {
        _runtimes[id]?.hostKeyDecision = null;
      }
    }
    if (cancelled()) return false;
    if (review.hasChanged && !key.isRdp) {
      throw HostKeyChangedException(review, '主机指纹已变更，已拒绝连接；请通过可信渠道核验服务器密钥');
    }
    if (!accepted) return false;
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

  /// SSH 输出结束后，按设置关闭窗格或保留历史供查看和重连。
  void _onShellEnded(String id) {
    final session = _find(id);
    if (_disposed || session == null || session.phase != SessionPhase.ready) {
      return;
    }
    if (session.kind == SessionKind.containerTerminal ||
        _shouldCloseTerminalOnDisconnect?.call() == true) {
      unawaited(close(id));
      return;
    }
    final terminal = session.terminal;
    terminal?.onOutput = null;
    terminal?.onResize = null;
    _releaseEndedShell(session, keepTerminal: true);
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        loginUsername: s.loginUsername,
        terminal: terminal,
        phase: SessionPhase.closed,
      ),
    );
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
    _releaseEndedShell(session);
  }

  void _releaseEndedShell(Session session, {bool keepTerminal = false}) {
    final id = session.id;
    final cleanup = _releaseResources(
      session,
      keepTerminal: keepTerminal,
    ).catchError((Object _) {});
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
    _selectSession(id);
  }

  void activateTab(String id) {
    final tab = tabById(id);
    if (tab != null) activate(tab.selectedSessionId);
  }

  /// 把现有窗格移到原标签右侧的独立标签，沿用会话和运行时连接。
  void movePaneToNewTab(String id) {
    final session = _find(id);
    if (_disposed ||
        session == null ||
        !session.kind.isInteractiveTerminal ||
        _runtimes[id]?.tabCloseRequest != null) {
      return;
    }
    final currentTabs = tabs;
    final index = currentTabs.indexWhere((tab) => tab.sessionIds.contains(id));
    if (index < 0) return;
    final source = currentTabs[index];
    if (source.layout is! SessionSplit) return;
    stopInputSync(source.id);
    final newId = _tabState.detach(source, id);
    reorder(
      currentTabs.map((tab) => tab.id).toList()..insert(index + 1, newId),
    );
    _selectSession(id);
    unawaited(_closeUnusedMonitoring(source.id, session.host.id));
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

  Future<void> _forwardFailed(
    String id,
    String message, {
    HostKeyReview? hostKeyFailure,
  }) async {
    final session = _find(id);
    if (session == null ||
        !session.phase.isAlive ||
        session.phase == SessionPhase.stopping) {
      return;
    }
    _runtimes[id]?.forwardErrorPort = null;
    _update(
      id,
      (s) => Session(
        id: s.id,
        host: s.host,
        kind: s.kind,
        phase: SessionPhase.failed,
        error: message,
        loginUsername: s.loginUsername,
        hostKeyFailure: hostKeyFailure,
      ),
    );
    await _cleanupForward(session);
  }

  Future<void> stopForward(String id) async {
    final session = _find(id);
    if (session == null ||
        session.kind != SessionKind.portForward ||
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
        phase: SessionPhase.stopping,
        loginUsername: s.loginUsername,
      ),
    );
    final runtime = _runtimes[id];
    runtime?.cancelPending();
    await _cleanupForward(
      session,
      waitForStart: runtime?.forwardStarting?.future,
    );
  }

  Future<void> _cleanupForward(
    Session session, {
    Future<void>? waitForStart,
  }) async {
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
        await waitForStart;
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

  Future<void> close(String id) {
    final session = _find(id);
    if (session == null) return Future<void>.value();
    if (_pendingCloses[id] case final pending?) return pending.result.future;
    final pending = _PendingSessionClose(switch (session.kind) {
      SessionKind.dynamicProxy =>
        _runtimes[id]?.systemProxyLease != null
            ? SessionCloseStep.systemProxy
            : SessionCloseStep.dynamicProxy,
      SessionKind.portForward => SessionCloseStep.portForward,
      SessionKind.fileTransfer => SessionCloseStep.fileTransfer,
      _ => SessionCloseStep.connection,
    });
    _pendingCloses[id] = pending;
    pending.result.complete(
      _close(id).whenComplete(() {
        _pendingCloses.remove(id);
      }),
    );
    return pending.result.future;
  }

  void _markCloseStep(String id, SessionCloseStep step) {
    if (_pendingCloses[id] case final pending?) pending.step = step;
  }

  Future<void> _close(String id) async {
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

    // 先同步移除标签：并发关闭时，后到者查不到会话直接返回。
    // 绝不能在 await 之后再用
    // 事先算好的 index 访问列表：挂起期间列表可能已被其他关闭操作改动。
    if (_inputSync.value?.targets.containsKey(id) == true) {
      _inputSync.value = null;
    }
    _tabState.remove(id);
    sessions.removeAt(index);
    if (activeSessionId.value == id) {
      final remaining = tabs;
      final sameTab = tabById(tab.id);
      _selectSession(
        sameTab?.selectedSessionId ??
            (remaining.isEmpty
                ? null
                : remaining[tabIndex.clamp(0, remaining.length - 1)]
                      .selectedSessionId),
      );
    }
    _runtimes[id]?.cancelPending();
    final statusClose = _closeUnusedMonitoring(tab.id, session.host.id);

    try {
      if (session.kind == SessionKind.portForward) {
        await _cleanupForward(
          session,
          waitForStart: _runtimes[id]?.forwardStarting?.future,
        );
      } else if (session.kind == SessionKind.dynamicProxy) {
        await _cleanupProxy(session);
      } else {
        await _releaseResources(session);
        // 标签已关闭，其传输记录不会再显示；连接失败重连时保留，因此只在这里清理。
        _transfers?.clearFinished(sessionId: id);
      }
    } finally {
      if (statusClose != null) _markCloseStep(id, SessionCloseStep.connection);
      await statusClose;
      _forgetClosedRuntime(id);
    }
  }

  Future<void>? _closeUnusedMonitoring(String tabId, String hostId) {
    final stillMonitored = tabById(tabId)?.sessionIds
        .any((id) => _find(id)?.host.id == hostId);
    return stillMonitored == true
        ? null
        : _serverStatusConnections.remove((tabId, hostId))?.close();
  }

  void _forgetClosedRuntime(String id) {
    final runtime = _runtimes[id];
    if (_find(id) == null &&
        runtime?.tabCloseRequest == null &&
        runtime?.systemProxyLease == null) {
      _runtimes.remove(id);
    }
  }

  Future<void> _releaseResources(
    Session session, {
    bool keepTerminal = false,
  }) async {
    final terminal = session.terminal;
    if (!keepTerminal) terminal?.dispose();
    final shellCleanup = _runtimes[session.id]?.shellCleanup;
    if (shellCleanup != null) {
      await shellCleanup;
      return;
    }
    if (session.kind == SessionKind.dynamicProxy) {
      await _releaseProxyResources(session.id);
    }
    // 先停止传输并释放文件句柄，再断开连接；保留目标端已写入文件。
    if (_transfers case final transfers?) {
      _markCloseStep(session.id, SessionCloseStep.fileTransfer);
      await transfers.cancelSession(session.id);
    }
    _markCloseStep(session.id, SessionCloseStep.connection);
    // 原生输出或 async* 转发流可能需要断开连接后才结束；先发起取消，
    // 同时断开连接，再一起等待，避免取消与断开互相等待。
    final outputCancellation = _runtimes[session.id]
        ?.cancelOutputSubscription();
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
    if (_runtimes[id]?.systemProxyLease case final lease?) {
      _markCloseStep(id, SessionCloseStep.systemProxy);
      await lease.restore();
    }
    _runtimes[id]?.systemProxyLease = null;
    _runtimes[id]?.proxyRestoreFailed = false;
    _markCloseStep(id, SessionCloseStep.dynamicProxy);
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
    final ids = sessions.map((session) => session.id).toList();
    await Future.wait(ids.map(close));
    if (_runtimes.values.any((runtime) => runtime.systemProxyLease != null)) {
      throw SystemProxyException(systemProxyRestoreError ?? '恢复系统代理失败，请重试停止代理');
    }
  }

  /// 退出时也等待已移除页签的清理，包括取消上一次退出后仍在进行的任务。
  Future<void> closeForExit() async {
    await Future.wait([
      for (final pending in _pendingCloses.values) pending.result.future,
      closeAll(),
    ]);
  }

  @override
  void onClose() {
    _disposed = true;
    unawaited(_sessionsChanged.cancel());
    unawaited(_activeChanged.cancel());
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
    final syncedTerminal = _inputSync.value?.targets[id];
    if (syncedTerminal != null &&
        (!_canSendCommand(next) || !identical(syncedTerminal, next.terminal))) {
      _inputSync.value = null;
    }
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
