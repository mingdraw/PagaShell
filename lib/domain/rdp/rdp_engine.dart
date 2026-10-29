import 'dart:typed_data';

import '../entities/host.dart';
import '../ssh/host_key.dart';
import '../ssh/ssh_engine.dart';

abstract interface class RdpEngine {
  Future<RdpEngineSession> connectDesktop(
    Host host,
    SshCredentials credentials, {
    required HostKeyVerifier verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  });
}

class RdpFrame {
  const RdpFrame({
    required this.width,
    required this.height,
    required this.rgba,
    this.x = 0,
    this.y = 0,
    int? patchWidth,
    int? patchHeight,
    this.tiles = const [],
    this.cursor,
  }) : patchWidth = patchWidth ?? width,
       patchHeight = patchHeight ?? height;
  final int width;
  final int height;
  final int x;
  final int y;
  final int patchWidth;
  final int patchHeight;
  final Uint8List rgba;

  /// Atlas source/destination rectangles; empty for a single rectangle frame.
  final List<RdpTile> tiles;
  final RdpCursor? cursor;
}

class RdpTile {
  const RdpTile({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.sourceX,
    required this.sourceY,
  });
  final int x;
  final int y;
  final int width;
  final int height;
  final int sourceX;
  final int sourceY;
}

enum RdpCursorKind { system, hidden, bitmap }

class RdpCursor {
  const RdpCursor({
    required this.kind,
    this.width = 0,
    this.height = 0,
    this.hotspotX = 0,
    this.hotspotY = 0,
    required this.rgba,
  });
  final RdpCursorKind kind;
  final int width;
  final int height;
  final int hotspotX;
  final int hotspotY;
  final Uint8List rgba;
}

abstract interface class RdpEngineSession {
  Stream<RdpFrame> get frames;
  Future<void> key(int scanCode, {required bool down, bool extended = false});
  Future<void> pointer(int x, int y, int flags, {int wheel = 0});
  Future<void> text(String text);

  /// True once the display request was sent; actual size arrives in [frames].
  /// False when the remote server does not offer dynamic Display Control.
  Future<bool> resize(int width, int height);
  Future<void> close();
}

/// Windows 拒绝了可重新输入的密码凭据；账号状态或协议错误不属于此类。
class DesktopAuthenticationException extends SshEngineException {
  const DesktopAuthenticationException(String message, {Object? cause})
    : super(message, cause);
}

class RdpAuthenticationException extends DesktopAuthenticationException {
  const RdpAuthenticationException(super.message, {super.cause});
}
