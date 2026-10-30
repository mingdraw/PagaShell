import 'dart:async';

import 'package:get/get.dart';

import '../../domain/rdp/rdp_clipboard.dart';
import '../../domain/ssh/ssh_engine.dart';

/// One owner per active desktop. Clipboard failures never fail the RDP session.
class RdpClipboardController {
  RdpClipboardController({
    required this.session,
    required this.local,
    required this.onError,
  }) {
    _events = session.clipboardEvents.listen(
      _receive,
      onError: (Object _) {
        progress.value = null;
        if (_active) onError('RDP 剪贴板已断开，请重新连接');
      },
    );
  }

  final RdpClipboardSession session;
  final LocalClipboard local;
  final void Function(String) onError;
  final progress = Rxn<RdpClipboardEvent>();
  late final StreamSubscription<RdpClipboardEvent> _events;
  Timer? _poll;
  ClipboardSnapshot? _last;
  bool _active = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _publishFailed = false;
  bool _initializing = false;
  RdpClipboardEvent? _pendingRemote;
  int _generation = 0;
  int _remoteSerial = 0;
  Future<void>? _activation;
  Future<void>? _syncing;

  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    final generation = ++_generation;
    _remoteSerial++;
    _initializing = active;
    _pendingRemote = null;
    _poll?.cancel();
    progress.value = null;
    // Serialize enable/disable: a slow activation cannot reactivate a closed tab.
    _activation = (_activation ?? Future<void>.value()).then((_) async {
      try {
        await session.setClipboardActive(active);
        if (!_current(generation) || !active) return;
        await _syncing;
        if (!_current(generation)) return;
        _last = null;
        if (_foreground) {
          await syncLocal();
        } else {
          _last = await local.read();
        }
        if (!_current(generation)) return;
        _initializing = false;
        final pending = _pendingRemote;
        _pendingRemote = null;
        if (pending != null) _receive(pending);
        _startPolling();
      } on Object {
        if (_current(generation)) onError('无法访问本机剪贴板');
      }
    });
  }

  bool _current(int generation) =>
      !_disposed && _active && generation == _generation;

  /// Losing application focus must not cancel a remote copy still in flight.
  /// Pause local publishing while allowing its conditional local write to finish.
  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    _poll?.cancel();
    if (foreground && _active) unawaited(_resumeLocal());
  }

  Future<void> _resumeLocal() async {
    await _activation;
    await syncLocal();
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    if (!_active || !_foreground || _disposed) return;
    _poll = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(syncLocal()),
    );
  }

  Future<void> syncLocal({bool retryFailed = false}) {
    if (!_active || !_foreground || _disposed) return Future<void>.value();
    return _syncing ??= _sync(retryFailed: retryFailed)
        .whenComplete(() => _syncing = null);
  }

  /// A paste must re-read after any older poll, then follow its wire barrier.
  Future<bool> syncBeforePaste() async {
    await _activation;
    await _syncing;
    await syncLocal(retryFailed: true);
    return _active && _foreground && !_disposed && !_publishFailed;
  }

  Future<void> _sync({required bool retryFailed}) async {
    final generation = _generation;
    try {
      final snapshot = await local.read();
      if (!_current(generation) || !_foreground) return;
      if (snapshot.changeId == _last?.changeId &&
          (!retryFailed || !_publishFailed)) {
        return;
      }
      if (!_publishFailed &&
          _last != null &&
          snapshot.content.sameAs(_last!.content)) {
        _last = snapshot;
        return;
      }
      _remoteSerial++;
      _last = snapshot;
      progress.value = null;
      await session.updateClipboard(snapshot.content);
      _publishFailed = false;
    } on Object catch (error) {
      if (_current(generation)) {
        _publishFailed = true;
        onError(
          error is SshEngineException ? error.message : 'RDP 剪贴板同步失败，请重新复制',
        );
      }
    }
  }

  void _receive(RdpClipboardEvent event) {
    if (!_active || _disposed) return;
    if (_initializing) {
      _pendingRemote = event;
      return;
    }
    switch (event.kind) {
      case RdpClipboardEventKind.ready:
        progress.value = null;
      case RdpClipboardEventKind.receiving:
        _remoteSerial++;
        progress.value = event;
      case RdpClipboardEventKind.error:
        progress.value = null;
        onError(event.error ?? 'RDP 剪贴板传输失败，请重新复制');
      case RdpClipboardEventKind.text:
      case RdpClipboardEventKind.files:
        progress.value = null;
        unawaited(_applyRemote(event.content, ++_remoteSerial));
    }
  }

  Future<void> _applyRemote(ClipboardContent content, int serial) async {
    final generation = _generation;
    try {
      await _syncing;
      final current = await local.read();
      if (!_current(generation) || serial != _remoteSerial) return;
      if (_last != null && current.changeId != _last!.changeId) {
        // A new local copy wins over an older download/format response.
        await syncLocal();
        return;
      }
      final written = await local.write(
        content,
        expectedChangeId: current.changeId,
      );
      if (!_current(generation) || serial != _remoteSerial) return;
      if (written == null) {
        await syncLocal();
      } else {
        _last = written; // Do not send this remote update straight back.
        _publishFailed = false;
      }
    } on Object {
      if (_current(generation)) onError('无法写入本机剪贴板');
    }
  }

  Future<void> cancelTransfer() async {
    _remoteSerial++;
    progress.value = null;
    try {
      await session.cancelClipboardTransfer();
    } on Object {
      if (_active && !_disposed) onError('RDP 剪贴板传输失败，请重新复制');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    _generation++;
    _remoteSerial++;
    _poll?.cancel();
    unawaited(_events.cancel());
    unawaited(
      (_activation ?? Future<void>.value())
          .then((_) => session.setClipboardActive(false))
          .catchError((Object _) {}),
    );
    progress.close();
  }
}
