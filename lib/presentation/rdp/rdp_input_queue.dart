import 'dart:async';
import 'dart:collection';

import '../../domain/ssh/ssh_engine.dart';

/// Keep key/button edges in order while replacing obsolete unsent mouse moves.
class RdpInputQueue {
  RdpInputQueue({required this.onError});
  final void Function(Object) onError;
  final _pending = Queue<_Input>();
  bool _sending = false;
  bool _failed = false;

  void add(Future<void> Function() action, {bool movement = false}) {
    if (_failed) return;
    if (movement && _pending.isNotEmpty && _pending.last.movement) {
      _pending.last.action = action;
      return;
    }
    if (_pending.length >= 256) {
      _fail(const SshEngineException('RDP 输入队列超时'));
      return;
    }
    _pending.add(_Input(action, movement));
    if (!_sending) unawaited(_drain());
  }

  Future<void> _drain() async {
    _sending = true;
    try {
      while (_pending.isNotEmpty && !_failed) {
        await _pending.removeFirst().action();
      }
    } on Object catch (error) {
      _fail(error);
    } finally {
      _sending = false;
    }
  }

  void _fail(Object error) {
    if (_failed) return;
    _failed = true;
    _pending.clear();
    onError(error);
  }
}

class _Input {
  _Input(this.action, this.movement);
  Future<void> Function() action;
  final bool movement;
}
