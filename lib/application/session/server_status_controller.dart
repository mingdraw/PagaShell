import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 每个页签独立持有；展开且处于活动页签时采样，不并发执行采集。
class ServerStatusController extends GetxController {
  ServerStatusController({
    required this.source,
    this.interval = const Duration(seconds: 3),
  });

  final ServerStatusSource source;
  final Duration interval;
  final Rxn<ServerStatus> status = Rxn<ServerStatus>();
  static const _historyLimit = 24;
  final history = <ServerStatus>[].obs;
  final RxnString error = RxnString();
  final Rxn<DateTime> updatedAt = Rxn<DateTime>();
  final RxBool loading = false.obs;
  ServerStatusSample? _previous;
  Timer? _timer;
  final autoRefreshPaused = false.obs;
  bool _enabled = false;
  bool _disposed = false;
  bool _inFlight = false;
  int _generation = 0;

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    _generation++;
    _timer?.cancel();
    _previous = null;
    loading.value = false;
    if (enabled) unawaited(refreshStatus(automatic: true));
  }

  void setAutoRefreshPaused(bool paused) {
    if (_disposed || autoRefreshPaused.value == paused) return;
    autoRefreshPaused.value = paused;
    _previous = null;
    _timer?.cancel();
    if (!paused) unawaited(refreshStatus(automatic: true));
  }

  Future<void> refreshStatus({bool automatic = false}) async {
    if (automatic && autoRefreshPaused.value) return;
    if (_disposed || !_enabled || _inFlight) return;
    _timer?.cancel();
    _inFlight = true;
    final elapsed = Stopwatch()..start();
    final generation = _generation;
    loading.value = true;
    try {
      final sample = await source.readServerStatus();
      if (_disposed ||
          !_enabled ||
          generation != _generation ||
          (automatic && autoRefreshPaused.value)) {
        return;
      }
      final next = ServerStatus.fromSamples(sample, _previous);
      if (history.length >= _historyLimit) history.removeAt(0);
      history.add(next);
      status.value = next;
      _previous = sample;
      updatedAt.value = DateTime.now();
      error.value = null;
    } on Object catch (e) {
      if (_disposed ||
          !_enabled ||
          generation != _generation ||
          (automatic && autoRefreshPaused.value)) {
        return;
      }
      error.value = e is SshEngineException ? e.message : '无法获取服务状态，请重试';
      _previous = null;
    } finally {
      _inFlight = false;
      if (!_disposed && _enabled) {
        loading.value = false;
        // 成功采集按启动时刻计时，macOS 的 1 秒 CPU 采样也纳入周期。
        final delay = error.value != null
            ? interval
            : Duration(
                milliseconds:
                    (interval.inMilliseconds - elapsed.elapsedMilliseconds)
                        .clamp(0, interval.inMilliseconds),
              );
        if (!autoRefreshPaused.value &&
            error.value != '服务状态仅支持 Linux 和 macOS') {
          _timer = Timer(
            generation == _generation ? delay : Duration.zero,
            () => unawaited(refreshStatus(automatic: true)),
          );
        }
      }
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.onClose();
  }
}
