import 'dart:async';
import 'dart:collection';

/// 限制同一 SSH 会话中同时打开的文件传输流，等待中的流可立即取消。
class TransferLimiter {
  TransferLimiter(this.limit) : assert(limit > 0);

  final int limit;
  final Queue<_Ticket> _waiting = Queue<_Ticket>();
  int _active = 0;
  bool _paused = false;
  bool _draining = false;

  void pause() => _paused = true;

  void resume() {
    _paused = false;
    _drain();
  }

  Stream<T> schedule<T>(
    Stream<T> Function() open, {
    void Function()? onQueued,
    void Function()? onStarted,
  }) {
    late final StreamController<T> output;
    StreamSubscription<T>? source;
    _Ticket? ticket;
    var cancelled = false;
    var sourceEnded = false;

    void release() {
      final current = ticket;
      if (current == null || current.released) return;
      current.released = true;
      if (current.active) {
        _active--;
      } else {
        _waiting.remove(current);
      }
      _drain();
    }

    void start() {
      if (cancelled) {
        release();
        return;
      }
      try {
        onStarted?.call();
        if (cancelled) {
          release();
          return;
        }
        // 此订阅由 output.onCancel 持有并等待取消，或由源流完成自动结束。
        // ignore: cancel_subscriptions
        final subscription = open().listen(
          (event) {
            if (!cancelled) output.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (!cancelled) output.addError(error, stack);
          },
          onDone: () {
            sourceEnded = true;
            source = null;
            release();
            if (!cancelled) unawaited(output.close());
          },
        );
        if (!sourceEnded) source = subscription;
      } on Object catch (error, stack) {
        release();
        if (!cancelled) {
          output.addError(error, stack);
          unawaited(output.close());
        }
      }
    }

    output = StreamController<T>(
      sync: true,
      onListen: () {
        final current = _Ticket(start);
        ticket = current;
        _waiting.addLast(current);
        if (_paused || _active >= limit) onQueued?.call();
        _drain();
      },
      onCancel: () async {
        cancelled = true;
        try {
          if (!sourceEnded) await source?.cancel();
        } finally {
          release();
        }
      },
    );
    return output.stream;
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (!_paused && _active < limit && _waiting.isNotEmpty) {
        final ticket = _waiting.removeFirst();
        if (ticket.released) continue;
        ticket.active = true;
        _active++;
        ticket.start();
      }
    } finally {
      _draining = false;
    }
  }
}

class _Ticket {
  _Ticket(this.start);

  final void Function() start;
  bool active = false;
  bool released = false;
}
