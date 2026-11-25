import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/entities/small_text_file.dart';
import '../../domain/proxy/dynamic_proxy_engine.dart';
import '../../domain/rdp/rdp_clipboard.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/agent_ops.dart';
import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/firewall.dart';
import '../../domain/ssh/host_key.dart';
import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/terminal/terminal_frame.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../../src/rust/api/agent_ops.dart' as agent;
import '../../src/rust/api/desktop.dart' as desktop;
import '../../src/rust/api/docker.dart' as docker;
import '../../src/rust/api/firewall.dart' as firewall;
import '../../src/rust/api/network_ports.dart' as network_ports;
import '../../src/rust/api/page.dart' as page;
import '../../src/rust/api/proxy.dart' as proxy;
import '../../src/rust/api/ssh.dart' as rust;
import '../../src/rust/api/terminal.dart' as native_terminal;
import '../../src/rust/api/vnc.dart' as vnc;
import 'docker_parser.dart';
import 'firewall_parser.dart';
import 'network_ports_parser.dart';
import 'process_parser.dart';
import 'rdp_connection_error.dart';
import 'rust_transfer_stream.dart';
import 'server_profile_parser.dart';
import 'server_status_parser.dart';

page.PageGateway _pageSettings(SshGateway gateway) => page.PageGateway(
  serverHost: gateway.host.hostname,
  serverPort: gateway.host.port,
  clientId: gateway.host.pageClientId,
  token: gateway.credentials.password ?? '',
  serverFingerprint: gateway.host.pageServerFingerprint,
);

/// Rust 引擎（russh）的 [SshEngine] 适配器。
///
/// 桥接层职责：域模型 ↔ FFI 参数转换、字节流 → UTF-8 解码（容忍分片的
/// 多字节字符）、异常语义转换。协议逻辑全部在 Rust 侧。
class RustSshEngine
    implements
        SshEngine,
        PrivateKeyValidator,
        GatewayForwardEngine,
        DynamicProxyEngine {
  const RustSshEngine();

  @override
  Future<DynamicProxySession> startProxy(
    ProxyConfig config, {
    SshGateway? gateway,
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  }) async {
    config.validate(forStart: true);
    _RustEngineSession? sshGateway;
    int? id;
    var wasCancelled = false;
    var finished = false;
    var success = false;
    Future<void> cleanup() async {
      try {
        if (id != null) await proxy.proxyStop(proxyId: id);
      } finally {
        await sshGateway?.close();
      }
    }

    void checkCancelled() {
      if (wasCancelled) throw const SshEngineException('连接已取消');
    }

    if (cancelled != null) {
      unawaited(
        cancelled.then((_) async {
          if (finished) return;
          wasCancelled = true;
          await cleanup();
        }),
      );
    }
    try {
      checkCancelled();
      if (gateway == null) throw const SshEngineException('所选网关不可用');
      if (gateway.host.gatewayType == GatewayType.ssh) {
        sshGateway = await connect(
          gateway.host,
          gateway.credentials,
          verifyHostKey: verifyHostKey,
          cancelled: cancelled,
        ) as _RustEngineSession;
      }
      checkCancelled();
      id = await proxy.proxyStart(
        configJson: jsonEncode(config.toEngineJson()),
        sshGatewayId: sshGateway?._sessionId,
        pageGateway: gateway.host.gatewayType == GatewayType.page
            ? _pageSettings(gateway)
            : null,
      );
      checkCancelled();
      success = true;
      return _RustProxySession(id, sshGateway);
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    } finally {
      finished = true;
      if (!success) await cleanup();
    }
  }

  @override
  Future<PortForwardSession> connectForward(
    SshGateway gateway, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
  }) async {
    if (gateway.host.gatewayType == GatewayType.ssh) {
      final session = await connect(
        gateway.host,
        gateway.credentials,
        verifyHostKey: verifyHostKey,
        cancelled: cancelled,
      );
      return session as PortForwardSession;
    }
    var wasCancelled = false;
    var finished = false;
    int? id;
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) async {
          if (finished) return;
          wasCancelled = true;
          if (id != null) {
            await rust
                .pageForwardDisconnect(sessionId: id)
                .catchError((Object _) {});
          }
        }),
      );
    }
    try {
      id = await rust.pageForwardCreate(gateway: _pageSettings(gateway));
      if (wasCancelled) {
        await rust.pageForwardDisconnect(sessionId: id);
        throw const SshEngineException('连接已取消');
      }
      return _RustPageForwardSession(id);
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    } finally {
      finished = true;
    }
  }

  @override
  Future<void> validatePrivateKey(
    String privateKey, {
    String? passphrase,
  }) async {
    try {
      await rust.sshValidatePrivateKey(
        privateKey: privateKey,
        passphrase: passphrase,
      );
    } on Object {
      throw const SshEngineException('私钥格式无效或口令错误，请检查私钥与口令');
    }
  }

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    if (host.isDesktop) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    if (gateway?.host.isDesktop ?? false) {
      throw const SshEngineException('网关支持 SSH 或 Page 类型');
    }
    final ownedIds = <int>{};
    var wasCancelled = false;
    var finished = false;
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) async {
          if (finished) return;
          wasCancelled = true;
          for (final id in ownedIds.toList().reversed) {
            await rust.sshDisconnect(sessionId: id).catchError((Object _) {});
          }
        }),
      );
    }
    try {
      if (host.gatewayId != null && gateway?.host.id != host.gatewayId) {
        throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
      }
      if (verifyHostKey == null) {
        throw const SshEngineException('未配置主机密钥校验，已拒绝连接');
      }
      Future<int> connectEndpoint(
        Host endpoint,
        SshCredentials login, {
        int? gatewayId,
        page.PageGateway? pageGateway,
      }) async {
        if (wasCancelled) throw const SshEngineException('连接已取消');
        final handshake = pageGateway != null
            ? await rust.sshHandshakeViaPage(
                host: endpoint.hostname,
                port: endpoint.port,
                gateway: pageGateway,
              )
            : gatewayId == null
            ? await rust.sshHandshake(
                host: endpoint.hostname,
                port: endpoint.port,
              )
            : await rust.sshHandshakeViaGateway(
                host: endpoint.hostname,
                port: endpoint.port,
                gatewayId: gatewayId,
              );
        ownedIds.add(handshake.sessionId);
        if (wasCancelled) throw const SshEngineException('连接已取消');
        final accepted = await verifyHostKey(
          SshHostKey(
            hostname: endpoint.hostname,
            port: endpoint.port,
            keyType: handshake.keyType,
            fingerprint: handshake.fingerprint,
          ),
        );
        if (!accepted || wasCancelled) {
          throw const SshEngineException('主机密钥未获信任，已取消连接');
        }
        final username = login.username ?? endpoint.username;
        final sessionId = switch (login.authType) {
          AuthType.password => await rust.sshAuthenticate(
            sessionId: handshake.sessionId,
            expectedFingerprint: handshake.fingerprint,
            username: username,
            password: login.password!,
          ),
          AuthType.privateKey => await rust.sshAuthenticatePrivateKey(
            sessionId: handshake.sessionId,
            expectedFingerprint: handshake.fingerprint,
            username: username,
            privateKey: login.privateKey!,
            passphrase: login.passphrase,
          ),
          _ => throw const SshEngineException('暂不支持此认证方式'),
        };
        if (wasCancelled) throw const SshEngineException('连接已取消');
        return sessionId;
      }

      int? gatewayId;
      if (gateway != null && gateway.host.gatewayType == GatewayType.ssh) {
        gatewayId = await connectEndpoint(gateway.host, gateway.credentials);
      }
      final sessionId = await connectEndpoint(
        host,
        credentials,
        gatewayId: gatewayId,
        pageGateway: gateway?.host.gatewayType == GatewayType.page
            ? _pageSettings(gateway!)
            : null,
      );
      // Rust 目标会话接管网关的生命周期，关闭目标时一并关闭网关。
      ownedIds.clear();
      return _RustEngineSession(sessionId);
    } on SshEngineException {
      rethrow;
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    } on Object catch (e) {
      throw SshEngineException(e.toString(), e);
    } finally {
      finished = true;
      for (final id in ownedIds.toList().reversed) {
        await rust.sshDisconnect(sessionId: id).catchError((Object _) {});
      }
    }
  }
}

class RustRdpEngine implements RdpEngine {
  const RustRdpEngine();

  @override
  Future<RdpEngineSession> connectDesktop(
    Host host,
    SshCredentials credentials, {
    required HostKeyVerifier verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    if (credentials.authType != AuthType.password) {
      throw const SshEngineException('RDP 仅支持密码认证，请修改所选凭证');
    }
    if (host.gatewayId != null && gateway?.host.id != host.gatewayId) {
      throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
    }
    if (gateway?.host.isDesktop ?? false) {
      throw const SshEngineException('网关支持 SSH 或 Page 类型');
    }
    _RustEngineSession? sshGateway;
    int? id;
    var wasCancelled = false;
    var finished = false;
    Future<void> cleanup() async {
      if (id != null) {
        await desktop
            .desktopDisconnect(sessionId: id)
            .catchError((Object _) {});
      }
      await sshGateway?.close();
    }

    void checkCancelled() {
      if (wasCancelled) throw const SshEngineException('连接已取消');
    }

    if (cancelled != null) {
      unawaited(
        cancelled.then((_) async {
          if (finished) return;
          wasCancelled = true;
          await cleanup();
        }),
      );
    }
    var success = false;
    try {
      checkCancelled();
      if (gateway != null && gateway.host.gatewayType == GatewayType.ssh) {
        sshGateway = await const RustSshEngine().connect(
          gateway.host,
          gateway.credentials,
          verifyHostKey: verifyHostKey,
          cancelled: cancelled,
        ) as _RustEngineSession;
      }
      checkCancelled();
      final desktop.DesktopHandshake prepared;
      if (Platform.isWindows && gateway == null) {
        // Register a cancellable handle before the worker starts network I/O.
        final worker = await desktop.desktopWorkerOpen();
        id = worker.sessionId;
        checkCancelled();
        prepared = await desktop.desktopWorkerHandshake(
          sessionId: id,
          host: host.hostname,
          port: host.port,
        );
      } else if (gateway?.host.gatewayType == GatewayType.page) {
        prepared = await desktop.desktopHandshakeViaPage(
          host: host.hostname,
          port: host.port,
          gateway: _pageSettings(gateway!),
        );
      } else {
        prepared = await desktop.desktopHandshake(
          host: host.hostname,
          port: host.port,
          sshGatewayId: sshGateway?._sessionId,
        );
      }
      id = prepared.sessionId;
      checkCancelled();
      if (!await verifyHostKey(
        SshHostKey(
          hostname: host.hostname,
          port: host.port,
          keyType: 'X.509 SHA-256',
          fingerprint: prepared.fingerprint,
          protocol: ServerIdentityProtocol.rdp,
          certificateError: prepared.certificateError,
        ),
      )) {
        throw const SshEngineException('RDP 证书未获信任，已取消连接');
      }
      checkCancelled();
      await desktop.desktopAuthenticate(
        sessionId: id,
        expectedFingerprint: prepared.fingerprint,
        username: credentials.username ?? host.username,
        password: credentials.password!,
        domain: credentials.rdpDomain ?? host.rdpDomain,
      );
      checkCancelled();
      success = true;
      return _RustRdpDesktopSession(id, sshGateway);
    } on AnyhowException catch (e) {
      checkCancelled();
      throw rdpConnectionError(e.message, cause: e);
    } finally {
      finished = true;
      if (!success) await cleanup();
    }
  }
}

class RustVncEngine implements VncEngine {
  const RustVncEngine();

  @override
  Future<RdpEngineSession> connectDesktop(
    Host host,
    SshCredentials credentials, {
    required HostKeyVerifier verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    if (credentials.authType != AuthType.password) {
      throw const SshEngineException('VNC 仅支持密码认证，请修改所选凭证');
    }
    if (host.gatewayId != null && gateway?.host.id != host.gatewayId) {
      throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
    }
    if (gateway?.host.isDesktop ?? false) {
      throw const SshEngineException('网关支持 SSH 或 Page 类型');
    }
    _RustEngineSession? sshGateway;
    int? id;
    var wasCancelled = false;
    var finished = false;
    var success = false;
    Future<void> cleanup() async {
      if (id != null) {
        await vnc.vncDisconnect(sessionId: id).catchError((Object _) {});
      }
      await sshGateway?.close();
    }

    void checkCancelled() {
      if (wasCancelled) throw const SshEngineException('连接已取消');
    }

    if (cancelled != null) {
      unawaited(
        cancelled.then((_) async {
          if (finished) return;
          wasCancelled = true;
          await cleanup();
        }),
      );
    }
    try {
      checkCancelled();
      if (gateway != null && gateway.host.gatewayType == GatewayType.ssh) {
        sshGateway = await const RustSshEngine().connect(
          gateway.host,
          gateway.credentials,
          verifyHostKey: verifyHostKey,
          cancelled: cancelled,
        ) as _RustEngineSession;
      }
      checkCancelled();
      id = await vnc.vncConnect(
        host: host.hostname,
        port: host.port,
        password: credentials.password ?? '',
        sshGatewayId: sshGateway?._sessionId,
        pageGateway: gateway?.host.gatewayType == GatewayType.page
            ? _pageSettings(gateway!)
            : null,
      );
      checkCancelled();
      success = true;
      return _RustVncDesktopSession(id, sshGateway);
    } on AnyhowException catch (e) {
      if (e.message.contains('VNC_AUTH_FAILED')) {
        throw VncAuthenticationException('VNC 服务器未接受密码，请重新输入。', cause: e);
      }
      throw SshEngineException(e.message.split('\n').first, e);
    } finally {
      finished = true;
      if (!success) await cleanup();
    }
  }
}

class _RustRdpDesktopSession extends _RustDesktopSession
    implements RdpClipboardSession, RdpBatchInputSession {
  _RustRdpDesktopSession(super.id, super.gateway);

  @override
  Future<void> inputBatch(List<RdpInputEvent> events) async {
    if (_closed) return;
    try {
      await desktop.desktopInputBatch(
        sessionId: id,
        events: [
          for (final event in events)
            switch (event) {
              RdpKeyInput() => desktop.DesktopInputEvent(
                pointer: false,
                code: event.scanCode,
                flags: (event.down ? 0 : 1) | (event.extended ? 2 : 0),
                x: 0,
                y: 0,
              ),
              RdpPointerInput() => desktop.DesktopInputEvent(
                pointer: true,
                code: event.wheel,
                flags: event.flags,
                x: event.x,
                y: event.y,
              ),
            },
        ],
      );
    } on AnyhowException catch (error) {
      throw SshEngineException(error.message.split('\n').first, error);
    }
  }

  @override
  Stream<RdpClipboardEvent> get clipboardEvents async* {
    var sequence = 0;
    while (!_closed) {
      try {
        final event = await desktop.desktopClipboardEvent(
          sessionId: id,
          afterSequence: sequence,
        );
        if (_closed) return;
        if (event == null) continue;
        sequence = event.sequence;
        yield RdpClipboardEvent(
          kind: RdpClipboardEventKind.values[event.kind],
          content: ClipboardContent(text: event.text, files: event.files),
          transferred: event.transferred.toInt(),
          total: event.total.toInt(),
          error: event.error,
        );
      } on AnyhowException {
        if (_closed) return;
        throw const SshEngineException('RDP 剪贴板已断开，请重新连接');
      }
    }
  }

  @override
  Future<void> setClipboardActive(bool active) async {
    if (_closed) return;
    final directory = active
        ? path.join((await getTemporaryDirectory()).path, 'rdp-clipboard')
        : '';
    await desktop.desktopClipboardActive(
      sessionId: id,
      active: active,
      cacheDirectory: directory,
    );
  }

  @override
  Future<void> updateClipboard(ClipboardContent content) async {
    if (_closed) return;
    try {
      await desktop.desktopClipboardUpdate(
        sessionId: id,
        text: content.text,
        files: content.files,
      );
    } on AnyhowException catch (error) {
      throw SshEngineException(error.message.split('\n').first);
    }
  }

  @override
  Future<void> cancelClipboardTransfer() async {
    if (!_closed) await desktop.desktopClipboardCancel(sessionId: id);
  }
}

class _RustVncDesktopSession extends _RustDesktopSession
    implements VncEngineSession {
  _RustVncDesktopSession(super.id, super.gateway) : super(isVnc: true);

  @override
  Future<void> keySymbol(int keysym, {required bool down}) =>
      _input(code: keysym, flags: down ? 0 : 1);

  @override
  Future<bool> resize(int width, int height) async => false;
}

class _RustDesktopSession implements RdpEngineSession {
  _RustDesktopSession(this.id, this.gateway, {this.isVnc = false});
  final int id;
  final _RustEngineSession? gateway;
  final bool isVnc;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Stream<RdpFrame> get frames {
    var sequence = 0;
    var pumping = false;
    late final StreamController<RdpFrame> controller;
    Future<void> pump() async {
      if (pumping || controller.isClosed) return;
      pumping = true;
      try {
        // An async* stream only suspends at yield. When the frame RPC times
        // out with no update, it would keep polling even with a paused viewer.
        while (!_closed && controller.hasListener && !controller.isPaused) {
          final reply = await (isVnc ? vnc.vncFrame : desktop.desktopFrame)(
            sessionId: id,
            afterSequence: sequence,
          );
          final frame = await reply.first;
          if (_closed || !controller.hasListener) return;
          if (frame == null) continue;
          sequence = frame.sequence;
          controller.add(
            RdpFrame(
              width: frame.width,
              height: frame.height,
              rgba: frame.rgba,
              patchWidth: frame.bitmapWidth,
              patchHeight: frame.bitmapHeight,
              tiles: [
                for (final tile in frame.tiles)
                  RdpTile(
                    x: tile.x,
                    y: tile.y,
                    width: tile.width,
                    height: tile.height,
                    sourceX: tile.sourceX,
                    sourceY: tile.sourceY,
                  ),
              ],
              cursor: frame.cursor == null
                  ? null
                  : RdpCursor(
                      kind: switch (frame.cursor!.kind) {
                        1 => RdpCursorKind.hidden,
                        2 => RdpCursorKind.bitmap,
                        _ => RdpCursorKind.system,
                      },
                      width: frame.cursor!.width,
                      height: frame.cursor!.height,
                      hotspotX: frame.cursor!.hotspotX,
                      hotspotY: frame.cursor!.hotspotY,
                      rgba: frame.cursor!.rgba,
                    ),
            ),
          );
        }
      } on Object catch (error, stack) {
        if (!_closed && controller.hasListener) {
          controller.addError(
            error is AnyhowException
                ? SshEngineException(error.message.split('\n').first, error)
                : error,
            stack,
          );
        }
        unawaited(controller.close());
      } finally {
        pumping = false;
        if (_closed && !controller.isClosed) unawaited(controller.close());
      }
    }

    controller = StreamController<RdpFrame>(
      sync: true,
      onListen: () => scheduleMicrotask(() => unawaited(pump())),
      onResume: () => unawaited(pump()),
    );
    return controller.stream;
  }

  Future<void> _input({
    int kind = 0,
    int code = 0,
    int flags = 0,
    int x = 0,
    int y = 0,
    String text = '',
  }) async {
    if (_closed) return;
    try {
      await (isVnc ? vnc.vncInput : desktop.desktopInput)(
        sessionId: id,
        kind: kind,
        code: code,
        flags: flags,
        x: x,
        y: y,
        text: text,
      );
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<void> key(int scanCode, {required bool down, bool extended = false}) =>
      _input(code: scanCode, flags: (down ? 0 : 1) | (extended ? 2 : 0));
  @override
  Future<void> pointer(int x, int y, int flags, {int wheel = 0}) =>
      _input(kind: 1, x: x, y: y, flags: flags, code: wheel);
  @override
  Future<void> text(String text) => _input(kind: 2, text: text);
  @override
  Future<bool> resize(int width, int height) async {
    if (_closed) throw const SshEngineException('RDP 会话已关闭');
    try {
      return await desktop.desktopResize(
        sessionId: id,
        width: width,
        height: height,
      );
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    _closed = true;
    try {
      await (isVnc ? vnc.vncDisconnect : desktop.desktopDisconnect)(
        sessionId: id,
      );
    } finally {
      await gateway?.close();
    }
  }();
}

class _RustSshExecHandle implements SshExecHandle {
  _RustSshExecHandle(
    this._sessionId,
    this._id,
    String command,
    int timeoutSecs,
  ) {
    _events = StreamController<SshExecEvent>(onCancel: cancel);
    agent
        .sshExecStream(
          sessionId: _sessionId,
          execId: _id,
          command: command,
          timeoutSecs: timeoutSecs,
        )
        .listen(
          (event) {
            if (event.kind == 'started') {
              _registered.complete(true);
              return;
            }
            final kind = switch (event.kind) {
              'stdout' => SshExecEventKind.stdout,
              'stderr' => SshExecEventKind.stderr,
              'exit' => SshExecEventKind.exit,
              _ => null,
            };
            if (kind != null) {
              _events.add(
                SshExecEvent(
                  kind,
                  data: event.data,
                  exitCode: event.exitCode,
                  timedOut: event.timedOut,
                  cancelled: event.cancelled,
                  truncated: event.truncated,
                ),
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            _events.addError(
              const SshEngineException('SSH 后台命令未完成，请检查连接'),
              stack,
            );
          },
          onDone: () {
            if (!_registered.isCompleted) _registered.complete(false);
            _finished = true;
            unawaited(_events.close());
          },
        );
  }

  final int _sessionId, _id;
  final _registered = Completer<bool>();
  late final StreamController<SshExecEvent> _events;
  Future<void>? _cancelling;
  bool _finished = false;

  @override
  Stream<SshExecEvent> get events => _events.stream;

  @override
  Future<void> cancel() => _cancelling ??= () async {
    // Dart may see Stop before the FRB stream has registered on the Rust side.
    if (await _registered.future && !_finished) {
      await agent.sshExecCancel(sessionId: _sessionId, execId: _id);
    }
  }();
}

class _RustEngineSession
    implements
        SshEngineSession,
        ResumableSftpSession,
        SmallTextFileAccess,
        ServerStatusSource,
        ServerProfileSource,
        SshExecSource,
        RemoteFileOpsSource,
        ProcessManagerSource,
        NetworkPortsSource,
        FirewallSource,
        DockerManagerSource,
        DockerLogsSource,
        DockerContainerActions,
        DockerImageActions,
        DockerComposeActions,
        DockerTerminalSource,
        PortForwardSession,
        TerminalScreenSource {
  _RustEngineSession(this._sessionId);

  static int _nextExecId = 0;

  @override
  SshExecHandle startExec(String command, {required int timeoutSecs}) {
    if (_closed) throw const SshEngineException('终端已关闭');
    _nextExecId = (_nextExecId + 1) & 0xffffffff;
    return _RustSshExecHandle(_sessionId, _nextExecId, command, timeoutSecs);
  }

  @override
  Future<ServerProfile> readServerProfile() => _guard(() async {
    if (_closed) throw const SshEngineException('终端已关闭');
    return parseServerProfile(
      await agent.sshReadServerProfile(sessionId: _sessionId),
    );
  });

  @override
  Future<RemoteTextSnapshot> readRemoteText(
    String path, {
    required bool useSudo,
  }) => _remoteFile(() async {
    final file = await agent.sshReadRemoteText(
      sessionId: _sessionId,
      path: path,
      useSudo: useSudo,
    );
    return RemoteTextSnapshot(
      text: file.text,
      sha256: file.sha256,
      sizeBytes: file.sizeBytes,
      modifiedUnix: file.modifiedUnix,
      usedSudo: file.usedSudo,
    );
  });

  @override
  Future<RemoteWriteResult> writeRemoteText(
    String path,
    String content, {
    required String? expectedSha256,
    required bool createIfMissing,
    required bool createParentDirs,
    required String backupSuffix,
    required bool useSudo,
  }) => _remoteFile(() async {
    final result = await agent.sshWriteRemoteText(
      sessionId: _sessionId,
      request: agent.RemoteWriteRequest(
        path: path,
        content: content,
        expectedSha256: expectedSha256,
        createIfMissing: createIfMissing,
        createParentDirs: createParentDirs,
        backupSuffix: backupSuffix,
        useSudo: useSudo,
      ),
    );
    return RemoteWriteResult(
      sha256: result.newSha256,
      backupPath: result.backupPath,
      createdNew: result.createdNew,
      usedSudo: result.usedSudo,
    );
  });

  @override
  Future<void> restoreRemoteBackup(
    String path, {
    required String? backupPath,
    required String currentSha256,
    required String? backupSha256,
    required bool useSudo,
  }) => _remoteFile(
    () => agent.sshRestoreRemoteBackup(
      sessionId: _sessionId,
      path: path,
      backupPath: backupPath,
      expectedCurrentSha256: currentSha256,
      expectedBackupSha256: backupSha256,
      useSudo: useSudo,
    ),
  );

  Future<T> _remoteFile<T>(Future<T> Function() operation) async {
    if (_closed) throw const RemoteFileOpsException(RemoteFileError.failed);
    try {
      return await operation();
    } on AnyhowException catch (error) {
      throw RemoteFileOpsException(switch (error.message
          .split('\n')
          .first
          .trim()) {
        'FILE_NOT_FOUND' => RemoteFileError.notFound,
        'FILE_CONFLICT' || 'FILE_ALREADY_EXISTS' => RemoteFileError.conflict,
        'SUDO_PASSWORD_REQUIRED' => RemoteFileError.sudoPasswordRequired,
        'INVALID_TARGET' => RemoteFileError.invalidTarget,
        'SENSITIVE_FILE' => RemoteFileError.sensitive,
        'FILE_TOO_LARGE' || '文本文件不能超过 2 MiB' => RemoteFileError.tooLarge,
        'REMOTE_FILE_OUTCOME_UNKNOWN' => RemoteFileError.outcomeUnknown,
        _ => RemoteFileError.failed,
      });
    }
  }

  @override
  Future<SmallTextFile> readSmallText(String path) => _guard(() async {
    final file = await rust.sftpReadText(sessionId: _sessionId, path: path);
    final timestamp = file.modifiedUnix;
    return SmallTextFile(
      file.text,
      timestamp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
    );
  });

  @override
  Future<void> saveSmallText(
    String path,
    SmallTextFile original,
    String text,
  ) => _guard(
    () => rust.sftpSaveText(
      sessionId: _sessionId,
      path: path,
      original: rust.SftpTextFile(
        text: original.text,
        modifiedUnix: original.modified == null
            ? null
            : original.modified!.millisecondsSinceEpoch ~/ 1000,
      ),
      text: text,
    ),
  );

  final int _sessionId;
  bool _closed = false;

  // 终端输入串行发送：同时只有一个 sshWrite 在途，期间的输入合并为下一次
  // 调用。各自独立的异步 FFI 调用在多线程运行时上不保证执行顺序，快速输入
  // 或分片粘贴可能乱序；合并也减少了逐键的跨语言调用与全局会话锁竞争。
  final _pendingInput = BytesBuilder(copy: false);
  bool _writingInput = false;
  bool _awaitingDockerFrame = false;

  @override
  Stream<PortForwardEvent> startPortForwards(List<ForwardPort> ports) async* {
    if (_closed) throw const SshEngineException('端口转发已断开');
    try {
      await for (final event in rust.sshStartPortForwards(
        sessionId: _sessionId,
        ports: [
          for (final port in ports)
            rust.ForwardPortSpec(
              localPort: port.localPort,
              bindHost: port.bindHost,
              targetHost: port.targetHost,
              targetPort: port.targetPort,
            ),
        ],
      )) {
        yield PortForwardEvent(
          kind: event.kind,
          localPort: event.localPort,
          message: event.message,
        );
      }
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<ServerStatusSample> readServerStatus() => _guard(() async {
    if (_closed) throw const SshEngineException('终端已关闭');
    return parseServerStatus(
      await rust.sshReadServerStatus(sessionId: _sessionId),
    );
  });

  @override
  Future<ProcessSnapshot> readProcesses() => _guard(() async {
    if (_closed) throw const SshEngineException('进程管理连接已关闭');
    return parseProcesses(await rust.sshReadProcesses(sessionId: _sessionId));
  });

  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() => _guard(() async {
    if (_closed) throw const SshEngineException('网络端口连接已关闭');
    return parseNetworkPorts(
      await network_ports.sshReadNetworkPorts(sessionId: _sessionId),
    );
  });

  @override
  Future<FirewallSnapshot> readFirewall() => _guard(() async {
    if (_closed) throw const SshEngineException('防火墙管理连接已关闭');
    return parseFirewallSnapshot(
      await firewall.sshReadFirewall(sessionId: _sessionId),
    );
  });

  @override
  Future<void> addFirewallRules(
    FirewallBackend backend,
    List<FirewallRuleInput> rules,
  ) => _guard(() async {
    if (_closed) throw const SshEngineException('防火墙管理连接已关闭');
    await firewall.sshAddFirewallRules(
      sessionId: _sessionId,
      backend: _firewallBackend(backend),
      rules: [for (final rule in rules) _firewallRuleSpec(rule)],
    );
  });

  @override
  Future<void> deleteFirewallRule(FirewallRule rule) => _guard(() async {
    if (_closed) throw const SshEngineException('防火墙管理连接已关闭');
    await firewall.sshDeleteFirewallRule(
      sessionId: _sessionId,
      backend: _firewallBackend(rule.backend),
      existingRaw: rule.rawRule,
    );
  });

  @override
  Future<void> runFirewallServiceAction(
    FirewallBackend backend,
    FirewallServiceAction action,
  ) => _guard(() async {
    if (_closed) throw const SshEngineException('防火墙管理连接已关闭');
    await firewall.sshRunFirewallServiceAction(
      sessionId: _sessionId,
      backend: _firewallBackend(backend),
      action: switch (action) {
        FirewallServiceAction.enable =>
          firewall.FirewallServiceActionKind.enable,
        FirewallServiceAction.disable =>
          firewall.FirewallServiceActionKind.disable,
        FirewallServiceAction.reload =>
          firewall.FirewallServiceActionKind.reload,
      },
    );
  });

  static firewall.FirewallBackendKind _firewallBackend(
    FirewallBackend backend,
  ) => switch (backend) {
    FirewallBackend.firewalld => firewall.FirewallBackendKind.firewalld,
    FirewallBackend.ufw => firewall.FirewallBackendKind.ufw,
    FirewallBackend.nftables => firewall.FirewallBackendKind.nftables,
    FirewallBackend.iptables => firewall.FirewallBackendKind.iptables,
  };

  static firewall.FirewallRuleSpec _firewallRuleSpec(FirewallRuleInput rule) =>
      firewall.FirewallRuleSpec(
        action: switch (rule.action) {
          FirewallAction.allow => firewall.FirewallActionKind.allow,
          FirewallAction.deny => firewall.FirewallActionKind.deny,
        },
        protocol: switch (rule.protocol) {
          FirewallProtocol.tcp => firewall.FirewallProtocolKind.tcp,
          FirewallProtocol.udp => firewall.FirewallProtocolKind.udp,
          FirewallProtocol.tcpUdp => firewall.FirewallProtocolKind.tcpUdp,
        },
        port: rule.port,
        source: rule.source,
        priority: rule.priority,
        comment: rule.comment,
      );

  @override
  Future<List<DockerResource>> readDockerResources(DockerResourceKind kind) =>
      _guard(() async {
        if (_closed) throw const SshEngineException('Docker 管理连接已关闭');
        return parseDockerResources(
          await docker.sshReadDockerResources(
            sessionId: _sessionId,
            kind: _dockerKind(kind),
          ),
          kind,
        );
      });

  @override
  Future<DockerLogSession> openDockerLogs(DockerResource container) =>
      _guard(() async {
        if (_closed || container.kind != DockerResourceKind.container) {
          throw const SshEngineException('无法打开容器日志，请检查连接');
        }
        final logs = _RustDockerLogSession(
          await docker.sshOpenDockerLogs(
            sessionId: _sessionId,
            containerId: container.id,
          ),
        );
        if (_closed) {
          await logs.close();
          throw const SshEngineException('Docker 管理连接已关闭');
        }
        return logs;
      });

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) =>
      _guard(() async {
        if (_closed) throw const SshEngineException('Docker 管理连接已关闭');
        return parseDockerDetails(
          await docker.sshReadDockerDetails(
            sessionId: _sessionId,
            kind: _dockerKind(resource.kind),
            resourceId: resource.id,
          ),
          resource,
        );
      });

  @override
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource container,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) => _guard(() async {
    if (_closed) throw const SshEngineException('Docker 操作连接已关闭');
    if (container.kind != DockerResourceKind.container) {
      throw const SshEngineException('此操作仅支持容器');
    }
    final warning = await docker.sshRunDockerContainerAction(
      sessionId: _sessionId,
      containerId: container.id,
      action: switch (action) {
        DockerContainerAction.start => docker.DockerContainerAction.start,
        DockerContainerAction.stop => docker.DockerContainerAction.stop,
        DockerContainerAction.upgrade => docker.DockerContainerAction.upgrade,
        DockerContainerAction.delete => docker.DockerContainerAction.delete,
      },
      targetImage: targetImage,
      forcePull: forcePull,
    );
    return DockerActionResult(warning: warning);
  });

  @override
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) => _guard(() async {
    if (_closed) throw const SshEngineException('Docker 操作连接已关闭');
    if (image != null && image.kind != DockerResourceKind.image) {
      throw const SshEngineException('此操作仅支持镜像');
    }
    await docker.sshRunDockerImageAction(
      sessionId: _sessionId,
      action: switch (action) {
        DockerImageAction.delete => docker.DockerImageAction.delete,
        DockerImageAction.pruneUntagged =>
          docker.DockerImageAction.pruneUntagged,
        DockerImageAction.pruneUnused => docker.DockerImageAction.pruneUnused,
      },
      imageId: image?.id,
    );
    return const DockerActionResult();
  });

  static docker.DockerResourceKind _dockerKind(DockerResourceKind kind) =>
      switch (kind) {
        DockerResourceKind.compose => docker.DockerResourceKind.compose,
        DockerResourceKind.container => docker.DockerResourceKind.container,
        DockerResourceKind.image => docker.DockerResourceKind.image,
        DockerResourceKind.network => docker.DockerResourceKind.network,
        DockerResourceKind.volume => docker.DockerResourceKind.volume,
      };

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) => _guard(() async {
    if (_closed) throw const SshEngineException('Docker 操作连接已关闭');
    if (project.kind != DockerResourceKind.compose) {
      throw const SshEngineException('此操作仅支持编排');
    }
    final warning = await docker.sshRunDockerComposeAction(
      sessionId: _sessionId,
      projectName: project.id,
      action: switch (action) {
        DockerComposeAction.start => docker.DockerComposeAction.start,
        DockerComposeAction.stop => docker.DockerComposeAction.stop,
        DockerComposeAction.rebuild => docker.DockerComposeAction.rebuild,
        DockerComposeAction.delete => docker.DockerComposeAction.delete,
      },
    );
    return DockerActionResult(warning: warning);
  });

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) =>
      _guard(() async {
        if (_closed) throw const SshEngineException('进程管理连接已关闭');
        return parseProcessDetails(
          await rust.sshReadProcessDetails(
            sessionId: _sessionId,
            pid: process.pid,
            startedAt: process.startedAt,
          ),
          process,
        );
      });

  @override
  Future<void> terminateProcess(RemoteProcess process) => _guard(() async {
    if (_closed) throw const SshEngineException('进程管理连接已关闭');
    await rust.sshTerminateProcess(
      sessionId: _sessionId,
      pid: process.pid,
      startedAt: process.startedAt,
    );
  });

  @override
  Stream<TerminalFrame> startTerminalShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    if (_closed) throw const SshEngineException('终端已关闭');
    return rust
        .sshStartTerminal(
          sessionId: _sessionId,
          cols: cols,
          rows: rows,
          scrollback: scrollback,
        )
        .map(_terminalFrame);
  }

  @override
  Stream<TerminalFrame> startDockerTerminalShell({
    required DockerTerminalTarget target,
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    if (_closed) throw const SshEngineException('终端已关闭');
    // 容器预检可能等待数秒；PTY 就绪前保留输入，避免写入尚未建立的通道。
    _awaitingDockerFrame = true;
    return _dockerTerminalFrames(target, cols, rows, scrollback);
  }

  Stream<TerminalFrame> _dockerTerminalFrames(
    DockerTerminalTarget target,
    int cols,
    int rows,
    int scrollback,
  ) async* {
    try {
      yield* rust
          .sshStartDockerTerminal(
            sessionId: _sessionId,
            containerId: target.id,
            cols: cols,
            rows: rows,
            scrollback: scrollback,
          )
          .map((frame) {
            _awaitingDockerFrame = false;
            if (!_writingInput && _pendingInput.isNotEmpty) {
              unawaited(_drainInput());
            }
            return _terminalFrame(frame);
          })
          .handleError((Object error, StackTrace stack) {
            Error.throwWithStackTrace(
              error is AnyhowException
                  ? SshEngineException(error.message.split('\n').first, error)
                  : error,
              stack,
            );
          });
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    } finally {
      _awaitingDockerFrame = false;
      _pendingInput.clear();
    }
  }

  static TerminalFrame _terminalFrame(native_terminal.TerminalFrame frame) =>
      TerminalFrame(
        frameId: frame.frameId,
        columns: frame.columns,
        rows: frame.rows,
        alternate: frame.alternate,
        cursorX: frame.cursorX,
        cursorY: frame.cursorY,
        modes: frame.modes,
        cursorBlink: frame.cursorBlink,
        trimFront: frame.trimFront,
        keepRows: frame.keepRows,
        appendRows: frame.appendRows,
        lines: [
          for (final line in frame.lines)
            TerminalLine(
              id: line.id,
              wrapped: line.wrapped,
              cells: line.cells,
              // 绝大多数行没有组合字符，避免每行分配一个空 Map。
              clusters: line.clusters.isEmpty
                  ? const {}
                  : {
                      for (final cluster in line.clusters)
                        cluster.column: cluster.text,
                    },
            ),
        ],
        title: frame.title,
        bell: frame.bell,
      );

  @override
  Future<void> acknowledgeTerminalFrame(int frameId) => _guard(() async {
    if (_closed) return;
    rust.sshTerminalAck(sessionId: _sessionId, frameId: frameId);
  });

  @override
  void write(String data) {
    if (_closed || data.isEmpty) return;
    _pendingInput.add(utf8.encode(data));
    if (!_writingInput && !_awaitingDockerFrame) unawaited(_drainInput());
  }

  Future<void> _drainInput() async {
    _writingInput = true;
    try {
      while (!_closed && !_awaitingDockerFrame && _pendingInput.isNotEmpty) {
        final bytes = _pendingInput.takeBytes();
        try {
          await rust.sshWrite(sessionId: _sessionId, data: bytes);
        } on Object {
          // 与此前一致：终端关闭等写入失败由会话生命周期处理，不向输入方抛出。
        }
      }
    } finally {
      _writingInput = false;
    }
  }

  @override
  void resizeTerminal(int width, int height) {
    if (_closed) return;
    unawaited(
      rust
          .sshResize(sessionId: _sessionId, cols: width, rows: height)
          .catchError((Object _) {}),
    );
  }

  /// 每个传输的进程内唯一 id，供取消指令定位 Rust 侧的取消标志。
  static int _nextTransferId = 1;

  @override
  Future<List<SftpDirEntry>> listDir(String path) => _guard(() async {
    final entries = await rust.sftpListDir(sessionId: _sessionId, path: path);
    return [
      for (final e in entries)
        SftpDirEntry(
          name: e.name,
          isDir: e.isDir,
          size: e.size.toInt(),
          modified: e.modifiedUnix == BigInt.zero
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  e.modifiedUnix.toInt() * 1000,
                ),
        ),
    ];
  });

  @override
  Future<String> canonicalize(String path) =>
      _guard(() => rust.sftpCanonicalize(sessionId: _sessionId, path: path));

  @override
  Stream<SftpTransferProgress> download(String remotePath, String localPath) =>
      _download(remotePath, localPath, resume: false);

  @override
  Stream<SftpTransferProgress> downloadResuming(
    String remotePath,
    String localPath,
  ) => _download(remotePath, localPath, resume: true);

  Stream<SftpTransferProgress> _download(
    String remotePath,
    String localPath, {
    required bool resume,
  }) {
    final transferId = _nextTransferId++;
    return _wrapTransfer(
      transferId,
      rust.sftpDownload(
        sessionId: _sessionId,
        transferId: transferId,
        remotePath: remotePath,
        localPath: localPath,
        resume: resume,
      ),
    );
  }

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) =>
      _upload(localPath, remotePath, resume: false);

  @override
  Stream<SftpTransferProgress> uploadResuming(
    String localPath,
    String remotePath,
  ) => _upload(localPath, remotePath, resume: true);

  Stream<SftpTransferProgress> _upload(
    String localPath,
    String remotePath, {
    required bool resume,
  }) {
    final transferId = _nextTransferId++;
    return _wrapTransfer(
      transferId,
      rust.sftpUpload(
        sessionId: _sessionId,
        transferId: transferId,
        localPath: localPath,
        remotePath: remotePath,
        resume: resume,
      ),
    );
  }

  @override
  Future<void> createDir(String path) =>
      _guard(() => rust.sftpMkdir(sessionId: _sessionId, path: path));

  @override
  Future<void> rename(String oldPath, String newPath) => _guard(
    () => rust.sftpRename(sessionId: _sessionId, from: oldPath, to: newPath),
  );

  @override
  Future<void> remove(String path, {required bool isDir}) => _guard(
    () => rust.sftpRemove(sessionId: _sessionId, path: path, isDir: isDir),
  );

  /// 把 Rust 进度流包装为 domain 流：
  /// 监听方取消订阅（且传输未结束）时向 Rust 发取消指令，
  /// Rust 侧停止传输并保留已写入文件；错误统一转成 [SshEngineException]。
  Stream<SftpTransferProgress> _wrapTransfer(
    int transferId,
    Stream<rust.TransferProgress> inner,
  ) => rustTransferStream(
    inner,
    cancel: () => rust
        .sftpCancelTransfer(transferId: transferId)
        .catchError((Object _) {}),
  );

  /// 统一异常语义转换。
  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await rust.sshDisconnect(sessionId: _sessionId);
    } on Object {
      // 断开失败不影响本地清理。
    }
  }
}

class _RustDockerLogSession implements DockerLogSession {
  _RustDockerLogSession(this.id);

  final int id;
  Future<void>? _closing;

  Stream<List<int>> _chunks() async* {
    try {
      if (_closing == null) yield* docker.sshStreamDockerLogs(logId: id);
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Stream<String> get output =>
      const Utf8Decoder(allowMalformed: true).bind(_chunks());

  @override
  Future<void> close() => _closing ??= docker.sshCloseDockerLogs(logId: id);
}

class _RustProxySession
    implements
        DynamicProxySession,
        DynamicProxyTrafficSource,
        DynamicProxyHotReload {
  _RustProxySession(this.id, this.gateway) {
    done = proxy.proxyWait(proxyId: id).then((error) {
      if (error != null) throw SshEngineException(error);
    });
  }
  final int id;
  final _RustEngineSession? gateway;
  @override
  late final Future<void> done;
  Future<void>? _closing;

  @override
  Future<ProxyTraffic?> readTraffic() async {
    final traffic = await proxy.proxyTraffic(proxyId: id);
    if (traffic == null) return null;
    return (sent: traffic.sent.toInt(), received: traffic.received.toInt());
  }

  @override
  Future<void> updateRouting(ProxyConfig config) async {
    config.validate();
    try {
      await proxy.proxyUpdateRules(
        proxyId: id,
        configJson: jsonEncode(config.toEngineJson()),
      );
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    try {
      await proxy.proxyStop(proxyId: id);
    } finally {
      await gateway?.close();
    }
  }();
}

class _RustPageForwardSession implements PortForwardSession {
  _RustPageForwardSession(this.id);
  final int id;
  bool _closed = false;

  @override
  Stream<PortForwardEvent> startPortForwards(List<ForwardPort> ports) async* {
    if (_closed) throw const SshEngineException('端口转发已断开');
    try {
      await for (final event in rust.pageStartPortForwards(
        sessionId: id,
        ports: [
          for (final port in ports)
            rust.ForwardPortSpec(
              localPort: port.localPort,
              bindHost: port.bindHost,
              targetHost: port.targetHost,
              targetPort: port.targetPort,
            ),
        ],
      )) {
        yield PortForwardEvent(
          kind: event.kind,
          localPort: event.localPort,
          message: event.message,
        );
      }
    } on AnyhowException catch (e) {
      throw SshEngineException(e.message.split('\n').first, e);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await rust.pageForwardDisconnect(sessionId: id);
  }
}
