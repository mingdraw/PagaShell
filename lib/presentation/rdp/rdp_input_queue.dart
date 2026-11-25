import 'dart:async';
import 'dart:collection';

import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/ssh_engine.dart';

/// Keep key/button edges in order while coalescing obsolete unsent moves and wheel bursts.
class RdpInputQueue {
  RdpInputQueue({required this.onError, required this.sendBatch});
  final void Function(Object) onError;
  final Future<void> Function(List<RdpInputEvent>) sendBatch;
  static const maxBatchSize = 32;
  final _pending = Queue<_Input>();
  bool _sending = false;
  bool _failed = false;

  // Actions are barriers (e.g. synchronize the clipboard before Ctrl+V).
  void add(Future<void> Function() action) => _enqueue(_Input.action(action));

  void addEvent(RdpInputEvent event) => _enqueue(_Input.event(event));

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
      _enqueue(_Input.action(burst.run, wheel: burst));
    }
  }

  void _enqueue(_Input input) {
    if (_failed) return;
    if (input.movement && _pending.isNotEmpty && _pending.last.movement) {
      _pending.removeLast();
      _pending.addLast(input);
      return;
    }
    if (_pending.length >= 256) {
      _fail(const SshEngineException('RDP 输入队列超时'));
      return;
    }
    _pending.add(input);
    if (_sending) return;
    _sending = true;
    if (input.event != null) {
      // Group edges produced by the same callback without adding a timer delay.
      scheduleMicrotask(() => unawaited(_drain()));
    } else {
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty && !_failed) {
        final next = _pending.removeFirst();
        if (next.event case final event?) {
          final events = [event];
          while (_pending.isNotEmpty && events.length < maxBatchSize) {
            final pending = _pending.first.event;
            if (pending == null) break;
            events.add(pending);
            _pending.removeFirst();
          }
          await sendBatch(events);
        } else {
          await next.action!();
        }
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
  _Input.action(this.action, {this.wheel}) : event = null;
  _Input.event(this.event) : action = null, wheel = null;
  final Future<void> Function()? action;
  final RdpInputEvent? event;
  final _Wheel? wheel;
  bool get movement => switch (event) {
    RdpPointerInput(flags: 0x0800, wheel: 0) => true,
    _ => false,
  };
}

class _Wheel {
  _Wheel(this.dx, this.dy, this.send);
  int dx;
  int dy;
  Future<void> Function(int, int) send;

  Future<void> run() => send(dx, dy);
}
