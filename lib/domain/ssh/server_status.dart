/// 独立 SSH 命令通道采样，不使用交互终端的输入或输出。
abstract interface class ServerStatusSource {
  Future<ServerStatusSample> readServerStatus();
}

class ServerStatusSample {
  const ServerStatusSample({
    this.system = 'Linux',
    this.systemRelease,
    this.measuredCpuFraction,
    this.cpuCores = const {},
    required this.uptimeSeconds,
    required this.cpuTotal,
    required this.cpuIdle,
    required this.memoryTotal,
    required this.memoryAvailable,
    required this.filesystems,
    required this.network,
    required this.disks,
  });

  final String system;
  final String? systemRelease;
  String get systemLabel => systemRelease ?? system;

  /// macOS top 的第二次（1 秒间隔）采样已给出增量 CPU 利用率。
  final double? measuredCpuFraction;
  final double uptimeSeconds;
  final int cpuTotal;
  final int cpuIdle;
  final Map<int, CpuCounters> cpuCores;
  final int memoryTotal;
  final int memoryAvailable;
  final List<FilesystemUsage> filesystems;
  final Map<String, IoCounters> network;
  final Map<String, IoCounters> disks;

  int get memoryUsed => (memoryTotal - memoryAvailable).clamp(0, memoryTotal);
  double get memoryFraction => memoryTotal > 0 ? memoryUsed / memoryTotal : 0;
}

/// 每个逻辑核心的累计时钟计数，按核心编号匹配相邻采样。
class CpuCounters {
  const CpuCounters(this.total, this.idle);

  final int total;
  final int idle;
}

class FilesystemUsage {
  const FilesystemUsage({
    required this.mount,
    this.name,
    required this.total,
    required this.used,
    required this.available,
  });

  final String mount;
  final String? name;
  final int total;
  final int used;
  final int available;

  // df 的占用比例排除文件系统保留块。
  double get fraction => used + available > 0
      ? (used / (used + available)).clamp(0, 1).toDouble()
      : 0;
}

class IoCounters {
  const IoCounters(this.read, this.write);
  final int read;
  final int write;
}

class IoRate {
  const IoRate(this.readPerSecond, this.writePerSecond);
  final double? readPerSecond;
  final double? writePerSecond;
}

/// CPU 和吞吐速率由两次采样的增量计算，首次采样或计数器重置时为空。
class ServerStatus {
  ServerStatus.fromSamples(this.sample, ServerStatusSample? previous) {
    final elapsed = previous == null
        ? 0.0
        : sample.uptimeSeconds - previous.uptimeSeconds;
    cpuFraction =
        sample.measuredCpuFraction ??
        _cpuFraction(
          CpuCounters(sample.cpuTotal, sample.cpuIdle),
          previous == null
              ? null
              : CpuCounters(previous.cpuTotal, previous.cpuIdle),
          elapsed,
        );
    final coreIds = sample.cpuCores.keys.toList()..sort();
    cpuCores = {
      for (final id in coreIds)
        id: _cpuFraction(sample.cpuCores[id]!, previous?.cpuCores[id], elapsed),
    };
    network = _rates(sample.network, previous?.network, elapsed);
    disks = _rates(sample.disks, previous?.disks, elapsed);
  }

  final ServerStatusSample sample;
  late final double? cpuFraction;
  late final Map<int, double?> cpuCores;
  late final Map<String, IoRate> network;
  late final Map<String, IoRate> disks;

  static double? _cpuFraction(
    CpuCounters current,
    CpuCounters? previous,
    double elapsed,
  ) {
    if (previous == null || elapsed <= 0) return null;
    final total = current.total - previous.total;
    final idle = current.idle - previous.idle;
    if (total <= 0 || idle < 0 || idle > total) return null;
    return ((total - idle) / total).clamp(0, 1).toDouble();
  }

  static Map<String, IoRate> _rates(
    Map<String, IoCounters> current,
    Map<String, IoCounters>? previous,
    double elapsed,
  ) => {
    for (final entry in current.entries)
      entry.key: IoRate(
        _rate(entry.value.read, previous?[entry.key]?.read, elapsed),
        _rate(entry.value.write, previous?[entry.key]?.write, elapsed),
      ),
  };

  static double? _rate(int current, int? previous, double elapsed) =>
      previous != null && current >= previous && elapsed > 0
      ? (current - previous) / elapsed
      : null;
}
