import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/dynamic_proxy_engine.dart';
import '../../domain/rdp/rdp_clipboard.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/host_key.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../../src/rust/api/desktop.dart' as desktop;
import '../../src/rust/api/page.dart' as page;
import '../../src/rust/api/proxy.dart' as proxy;
import '../../src/rust/api/ssh.dart' as rust;
import '../../src/rust/api/vnc.dart' as vnc;
import 'rdp_connection_error.dart';
import 'rust_transfer_stream.dart';
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
      final prepared = gateway?.host.gatewayType == GatewayType.page
          ? await desktop.desktopHandshakeViaPage(
              host: host.hostname,
              port: host.port,
              gateway: _pageSettings(gateway!),
            )
          : await desktop.desktopHandshake(
              host: host.hostname,
              port: host.port,
              sshGatewayId: sshGateway?._sessionId,
            );
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
        domain: host.rdpDomain,
      );
      checkCancelled();
      success = true;
      return _RustRdpDesktopSession(id, sshGateway);
    } on AnyhowException catch (e) {
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
    implements RdpClipboardSession {
  _RustRdpDesktopSession(super.id, super.gateway);

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
  Stream<RdpFrame> get frames async* {
    var sequence = 0;
    while (!_closed) {
      try {
        final frame = await (isVnc ? vnc.vncFrame : desktop.desktopFrame)(
          sessionId: id,
          afterSequence: sequence,
        );
        if (_closed) return;
        if (frame != null) {
          sequence = frame.sequence;
          yield RdpFrame(
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
          );
        }
      } on AnyhowException catch (e) {
        if (_closed) return;
        throw SshEngineException(e.message.split('\n').first, e);
      }
    }
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

class _RustEngineSession
    implements SshEngineSession, ServerStatusSource, PortForwardSession {
  _RustEngineSession(this._sessionId);

  final int _sessionId;
  bool _closed = false;

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
              targetHost: port.targetHost,
              targetPort: port.targetPort,
            ),
        ],
      )) {
        yield PortForwardEvent(kind: event.kind, localPort: event.localPort);
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
  Stream<String> startShell({required int cols, required int rows}) {
    // 流式 UTF-8 解码：正确处理跨分片的多字节字符（CJK/emoji）。
    return rust
        .sshStartShell(sessionId: _sessionId, cols: cols, rows: rows)
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true));
  }

  @override
  void write(String data) {
    if (_closed) return;
    unawaited(
      rust
          .sshWrite(sessionId: _sessionId, data: utf8.encode(data))
          .catchError((Object _) {}),
    );
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
  Stream<SftpTransferProgress> download(String remotePath, String localPath) {
    final transferId = _nextTransferId++;
    return _wrapTransfer(
      transferId,
      rust.sftpDownload(
        sessionId: _sessionId,
        transferId: transferId,
        remotePath: remotePath,
        localPath: localPath,
      ),
    );
  }

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) {
    final transferId = _nextTransferId++;
    return _wrapTransfer(
      transferId,
      rust.sftpUpload(
        sessionId: _sessionId,
        transferId: transferId,
        localPath: localPath,
        remotePath: remotePath,
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
  /// Rust 侧停止传输并清理半成品；错误统一转成 [SshEngineException]。
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

class _RustProxySession implements DynamicProxySession {
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
              targetHost: port.targetHost,
              targetPort: port.targetPort,
            ),
        ],
      )) {
        yield PortForwardEvent(kind: event.kind, localPort: event.localPort);
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
