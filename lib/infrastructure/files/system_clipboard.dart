import 'package:flutter/services.dart';

import '../../domain/rdp/rdp_clipboard.dart';

class SystemClipboard implements LocalClipboard {
  SystemClipboard();
  static const _channel = MethodChannel('pagashell/clipboard');
  ClipboardSnapshot? _cached;

  @override
  Future<ClipboardSnapshot> read() async {
    final data = await _channel.invokeMapMethod<String, Object?>('read', {
      'afterChangeId': _cached?.changeId,
    });
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
