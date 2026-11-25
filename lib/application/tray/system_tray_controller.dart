import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/mcp/mcp_server_transport.dart';
import '../../domain/tray/system_tray.dart';
import '../ai/ai_settings_controller.dart';
import '../mcp/mcp_server_controller.dart';
import '../session/session.dart';
import '../session/session_controller.dart';
import '../settings/settings_controller.dart';

/// 桌面系统托盘状态与右键菜单控制器。
///
/// 汇总端口转发、动态代理、本地 MCP 服务与活动会话状态，驱动托盘提示和上下文菜单，
/// 并将菜单交互分派到对应业务控制器或主窗口壳层回调。
class SystemTrayController extends GetxController {
  SystemTrayController({
    required this._tray,
    required this._settings,
    required this._sessions,
    this._mcp,
    Future<bool> Function(String text)? copyText,
  }) : _copyText = copyText ?? _defaultCopyText;

  static const actionShowWindow = 'window.show';
  static const actionHideWindow = 'window.hide';
  static const actionStopAllForwards = 'forward.stopAll';
  static const actionStopAllProxies = 'proxy.stopAll';
  static const actionToggleMcp = 'mcp.toggle';
  static const actionCopyMcpEndpoint = 'mcp.copyEndpoint';
  static const actionOpenMcpSettings = 'mcp.settings';
  static const actionQuickConnect = 'action.quickConnect';
  static const actionSettings = 'action.settings';
  static const actionToggleMinimizeToTray = 'setting.minimizeToTray';
  static const actionQuit = 'app.quit';
  static const sessionFocusPrefix = 'session.focus:';

  static const _maxListedServiceSessions = 10;
  static const _maxListedInteractiveSessions = 12;

  final SystemTray _tray;
  final SettingsController _settings;
  final SessionController _sessions;
  final McpServerController? _mcp;
  final Future<bool> Function(String text) _copyText;

  final windowHiddenInTray = false.obs;

  Future<void> Function()? onShowWindow;
  Future<void> Function()? onHideWindow;
  Future<void> Function()? onOpenQuickConnect;
  Future<void> Function({bool ai})? onOpenSettings;
  Future<void> Function(String sessionId)? onFocusSession;
  Future<void> Function()? onQuitRequested;
  void Function(String message)? onNoticeSuccess;
  void Function(String message)? onNoticeError;

  final _workers = <Worker>[];
  Future<void> _syncQueue = Future<void>.value();
  bool _syncScheduled = false;
  bool _disposed = false;
  bool _initialized = false;

  @override
  void onInit() {
    super.onInit();
    _tray.setEventHandler(
      onIconActivated: _handleIconActivated,
      onMenuItemSelected: _handleMenuItemSelected,
    );
    final observables = <RxInterface<Object?>>[
      windowHiddenInTray,
      _settings.minimizeToTrayOnClose,
      _settings.savingMinimizeToTrayOnClose,
      _settings.languageCode,
      _settings.isLoaded,
      _sessions.sessions,
      if (_mcp case final mcp?) ...[
        mcp.running,
        mcp.busy,
        mcp.boundPort,
        mcp.activeClients,
        mcp.statusError,
      ],
    ];
    _workers.add(everAll(observables, (_) => refreshMenu()));
    unawaited(_start());
  }

  Future<void> _start() async {
    if (_disposed) return;
    await _tray.initialize();
    if (_disposed) return;
    _initialized = true;
    await _syncNow();
  }

  /// 立即排队刷新托盘提示与菜单（如语言切换完成后调用）。
  void refreshMenu() {
    if (_disposed || _syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (_disposed || !_initialized) return;
      unawaited(_syncNow());
    });
  }

  /// 同步主窗口是否隐藏于后台托盘的状态。
  void setWindowHiddenInTray(bool hidden) {
    if (_disposed) return;
    if (windowHiddenInTray.value != hidden) {
      windowHiddenInTray.value = hidden;
    }
    unawaited(_tray.setBackgroundMode(hidden));
    refreshMenu();
  }

  /// 应用退出前清理原生托盘图标，避免残留无效图标。
  Future<void> disposeTray() async {
    if (_disposed) return;
    _disposed = true;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    await _syncQueue;
    await _tray.setBackgroundMode(false);
    await _tray.dispose();
  }

  @override
  void onClose() {
    unawaited(disposeTray());
    super.onClose();
  }

  Future<void> _syncNow() {
    final task = _syncQueue.then((_) async {
      if (_disposed) return;
      await _tray.update(buildTrayState());
    });
    _syncQueue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  /// 根据当前语言、后台服务及会话状态构建不可变托盘快照。
  SystemTrayState buildTrayState() {
    final allSessions = _sessions.sessions.toList(growable: false);
    final activeForwards = [
      for (final session in allSessions)
        if (session.kind == SessionKind.portForward && session.phase.isAlive)
          session,
    ];
    final activeProxies = [
      for (final session in allSessions)
        if (session.kind == SessionKind.dynamicProxy &&
            (session.phase.isAlive || _sessions.proxyNeedsCleanup(session.id)))
          session,
    ];
    final interactiveSessions = [
      for (final session in allSessions)
        if (!session.kind.usesGatewayEndpoint && session.phase.isAlive) session,
    ];

    final mcp = _mcp;
    final mcpRunning = mcp?.running.value ?? false;
    final mcpBusy = mcp?.busy.value ?? false;
    final mcpClients = mcp?.activeClients.value ?? 0;
    final mcpPort = mcp == null ? 0 : (mcp.boundPort.value ?? mcp.config.port);
    final mcpError = mcp?.statusError.value;

    final tooltipParts = <String>[
      if (activeForwards.isNotEmpty)
        '端口转发 @count'.trParams({'count': '${activeForwards.length}'}),
      if (activeProxies.isNotEmpty)
        '动态代理 @count'.trParams({'count': '${activeProxies.length}'}),
      if (mcpRunning) 'MCP :@port'.trParams({'port': '$mcpPort'}),
      if (interactiveSessions.isNotEmpty)
        '会话 @count'.trParams({'count': '${interactiveSessions.length}'}),
    ];
    final tooltip = tooltipParts.isNotEmpty
        ? 'PagaShell · ${tooltipParts.join(' · ')}'
        : windowHiddenInTray.value
        ? 'PagaShell · @status'.trParams({'status': '后台运行中'.tr})
        : 'PagaShell';

    final items = <SystemTrayMenuItem>[
      if (windowHiddenInTray.value)
        SystemTrayMenuItem.action(
          id: actionShowWindow,
          label: '显示 PagaShell'.tr,
        )
      else
        SystemTrayMenuItem.action(id: actionHideWindow, label: '隐藏到托盘'.tr),
      const SystemTrayMenuItem.separator(),
      _buildForwardMenuItem(activeForwards),
      _buildProxyMenuItem(activeProxies),
      if (mcp != null)
        _buildMcpMenuItem(
          running: mcpRunning,
          busy: mcpBusy,
          clients: mcpClients,
          port: mcpPort,
          hasError: mcpError != null,
        ),
      if (interactiveSessions.isNotEmpty)
        _buildInteractiveSessionsMenuItem(interactiveSessions),
      const SystemTrayMenuItem.separator(),
      SystemTrayMenuItem.action(id: actionQuickConnect, label: '快速连接…'.tr),
      SystemTrayMenuItem.action(id: actionSettings, label: '设置…'.tr),
      SystemTrayMenuItem.checkbox(
        id: actionToggleMinimizeToTray,
        label: '关闭时最小化到托盘'.tr,
        checked: _settings.minimizeToTrayOnClose.value,
        enabled: !_settings.savingMinimizeToTrayOnClose.value,
      ),
      const SystemTrayMenuItem.separator(),
      SystemTrayMenuItem.action(id: actionQuit, label: '退出 PagaShell'.tr),
    ];

    return SystemTrayState(
      tooltip: tooltip,
      items: List.unmodifiable(items),
      hasActiveServices:
          mcpRunning ||
          activeForwards.any((s) => s.phase == SessionPhase.ready) ||
          activeProxies.any((s) => s.phase == SessionPhase.ready),
    );
  }

  SystemTrayMenuItem _buildForwardMenuItem(List<Session> activeForwards) {
    if (activeForwards.isEmpty) {
      return SystemTrayMenuItem.info('端口转发：未运行'.tr);
    }
    final listed = activeForwards.take(_maxListedServiceSessions);
    final overflow = activeForwards.length - _maxListedServiceSessions;
    final canStop = activeForwards.any((s) => s.phase != SessionPhase.stopping);
    return SystemTrayMenuItem.submenu(
      label: '端口转发（@count 运行中）'.trParams({'count': '${activeForwards.length}'}),
      children: [
        for (final session in listed)
          SystemTrayMenuItem.action(
            id: '$sessionFocusPrefix${session.id}',
            label: _formatForwardSessionLabel(session),
          ),
        if (overflow > 0)
          SystemTrayMenuItem.info(
            '还有 @count 项…'.trParams({'count': '$overflow'}),
          ),
        const SystemTrayMenuItem.separator(),
        SystemTrayMenuItem.action(
          id: actionStopAllForwards,
          label: (activeForwards.length == 1 ? '停止此端口转发' : '停止全部端口转发').tr,
          enabled: canStop,
        ),
      ],
    );
  }

  SystemTrayMenuItem _buildProxyMenuItem(List<Session> activeProxies) {
    if (activeProxies.isEmpty) {
      return SystemTrayMenuItem.info('动态代理：未运行'.tr);
    }
    final listed = activeProxies.take(_maxListedServiceSessions);
    final overflow = activeProxies.length - _maxListedServiceSessions;
    final canStop = activeProxies.any((s) => s.phase != SessionPhase.stopping);
    return SystemTrayMenuItem.submenu(
      label: '动态代理（@count 运行中）'.trParams({'count': '${activeProxies.length}'}),
      children: [
        for (final session in listed)
          SystemTrayMenuItem.action(
            id: '$sessionFocusPrefix${session.id}',
            label: _formatProxySessionLabel(session),
          ),
        if (overflow > 0)
          SystemTrayMenuItem.info(
            '还有 @count 项…'.trParams({'count': '$overflow'}),
          ),
        const SystemTrayMenuItem.separator(),
        SystemTrayMenuItem.action(
          id: actionStopAllProxies,
          label: (activeProxies.length == 1 ? '停止此动态代理' : '停止全部动态代理').tr,
          enabled: canStop,
        ),
      ],
    );
  }

  SystemTrayMenuItem _buildMcpMenuItem({
    required bool running,
    required bool busy,
    required int clients,
    required int port,
    required bool hasError,
  }) {
    final header = running
        ? '本地 MCP 服务（运行中 :@port）'.trParams({'port': '$port'})
        : '本地 MCP 服务（已停止）'.tr;
    final statusLine = running
        ? clients > 0
              ? '状态：运行中 · @count 个客户端'.trParams({'count': '$clients'})
              : '状态：运行中（127.0.0.1:@port）'.trParams({'port': '$port'})
        : hasError
        ? '状态：启动失败'.tr
        : '状态：已停止'.tr;
    return SystemTrayMenuItem.submenu(
      label: header,
      children: [
        SystemTrayMenuItem.info(statusLine),
        const SystemTrayMenuItem.separator(),
        SystemTrayMenuItem.action(
          id: actionToggleMcp,
          label:
              (busy
                      ? '正在处理…'
                      : running
                      ? '停止本地 MCP 服务'
                      : '启动本地 MCP 服务')
                  .tr,
          enabled: !busy,
        ),
        SystemTrayMenuItem.action(
          id: actionCopyMcpEndpoint,
          label: '复制 MCP 地址'.tr,
        ),
        SystemTrayMenuItem.action(
          id: actionOpenMcpSettings,
          label: 'MCP 设置…'.tr,
        ),
      ],
    );
  }

  SystemTrayMenuItem _buildInteractiveSessionsMenuItem(List<Session> sessions) {
    final listed = sessions.take(_maxListedInteractiveSessions);
    final overflow = sessions.length - _maxListedInteractiveSessions;
    return SystemTrayMenuItem.submenu(
      label: '活动会话（@count）'.trParams({'count': '${sessions.length}'}),
      children: [
        for (final session in listed)
          SystemTrayMenuItem.action(
            id: '$sessionFocusPrefix${session.id}',
            label: _formatInteractiveSessionLabel(session),
          ),
        if (overflow > 0)
          SystemTrayMenuItem.info(
            '还有 @count 项…'.trParams({'count': '$overflow'}),
          ),
      ],
    );
  }

  String _formatForwardSessionLabel(Session session) {
    final ports = _summarizeForwardPorts(session.host.forwardPorts);
    final status = _phaseTag(session.phase);
    final base = ports == null ? session.title : '${session.title} ($ports)';
    return status == null ? base : '$base · $status';
  }

  String _formatProxySessionLabel(Session session) {
    final details = _summarizeProxyConfig(session.host.proxyConfig);
    final status = _sessions.proxyNeedsCleanup(session.id)
        ? '系统代理待恢复'.tr
        : _phaseTag(session.phase);
    final base = details == null
        ? session.title
        : '${session.title} ($details)';
    return status == null ? base : '$base · $status';
  }

  String _formatInteractiveSessionLabel(Session session) {
    final kind = switch (session.kind) {
      SessionKind.fileTransfer => 'SFTP',
      SessionKind.remoteDesktop => session.host.isVnc ? 'VNC' : 'RDP',
      SessionKind.containerTerminal => 'Docker',
      _ => null,
    };
    final status = _phaseTag(session.phase);
    final base = kind == null ? session.title : '${session.title} ($kind)';
    return status == null ? base : '$base · $status';
  }

  String? _phaseTag(SessionPhase phase) => switch (phase) {
    SessionPhase.ready => null,
    SessionPhase.stopping => '停止中'.tr,
    SessionPhase.reconnecting => '重连中'.tr,
    _ => '连接中'.tr,
  };

  String? _summarizeForwardPorts(List<ForwardPort> ports) {
    if (ports.isEmpty) return null;
    final shown = ports.take(3).map((p) => ':${p.localPort}').join(', ');
    final extra = ports.length - 3;
    return extra > 0 ? '$shown +$extra' : shown;
  }

  String? _summarizeProxyConfig(ProxyConfig config) {
    final parts = <String>[];
    if (config.httpEnabled || config.httpsEnabled) {
      final port = !config.httpEnabled && config.httpsEnabled
          ? config.httpsPort
          : config.httpPort;
      parts.add('HTTP :$port');
    }
    if (config.socks5Enabled) {
      parts.add('SOCKS5 :${config.socks5Port}');
    }
    if (config.autoSystemProxy) {
      parts.add('系统代理'.tr);
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  void _handleIconActivated() {
    if (_disposed) return;
    unawaited(_invokeAsync(() async => onShowWindow?.call()));
  }

  void _handleMenuItemSelected(String itemId) {
    if (_disposed) return;
    unawaited(handleMenuAction(itemId));
  }

  /// 执行菜单动作（公开以便测试直接驱动）。
  Future<void> handleMenuAction(String itemId) async {
    if (_disposed) return;
    if (itemId.startsWith(sessionFocusPrefix)) {
      final sessionId = itemId.substring(sessionFocusPrefix.length);
      if (sessionId.isNotEmpty) {
        await _invokeAsync(() async => onFocusSession?.call(sessionId));
      }
      return;
    }
    switch (itemId) {
      case actionShowWindow:
        await _invokeAsync(() async => onShowWindow?.call());
      case actionHideWindow:
        await _invokeAsync(() async => onHideWindow?.call());
      case actionStopAllForwards:
        await _stopAllForwards();
      case actionStopAllProxies:
        await _stopAllProxies();
      case actionToggleMcp:
        await _toggleMcp();
      case actionCopyMcpEndpoint:
        await _copyMcpEndpoint();
      case actionOpenMcpSettings:
        await _invokeAsync(() async => onOpenSettings?.call(ai: true));
      case actionQuickConnect:
        await _invokeAsync(() async => onOpenQuickConnect?.call());
      case actionSettings:
        await _invokeAsync(() async => onOpenSettings?.call(ai: false));
      case actionToggleMinimizeToTray:
        await _toggleMinimizeToTray();
      case actionQuit:
        await _invokeAsync(() async => onQuitRequested?.call());
    }
  }

  Future<void> _stopAllForwards() async {
    final ids = [
      for (final session in _sessions.sessions)
        if (session.kind == SessionKind.portForward &&
            session.phase.isAlive &&
            session.phase != SessionPhase.stopping)
          session.id,
    ];
    if (ids.isEmpty) return;
    await Future.wait(ids.map(_sessions.stopForward));
  }

  Future<void> _stopAllProxies() async {
    final ids = [
      for (final session in _sessions.sessions)
        if (session.kind == SessionKind.dynamicProxy &&
            session.phase != SessionPhase.stopping &&
            (session.phase.isAlive || _sessions.proxyNeedsCleanup(session.id)))
          session.id,
    ];
    if (ids.isEmpty) return;
    await Future.wait(ids.map(_sessions.stopProxy));
    final failedId = ids.firstWhereOrNull(_sessions.proxyNeedsCleanup);
    if (failedId != null) {
      await _invokeAsync(() async => onFocusSession?.call(failedId));
      onNoticeError?.call('恢复系统代理失败，请重试停止代理');
    }
  }

  Future<void> _toggleMcp() async {
    final mcp = _mcp;
    if (mcp == null || mcp.busy.value) return;
    final enable = !mcp.running.value;
    try {
      await mcp.setEnabled(enable);
      if (!windowHiddenInTray.value) {
        onNoticeSuccess?.call(enable ? '本地 MCP 服务已启动' : '本地 MCP 服务已停止');
      }
    } on McpServerException catch (error) {
      await _invokeAsync(() async => onShowWindow?.call());
      onNoticeError?.call(error.message);
    } on AiSettingsException catch (error) {
      await _invokeAsync(() async => onShowWindow?.call());
      onNoticeError?.call(error.message);
    } on Object {
      await _invokeAsync(() async => onShowWindow?.call());
      onNoticeError?.call('本地 MCP 服务状态切换失败，请重试');
    }
  }

  Future<void> _copyMcpEndpoint() async {
    final mcp = _mcp;
    if (mcp == null) return;
    final copied = await _copyText(mcp.endpointUrl);
    if (copied && !windowHiddenInTray.value) {
      onNoticeSuccess?.call('已复制 MCP 地址');
    } else if (!copied && !windowHiddenInTray.value) {
      onNoticeError?.call('复制失败，请重试');
    }
  }

  Future<void> _toggleMinimizeToTray() async {
    try {
      await _settings.setMinimizeToTrayOnClose(
        !_settings.minimizeToTrayOnClose.value,
      );
    } on Object {
      if (!windowHiddenInTray.value) {
        onNoticeError?.call('保存失败，请重试');
      }
    }
  }

  Future<void> _invokeAsync(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // 防止未捕获的托盘事件异常中断主事件循环。
    }
  }

  static Future<bool> _defaultCopyText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on Object {
      return false;
    }
  }
}
