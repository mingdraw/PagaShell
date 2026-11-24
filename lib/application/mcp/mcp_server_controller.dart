import 'dart:async';

import 'package:get/get.dart';

import '../../domain/mcp/mcp_models.dart';
import '../../domain/mcp/mcp_server_transport.dart';
import '../../domain/repositories/known_host_repository.dart';
import '../ai/ai_settings_controller.dart';
import '../gateways/gateway_controller.dart';
import '../hosts/host_controller.dart';
import '../identities/identity_controller.dart';
import '../session/session_controller.dart';
import 'mcp_tool_executor.dart';

/// 本地 MCP 服务生命周期与状态控制器。
///
/// 负责按 `AiSettings.mcp` 自动启停回环监听、串行处理端口/权限/令牌变更，
/// 并在运行内存中维护最近 50 条脱敏调用审计日志。
class McpServerController extends GetxController {
  McpServerController({
    required this._aiSettings,
    required SessionController sessions,
    required HostController hosts,
    required GatewayController gateways,
    required IdentityController identities,
    required this._serverFactory,
    KnownHostRepository? knownHosts,
    this.autoStart = true,
  }) {
    _executor = McpToolExecutor(
      sessions: sessions,
      hosts: hosts,
      gateways: gateways,
      identities: identities,
      knownHosts: knownHosts,
      accessMode: () => _aiSettings.state.value.mcp.accessMode,
      onAudit: _recordAudit,
    );
  }

  static const maxAuditEntries = 50;

  final AiSettingsController _aiSettings;
  final McpServerFactory _serverFactory;
  final bool autoStart;
  late final McpToolExecutor _executor;

  final running = false.obs;
  final busy = false.obs;
  final boundPort = RxnInt();
  final statusError = RxnString();
  final activeClients = 0.obs;
  final token = RxnString();
  final auditLogs = <McpAuditEntry>[].obs;

  McpServerHandle? _handle;
  StreamSubscription<int>? _clientCountSubscription;
  Future<void> _pending = Future<void>.value();
  late final Future<void> ready = _initialize();

  McpServerConfig get config => _aiSettings.state.value.mcp;

  String get endpointUrl =>
      'http://${McpServerConfig.loopbackHost}:${boundPort.value ?? config.port}${McpServerConfig.mcpPath}';

  @override
  void onInit() {
    super.onInit();
    unawaited(ready);
  }

  @override
  void onClose() {
    token.value = null;
    final closing = _clientCountSubscription?.cancel();
    _clientCountSubscription = null;
    if (closing != null) unawaited(closing);
    unawaited(_shutdownHandle());
    super.onClose();
  }

  Future<void> _initialize() async {
    await _aiSettings.ready;
    if (isClosed || _aiSettings.loadFailed.value) return;
    try {
      final savedToken = await _aiSettings.readMcpToken();
      if (!isClosed && savedToken != null) {
        token.value = savedToken;
      }
    } on Object {
      // 启动阶段凭据存储尚未就绪时不阻塞界面初始化。
    }
    if (autoStart && config.enabled && !isClosed) {
      try {
        await _queue(() => _startServerLocked(config.port));
      } on Object {
        // 启动失败时保留 statusError 供设置页展示。
      }
    }
  }

  Future<T> _queue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _pending = _pending.then((_) async {
      if (isClosed) {
        completer.completeError(const McpServerException('MCP 服务控制器已关闭'));
        return;
      }
      busy.value = true;
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } on Object catch (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      } finally {
        if (!isClosed) busy.value = false;
      }
    });
    return completer.future;
  }

  Future<void> setEnabled(bool enabled) => _queue(() async {
    await _aiSettings.ready;
    if (enabled) {
      statusError.value = null;
      await _startServerLocked(config.port);
      try {
        await _aiSettings.saveMcpConfig(enabled: true);
      } on Object {
        await _shutdownHandle();
        rethrow;
      }
    } else {
      statusError.value = null;
      await _shutdownHandle();
      await _aiSettings.saveMcpConfig(enabled: false);
    }
  });

  Future<void> updatePort(int port) => _queue(() async {
    await _aiSettings.ready;
    if (port < McpServerConfig.minPort || port > McpServerConfig.maxPort) {
      throw const McpServerException('请输入 1024–65535 之间的有效端口号');
    }
    if (port == config.port && (!config.enabled || running.value)) return;
    statusError.value = null;
    if (running.value) {
      // 先绑定新端口再关闭旧端口，失败时保持原监听不受影响。
      final previousHandle = _handle;
      final previousSub = _clientCountSubscription;
      final activeToken = await _ensureTokenLocked();
      try {
        final nextHandle = await _serverFactory.start(
          port: port,
          token: activeToken,
          delegate: _executor,
        );
        _bindHandle(nextHandle);
        await previousSub?.cancel();
        await previousHandle?.close();
      } on McpServerException catch (error) {
        statusError.value = error.message;
        rethrow;
      }
    }
    await _aiSettings.saveMcpConfig(port: port);
  });

  Future<void> setAccessMode(McpAccessMode mode) => _queue(() async {
    await _aiSettings.ready;
    if (config.accessMode == mode) return;
    await _aiSettings.saveMcpConfig(accessMode: mode);
    _handle?.notifyToolsListChanged();
  });

  /// 确保已存在有效令牌并返回明文（仅用于界面复制与启动鉴权，不写入普通存储或日志）。
  Future<String> ensureToken() => _queue(_ensureTokenLocked);

  /// 立即轮换 Bearer 令牌，旧令牌即刻失效，无需重启监听。
  Future<String> rotateToken() => _queue(() async {
    await _aiSettings.ready;
    final nextToken = await _aiSettings.ensureMcpToken(rotate: true);
    if (!isClosed) token.value = nextToken;
    _handle?.updateToken(nextToken);
    return nextToken;
  });

  void clearAuditLogs() {
    auditLogs.clear();
  }

  /// 应用退出前停止本地 MCP 监听并释放端口。
  Future<void> stopForExit() => _queue(() async {
    await _shutdownHandle();
    if (!isClosed) token.value = null;
  });

  Future<String> _ensureTokenLocked() async {
    final ensured = await _aiSettings.ensureMcpToken();
    if (!isClosed) token.value = ensured;
    return ensured;
  }

  Future<void> _startServerLocked(int port) async {
    if (_handle != null && _handle!.port == port && running.value) return;
    final activeToken = await _ensureTokenLocked();
    await _shutdownHandle();
    try {
      final handle = await _serverFactory.start(
        port: port,
        token: activeToken,
        delegate: _executor,
      );
      _bindHandle(handle);
      statusError.value = null;
    } on McpServerException catch (error) {
      statusError.value = error.message;
      rethrow;
    } on Object {
      const failure = McpServerException('无法启动本地 MCP 服务，请检查端口设置后重试');
      statusError.value = failure.message;
      throw failure;
    }
  }

  void _bindHandle(McpServerHandle handle) {
    _handle = handle;
    running.value = true;
    boundPort.value = handle.port;
    activeClients.value = handle.activeSessionCount;
    _clientCountSubscription = handle.activeSessionCountStream.listen((count) {
      if (!isClosed) activeClients.value = count;
    });
  }

  Future<void> _shutdownHandle() async {
    final handle = _handle;
    final sub = _clientCountSubscription;
    _handle = null;
    _clientCountSubscription = null;
    if (!isClosed) {
      running.value = false;
      boundPort.value = null;
      activeClients.value = 0;
    }
    await sub?.cancel();
    await handle?.close();
  }

  void _recordAudit(McpAuditEntry entry) {
    if (isClosed) return;
    auditLogs.insert(0, entry);
    if (auditLogs.length > maxAuditEntries) {
      auditLogs.removeRange(maxAuditEntries, auditLogs.length);
    }
  }
}
