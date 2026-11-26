import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/rdp/rdp_clipboard.dart';

class SystemClipboard implements ObservableLocalClipboard {
  SystemClipboard();
  static const _channel = MethodChannel('pagashell/clipboard');
  static final _windowsChanges = const EventChannel(
    'pagashell/clipboardChanges',
  ).receiveBroadcastStream().map<void>((_) {});
  ClipboardSnapshot? _cached;

  @override
  Stream<void>? get changes => Platform.isWindows ? _windowsChanges : null;

  Future<Map<String, Object?>?> _readNative() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _channel.invokeMapMethod<String, Object?>('read', {
          'afterChangeId': _cached?.changeId,
        });
      } on PlatformException catch (error) {
        if (error.code != 'clipboard_busy' || attempt == 3) rethrow;
        // The writer may still have the clipboard open when Windows notifies us.
        await Future<void>.delayed(Duration(milliseconds: 25 << attempt));
      }
    }
  }

  @override
  Future<ClipboardSnapshot> read() async {
    final data = await _readNative();
    if (data == null) {
      if (_cached != null) return _cached!;
      throw StateError('Clipboard unavailable');
    }
    return _cached = ClipboardSnapshot(
      data['changeId']! as String,
      ClipboardContent(
        text: data['text'] as String?,
        files: List<String>.from(data['files']! as List<Object?>),
      ),
    );
  }

  @override
  Future<ClipboardSnapshot?> write(
    ClipboardContent content, {
    required String expectedChangeId,
  }) async {
    final changeId = await _channel.invokeMethod<String>('write', {
      'expectedChangeId': expectedChangeId,
      'text': content.text,
      'files': content.files,
    });
    return changeId == null
        ? null
        : (_cached = ClipboardSnapshot(changeId, content));
  }
}
