import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class RdpWindowsKeyboard {
  RdpWindowsKeyboard({required this.onKey, required this.onLost});

  static const _channel = MethodChannel('pagashell/rdpKeyboard');
  static int _nextId = 0;
  static RdpWindowsKeyboard? _current;
  final void Function(int scan, bool down) onKey;
  final VoidCallback onLost;
  int? _id;

  void setEnabled(bool enabled) {
    if (!enabled) {
      final id = _id;
      if (id == null) return;
      _id = null;
      if (identical(_current, this)) _current = null;
      unawaited(_stop(id));
      return;
    }
    if (_id != null || defaultTargetPlatform != TargetPlatform.windows) return;
    _nextId = (_nextId % 0x7fffffff) + 1;
    final id = _id = _nextId;
    _current = this;
    _channel.setMethodCallHandler(_receive);
    unawaited(_start(id));
  }

  static Future<void> _receive(MethodCall call) async {
    final owner = _current;
    if (owner == null) return;
    final data = call.arguments;
    if (call.method == 'captureLost' && data == owner._id) {
      owner._lost();
    } else if (call.method == 'captureKey' &&
        data is List<Object?> &&
        data.length == 3 &&
        data[0] == owner._id &&
        data[1] is int &&
        data[2] is bool) {
      final scan = data[1]! as int;
      if (scan > 0 && scan <= 0x1ff) owner.onKey(scan, data[2]! as bool);
    }
  }

  Future<void> _start(int id) async {
    try {
      if (await _channel.invokeMethod<bool>('captureStart', id) == true) return;
    } on PlatformException {
      // Normal Flutter keyboard handling is still available.
    } on MissingPluginException {
      // The runner may not implement native capture.
    }
    if (_id == id) _lost();
  }

  void _lost() {
    _id = null;
    if (identical(_current, this)) _current = null;
    onLost();
  }

  static Future<void> _stop(int id) async {
    try {
      await _channel.invokeMethod<void>('captureStop', id);
    } on PlatformException {
      // The runner also releases capture on native focus loss and shutdown.
    } on MissingPluginException {
      // There is nothing to release.
    }
  }
}
