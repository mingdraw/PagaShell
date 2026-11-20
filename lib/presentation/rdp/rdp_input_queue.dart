import 'dart:async';
import 'dart:collection';

import '../../domain/ssh/ssh_engine.dart';

/// Keep key/button edges in order while coalescing obsolete unsent moves and wheel bursts.
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
    _enqueue(_Input(action, movement: movement));
  }

  void addWheel(int dx, int dy, Future<void> Function(int, int) send) {
    if (_failed || (dx == 0 && dy == 0)) return;
    final wheel = _pending.isEmpty ? null : _pending.last.wheel;
    if (wheel != null) {
      wheel
        ..dx += dx
        ..dy += dy
        ..send = send;
    } else {
      final burst = _Wheel(dx, dy, send);
      _enqueue(_Input(burst.run, wheel: burst));
    }
  }

  void _enqueue(_Input input) {
    if (_pending.length >= 256) {
      _fail(const SshEngineException('RDP 输入队列超时'));
      return;
    }
    _pending.add(input);
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
    cancel();
    onError(error);
  }

  void cancel() {
    _failed = true;
    _pending.clear();
  }
}

class _Input {
  _Input(this.action, {this.movement = false, this.wheel});
  Future<void> Function() action;
  final bool movement;
  final _Wheel? wheel;
}

class _Wheel {
  _Wheel(this.dx, this.dy, this.send);
  int dx;
  int dy;
  Future<void> Function(int, int) send;

  Future<void> run() => send(dx, dy);
}
