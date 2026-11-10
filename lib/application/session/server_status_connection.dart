import 'dart:async';

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 页签独占的采集连接：首次采样时连接，不启动交互 shell，失败后重新连接。
class ServerStatusConnection
    implements
        ServerStatusSource,
        ProcessManagerSource,
        NetworkPortsSource,
        DockerManagerSource,
        DockerContainerActions,
        DockerImageActions,
        DockerComposeActions {
  ServerStatusConnection({
    required Future<SshEngineSession> Function(Future<void> cancelled)
    this._connect,
    this.dockerTimeout = dockerQueryTimeout,
    this.networkPortsTimeout = networkPortsQueryTimeout,
  });

  Future<SshEngineSession> Function(Future<void> cancelled)? _connect;
  final Duration dockerTimeout;
  final Duration networkPortsTimeout;
  SshEngineSession? _session;
  Future<SshEngineSession>? _connecting;
  Completer<void>? _cancellation;
  Future<void>? _closing;
  bool _closed = false;
  int _generation = 0;

  Future<SshEngineSession> _getSession() async {
    if (_closed) throw const SshEngineException('连接已取消');
    final session = _session;
    if (session != null) return session;
    final pending = _connecting ??= _open();
    try {
      return await pending;
    } finally {
      if (identical(_connecting, pending)) _connecting = null;
    }
  }

  Future<SshEngineSession> _open() async {
    final generation = _generation;
    final cancellation = Completer<void>();
    _cancellation = cancellation;
    try {
      final session = await _connect!(cancellation.future);
      // 关闭不等待握手结束；即使引擎迟到返回，句柄也必须在这里释放。
      if (_closed || generation != _generation) {
        await _closeSession(session);
        throw const SshEngineException('连接已取消');
      }
      _session = session;
      return session;
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (!cancellation.isCompleted) cancellation.complete();
    }
  }

  @override
  Future<ServerStatusSample> readServerStatus() async {
    final session = await _getSession();
    if (_closed) throw const SshEngineException('连接已取消');
    try {
      if (session is! ServerStatusSource) {
        throw const SshEngineException('此连接不支持服务状态采集');
      }
      return await (session as ServerStatusSource).readServerStatus();
    } on Object {
      if (identical(_session, session)) {
        await _resetConnection(_generation);
      }
      rethrow;
    }
  }

  @override
  Future<ProcessSnapshot> readProcesses() async {
    final session = await _getSession();
    if (_closed) throw const SshEngineException('连接已取消');
    try {
      if (session is! ProcessManagerSource) {
        throw const SshEngineException('此连接不支持进程管理');
      }
      return await (session as ProcessManagerSource).readProcesses();
    } on Object {
      if (identical(_session, session)) {
        await _resetConnection(_generation);
      }
      rethrow;
    }
  }

  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() {
    final generation = _generation;
    final request = () async {
      try {
        final session = await _getSession();
        if (_closed || generation != _generation) {
          throw const SshEngineException('网络端口连接已关闭');
        }
        if (session is! NetworkPortsSource) {
          throw const SshEngineException('此连接不支持网络端口查询');
        }
        final result = await (session as NetworkPortsSource).readNetworkPorts();
        if (_closed || generation != _generation) {
          throw const SshEngineException('网络端口连接已关闭');
        }
        return result;
      } on TimeoutException {
        unawaited(_resetConnection(generation));
        throw const SshEngineException('网络端口查询超时，请重试');
      } on SshEngineException catch (e) {
        if (const {
          '网络端口连接已关闭',
          '无法查询网络端口，请检查连接',
          '网络端口查询超时，请重试',
        }.contains(e.message)) {
          unawaited(_resetConnection(generation));
        }
        rethrow;
      }
    }();
    return request.timeout(
      networkPortsTimeout,
      onTimeout: () {
        unawaited(_resetConnection(generation));
        throw const SshEngineException('网络端口查询超时，请重试');
      },
    );
  }

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) async {
    final session = await _getSession();
    if (_closed) throw const SshEngineException('连接已取消');
    if (session is! ProcessManagerSource) {
      throw const SshEngineException('此连接不支持进程管理');
    }
    // 目标退出或权限不足不应清空健康的后台连接和列表。
    return (session as ProcessManagerSource).readProcessDetails(process);
  }

  @override
  Future<void> terminateProcess(RemoteProcess process) async {
    final session = await _getSession();
    if (_closed) throw const SshEngineException('连接已取消');
    if (session is! ProcessManagerSource) {
      throw const SshEngineException('此连接不支持进程管理');
    }
    // 失败不重发 TERM；权限或进程已退出也不需要断开健康的后台连接。
    await (session as ProcessManagerSource).terminateProcess(process);
  }

  Future<T> _dockerQuery<T>(Future<T> Function(DockerManagerSource) read) {
    final generation = _generation;
    final request = () async {
      try {
        final session = await _getSession();
        if (_closed || generation != _generation) {
          throw const SshEngineException('Docker 管理连接已关闭');
        }
        if (session is! DockerManagerSource) {
          throw const SshEngineException('此连接不支持 Docker 管理');
        }
        final result = await read(session as DockerManagerSource);
        if (_closed || generation != _generation) {
          throw const SshEngineException('Docker 管理连接已关闭');
        }
        return result;
      } on TimeoutException {
        unawaited(_resetConnection(generation));
        throw const SshEngineException('Docker 查询超时，请重试');
      } on SshEngineException catch (e) {
        // Docker 服务和权限错误保留连接；断线、超时后允许重新连接。
        if (e.message == 'Docker 管理连接已关闭' ||
            e.message == '无法查询 Docker，请检查连接' ||
            e.message == 'Docker 查询超时，请重试') {
          unawaited(_resetConnection(generation));
        }
        rethrow;
      }
    }();
    // 同一个限时覆盖建立后台连接和读取；清理不能延迟超时错误。
    return request.timeout(
      dockerTimeout,
      onTimeout: () {
        unawaited(_resetConnection(generation));
        throw const SshEngineException('Docker 查询超时，请重试');
      },
    );
  }

  Future<void> _resetConnection(int generation) {
    if (generation != _generation) return Future<void>.value();
    _generation++;
    final cancellation = _cancellation;
    _cancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    // 清除旧握手的缓存；即使它迟到返回，也会被 _open 的 generation 回收。
    _connecting = null;
    final session = _session;
    _session = null;
    return _closeSession(session);
  }

  @override
  Future<List<DockerResource>> readDockerResources(DockerResourceKind kind) =>
      _dockerQuery((source) => source.readDockerResources(kind));

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) =>
      _dockerQuery((source) => source.readDockerDetails(resource));

  @override
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource container,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) => _dockerAction((session) {
    if (session is! DockerContainerActions) {
      throw const SshEngineException('此连接不支持 Docker 容器操作');
    }
    return (session as DockerContainerActions).runDockerContainerAction(
      container,
      action,
      targetImage: targetImage,
      forcePull: forcePull,
    );
  });

  @override
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) => _dockerAction((session) {
    if (session is! DockerImageActions) {
      throw const SshEngineException('此连接不支持 Docker 镜像操作');
    }
    return (session as DockerImageActions).runDockerImageAction(
      action,
      image: image,
    );
  });

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) => _dockerAction((session) {
    if (session is! DockerComposeActions) {
      throw const SshEngineException('此连接不支持 Docker 编排操作');
    }
    return (session as DockerComposeActions).runDockerComposeAction(
      project,
      action,
    );
  });

  Future<DockerActionResult> _dockerAction(
    Future<DockerActionResult> Function(SshEngineSession) run,
  ) async {
    final connect = _connect;
    if (_closed || connect == null) {
      throw const SshEngineException('Docker 管理连接已关闭');
    }
    final cancellation = Completer<void>();
    var accepting = true;
    SshEngineSession? owned;
    try {
      final pending = connect(cancellation.future).then((session) async {
        if (!accepting || _closed) {
          await _closeSession(session);
          throw const SshEngineException('连接已取消');
        }
        return session;
      });
      owned = await pending.timeout(
        dockerTimeout,
        onTimeout: () {
          accepting = false;
          if (!cancellation.isCompleted) cancellation.complete();
          throw const SshEngineException('Docker 操作连接超时，请重试');
        },
      );
      // 变更操作由 Rust 限时；面板/采集连接关闭不打断已提交的操作。
      return await run(owned);
    } finally {
      accepting = false;
      if (!cancellation.isCompleted) cancellation.complete();
      await _closeSession(owned);
    }
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    _connect = null;
    return _closing = _resetConnection(_generation);
  }

  static Future<void> _closeSession(SshEngineSession? session) async {
    try {
      await session?.close();
    } on Object {
      // 采集连接可能已因远端断开而关闭。
    }
  }
}
