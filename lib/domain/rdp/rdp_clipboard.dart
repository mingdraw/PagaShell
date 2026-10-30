import 'rdp_engine.dart';

class ClipboardContent {
  // Keep the public argument name while normalizing file representations.
  // ignore: prefer_initializing_formals
  const ClipboardContent({String? text, this.files = const []}) : _text = text;
  final String? _text;
  final List<String> files;

  /// File lists take precedence over a textual representation of their paths.
  String? get text => files.isEmpty ? _text : null;

  bool sameAs(ClipboardContent other) =>
      text == other.text &&
      files.length == other.files.length &&
      Iterable<int>.generate(files.length)
          .every((i) => files[i] == other.files[i]);
}

class ClipboardSnapshot {
  const ClipboardSnapshot(this.changeId, this.content);
  final String changeId;
  final ClipboardContent content;
}

abstract interface class LocalClipboard {
  Future<ClipboardSnapshot> read();

  /// Null if another app changed the clipboard before this conditional write.
  Future<ClipboardSnapshot?> write(
    ClipboardContent content, {
    required String expectedChangeId,
  });
}

enum RdpClipboardEventKind { ready, text, files, receiving, error }

class RdpClipboardEvent {
  const RdpClipboardEvent({
    required this.kind,
    this.content = const ClipboardContent(),
    this.transferred = 0,
    this.total = 0,
    this.error,
  });
  final RdpClipboardEventKind kind;
  final ClipboardContent content;
  final int transferred;
  final int total;
  final String? error;
}

/// Optional RDP capability. VNC and ordinary input-only sessions do not expose it.
abstract interface class RdpClipboardSession implements RdpEngineSession {
  Stream<RdpClipboardEvent> get clipboardEvents;
  Future<void> setClipboardActive(bool active);
  Future<void> updateClipboard(ClipboardContent content);
  Future<void> cancelClipboardTransfer();
}
