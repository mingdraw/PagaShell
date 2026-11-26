import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../domain/rdp/rdp_engine.dart';

class RdpWindowsCursor extends MouseCursor {
  const RdpWindowsCursor._(this._id);

  static const _enabled = bool.fromEnvironment('PAGASHELL_RDP_NATIVE_CURSOR');
  static const _channel = MethodChannel('pagashell/rdpCursor');
  final int _id;

  static Future<RdpWindowsCursor?> create(RdpCursor bitmap) async {
    if (!Platform.isWindows ||
        (!_enabled &&
            Platform.environment['PAGASHELL_RDP_NATIVE_CURSOR'] != '1')) {
      return null;
    }
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'width': bitmap.width,
        'height': bitmap.height,
        'hotspotX': bitmap.hotspotX,
        'hotspotY': bitmap.hotspotY,
        'rgba': bitmap.rgba,
      });
      return id == null ? null : RdpWindowsCursor._(id);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _send(String method) async {
    try {
      await _channel.invokeMethod<void>(method, _id);
    } on PlatformException {
      // A cursor can outlive its HWND while the view is shutting down.
    } on MissingPluginException {
      // The window also releases cursors when the engine closes.
    }
  }

  void release() => unawaited(_send('release'));

  @override
  String get debugDescription => 'Remote desktop cursor';

  @override
  MouseCursorSession createSession(int device) =>
      _RdpCursorSession(this, device);
}

class _RdpCursorSession extends MouseCursorSession {
  _RdpCursorSession(this.nativeCursor, int device)
    : super(nativeCursor, device);

  final RdpWindowsCursor nativeCursor;

  @override
  Future<void> activate() => nativeCursor._send('activate');

  @override
  void dispose() => unawaited(nativeCursor._send('deactivate'));
}
