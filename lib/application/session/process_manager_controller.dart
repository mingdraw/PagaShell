import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 采样与结束操作使用后台连接；隐藏面板时停止采样，保留排序、筛选和上次数据。
class ProcessManagerController extends GetxController {
  ProcessManagerController({
    required this.source,
    this.interval = const Duration(seconds: 3),
  });

  final ProcessManagerSource source;
  final Duration interval;
  final RxList<ProcessUsage> processes = <ProcessUsage>[].obs;
  final Rx<ProcessSort> sort = ProcessSort.memory.obs;
  final RxString query = ''.obs;
  final RxBool loading = false.obs;
  final RxnString error = RxnString();
  final RxnString actionError = RxnString();
  final RxnString notice = RxnString();
  final Rxn<DateTime> updatedAt = Rxn<DateTime>();
  final RxSet<String> terminating = <String>{}.obs;
  ProcessSnapshot? _previous;
  Timer? _timer;
  bool _enabled = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _refreshAgain = false;
  int _generation = 0;

  List<ProcessUsage> get visibleProcesses {
    final term = query.value.trim().toLowerCase();
    final order = sort.value;
    final result = processes.where((usage) {
      final p = usage.process;
      return term.isEmpty ||
          p.name.toLowerCase().contains(term) ||
          p.user.toLowerCase().contains(term) ||
          '${p.pid}'.contains(term);
    }).toList();
    result.sort((a, b) {
      final compared = order == ProcessSort.cpu
          ? b.cpuPercent.compareTo(a.cpuPercent)
          : b.process.memoryBytes.compareTo(a.process.memoryBytes);
      return compared != 0 ? compared : a.process.pid.compareTo(b.process.pid);
    });
    return result;
  }

  void setEnabled(bool enabled) {
    if (_disposed || enabled == _enabled) return;
    _enabled = enabled;
    _generation++;
    _previous = null;
    _timer?.cancel();
    loading.value = false;
    if (enabled) unawaited(refreshProcesses());
  }

  Future<void> refreshProcesses() async {
    if (_disposed || !_enabled) return;
    if (_inFlight) {
      _refreshAgain = true;
      return;
    }
    _timer?.cancel();
    _inFlight = true;
    _refreshAgain = false;
    final generation = _generation;
    loading.value = true;
    try {
      final snapshot = await source.readProcesses();
      if (_disposed || !_enabled || generation != _generation) return;
      processes.value = ProcessUsage.fromSamples(snapshot, _previous);
      _previous = snapshot;
      updatedAt.value = DateTime.now();
      error.value = null;
    } on Object catch (e) {
      if (_disposed || !_enabled || generation != _generation) return;
      error.value = e is SshEngineException ? e.message : '无法读取进程列表，请重试';
      _previous = null;
    } finally {
      _inFlight = false;
      if (!_disposed && _enabled) {
        loading.value = false;
        if (error.value != '进程管理仅支持 Linux 和 macOS') {
          _timer = Timer(
            _refreshAgain || generation != _generation
                ? Duration.zero
                : interval,
            () => unawaited(refreshProcesses()),
          );
        }
      }
    }
  }

  Future<ProcessDetails> readDetails(RemoteProcess process) async {
    if (_disposed || !_enabled) {
      throw const SshEngineException('进程管理连接已关闭');
    }
    final generation = _generation;
    final details = await source.readProcessDetails(process);
    if (_disposed || !_enabled || generation != _generation) {
      throw const SshEngineException('进程管理连接已关闭');
    }
    if (details.process.identity != process.identity) {
      throw const SshEngineException('进程已变化，请刷新后重试');
    }
    return details;
  }

  Future<bool> terminate(RemoteProcess process) async {
    if (_disposed ||
        !_enabled ||
        !process.canTerminate ||
        terminating.contains(process.identity)) {
      return false;
    }
    terminating.add(process.identity);
    actionError.value = null;
    notice.value = null;
    try {
      await source.terminateProcess(process);
      if (_disposed) return false;
      notice.value = '已发送结束请求';
      await refreshProcesses();
      return true;
    } on Object catch (e) {
      if (!_disposed) {
        actionError.value = e is SshEngineException ? e.message : '结束进程失败，请重试';
      }
      return false;
    } finally {
      if (!_disposed) terminating.remove(process.identity);
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
