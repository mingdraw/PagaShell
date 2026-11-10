import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/ssh_engine.dart';

enum NetworkPortsFilter { all, tcp, udp }

typedef NetworkPortTerminationFailure = ({int pid, String message});

class NetworkPortsController extends GetxController {
  NetworkPortsController({
    required this.source,
    this.interval = const Duration(seconds: 3),
    this.timeout = networkPortsQueryTimeout,
  });
  final NetworkPortsSource source;
  final Duration interval;
  final Duration timeout;
  final ports = <ListeningNetworkPort>[].obs;
  final query = ''.obs;
  final filter = NetworkPortsFilter.all.obs;
  final loading = false.obs;
  final error = RxnString();
  final actionError = RxnString();
  final notice = RxnString();
  final actionFailures = <NetworkPortTerminationFailure>[].obs;
  final preparing = <int>{}.obs;
  final terminating = <int>{}.obs;
  final limited = false.obs;
  final updatedAt = Rxn<DateTime>();
  Timer? _timer;
  bool _enabled = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _refreshAgain = false;
  int _generation = 0;

  bool get canTerminate => source is ProcessManagerSource;

  bool canTerminateProcess(NetworkPortProcess process) =>
      canTerminate && process.pid > 1 && process.name.isNotEmpty;

  List<ListeningNetworkPort> _samePort(
    Iterable<ListeningNetworkPort> entries,
    ListeningNetworkPort port,
  ) => entries
      .where((p) => p.protocol == port.protocol && p.port == port.port)
      .toList();

  bool canTerminatePort(ListeningNetworkPort port) {
    final group = _samePort(ports, port);
    if (!canTerminate) return false;
    try {
      _owners(group);
      return true;
    } on SshEngineException {
      return false;
    }
  }

  Map<int, String> _owners(List<ListeningNetworkPort> group) {
    if (group.isEmpty) {
      throw const SshEngineException('端口对应的进程已变化，请刷新后重试');
    }
    if (group.any(
      (p) =>
          p.processes.isEmpty ||
          p.processes.any((owner) => !canTerminateProcess(owner)),
    )) {
      throw const SshEngineException('无法核对此端口的全部进程，请刷新后重试');
    }
    final owners = <int, String>{};
    for (final owner in group.expand((p) => p.processes)) {
      if (owners.containsKey(owner.pid) && owners[owner.pid] != owner.name) {
        throw const SshEngineException('端口对应的进程已变化，请刷新后重试');
      }
      owners[owner.pid] = owner.name;
    }
    return owners;
  }

  List<ListeningNetworkPort> get visiblePorts {
    final term = query.value.trim().toLowerCase();
    final selected = switch (filter.value) {
      NetworkPortsFilter.all => null,
      NetworkPortsFilter.tcp => NetworkPortProtocol.tcp,
      NetworkPortsFilter.udp => NetworkPortProtocol.udp,
    };
    return ports
        .where(
          (p) =>
              (selected == null || p.protocol == selected) && p.matches(term),
        )
        .toList(growable: false);
  }

  void setEnabled(bool enabled) {
    if (_disposed || enabled == _enabled) return;
    _enabled = enabled;
    _generation++;
    _timer?.cancel();
    loading.value = false;
    if (enabled) unawaited(refreshPorts());
  }

  Future<void> refreshPorts() async {
    if (_disposed || !_enabled) return;
    if (_inFlight) {
      _refreshAgain = true;
      return;
    }
    _inFlight = true;
    _refreshAgain = false;
    _timer?.cancel();
    final generation = _generation;
    loading.value = true;
    try {
      final sample = await source.readNetworkPorts().timeout(timeout);
      if (_disposed || !_enabled || generation != _generation) return;
      ports.value = sample.ports;
      limited.value = sample.limited;
      updatedAt.value = DateTime.now();
      error.value = null;
    } on Object catch (e) {
      if (_disposed || !_enabled || generation != _generation) return;
      error.value = e is TimeoutException
          ? '网络端口查询超时，请重试'
          : e is SshEngineException
          ? e.message
          : '无法读取网络端口，请重试';
    } finally {
      _inFlight = false;
      if (!_disposed && _enabled) {
        loading.value = false;
        if (error.value != '网络端口仅支持 Linux 和 macOS' &&
            error.value != '未找到端口采集工具，请安装 ss 或 lsof') {
          _timer = Timer(
            _refreshAgain || generation != _generation
                ? Duration.zero
                : interval,
            () => unawaited(refreshPorts()),
          );
        }
      }
    }
  }

  /// 仅在点击结束时读取进程身份；不在端口轮询中遍历进程。
  Future<List<RemoteProcess>?> prepareTermination(
    ListeningNetworkPort port,
  ) async {
    if (_disposed || !_enabled || !canTerminatePort(port)) {
      return null;
    }
    final displayed = _owners(_samePort(ports, port));
    if (displayed.keys.any(
      (pid) => preparing.contains(pid) || terminating.contains(pid),
    )) {
      return null;
    }
    final generation = _generation;
    preparing.addAll(displayed.keys);
    actionError.value = null;
    actionFailures.clear();
    notice.value = null;
    try {
      final processes = await (() async {
        final snapshot = await (source as ProcessManagerSource).readProcesses();
        final targets = <RemoteProcess>[];
        for (final pid in displayed.keys) {
          final matches = snapshot.processes
              .where((p) => p.pid == pid)
              .toList();
          if (matches.length != 1 ||
              !matches.single.canTerminate ||
              matches.single.name.trim().isEmpty ||
              matches.single.startedAt.isEmpty) {
            throw const SshEngineException('端口对应的进程已变化，请刷新后重试');
          }
          targets.add(matches.single);
        }
        // 先读取启动时间，再核对端口归属；执行 TERM 时原生层再次核对启动时间。
        final current = await source.readNetworkPorts();
        final owners = _owners(_samePort(current.ports, port));
        if (owners.length != displayed.length ||
            displayed.entries.any((e) => owners[e.key] != e.value)) {
          throw const SshEngineException('端口对应的进程已变化，请刷新后重试');
        }
        targets.sort((a, b) => a.pid.compareTo(b.pid));
        return List<RemoteProcess>.unmodifiable(targets);
      })().timeout(timeout);
      if (_disposed || !_enabled || generation != _generation) return null;
      return processes;
    } on Object catch (e) {
      if (!_disposed && _enabled && generation == _generation) {
        actionError.value = e is TimeoutException
            ? '核对端口进程超时，请重试'
            : e is SshEngineException
            ? e.message
            : '无法核对端口对应的进程，请重试';
      }
      return null;
    } finally {
      if (!_disposed) preparing.removeAll(displayed.keys);
    }
  }

  Future<bool> terminate(
    ListeningNetworkPort port,
    List<RemoteProcess> processes,
  ) async {
    final targets = {for (final process in processes) process.pid: process};
    if (_disposed ||
        !_enabled ||
        !canTerminate ||
        targets.isEmpty ||
        targets.length != processes.length ||
        processes.any(
          (p) =>
              !p.canTerminate ||
              preparing.contains(p.pid) ||
              terminating.contains(p.pid),
        )) {
      return false;
    }
    terminating.addAll(targets.keys);
    actionError.value = null;
    actionFailures.clear();
    notice.value = null;
    try {
      final generation = _generation;
      final current = await source.readNetworkPorts().timeout(timeout);
      final owners = _owners(_samePort(current.ports, port));
      if (_disposed || !_enabled || generation != _generation) return false;
      if (owners.length != targets.length ||
          owners.keys.any((pid) => !targets.containsKey(pid))) {
        throw const SshEngineException('端口对应的进程已变化，请刷新后重试');
      }
      var sent = 0;
      for (final process in processes) {
        if (_disposed) return false;
        try {
          await (source as ProcessManagerSource).terminateProcess(process);
          sent++;
        } on Object catch (e) {
          if (!_disposed) {
            actionFailures.add((
              pid: process.pid,
              message: e is SshEngineException ? e.message : '结束进程失败，请重试',
            ));
          }
        }
      }
      if (_disposed) return false;
      if (actionFailures.isEmpty) {
        notice.value = '已向全部关联进程发送结束请求';
      } else {
        actionError.value = sent > 0 ? '部分进程未能结束，请查看失败原因' : '未能结束端口关联的进程';
      }
      await refreshPorts();
      return actionFailures.isEmpty;
    } on Object catch (e) {
      if (!_disposed) {
        actionError.value = e is SshEngineException ? e.message : '结束进程失败，请重试';
      }
      return false;
    } finally {
      if (!_disposed) terminating.removeAll(targets.keys);
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
