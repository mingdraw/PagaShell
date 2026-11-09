/// 后台 SSH 连接的可选能力；所有操作使用无 PTY 的独立命令通道。
abstract interface class ProcessManagerSource {
  Future<ProcessSnapshot> readProcesses();
  Future<ProcessDetails> readProcessDetails(RemoteProcess process);
  Future<void> terminateProcess(RemoteProcess process);
}

class RemoteProcess {
  const RemoteProcess({
    required this.pid,
    required this.user,
    required this.name,
    required this.startedAt,
    required this.cpuSeconds,
    required this.cpuPercent,
    required this.memoryBytes,
  });

  final int pid;
  final String user;
  final String name;

  /// LC_ALL=C 下的 ps lstart，终止前再次核对，避免对已复用的 PID 发信号。
  final String startedAt;
  final double cpuSeconds;
  final double cpuPercent;
  final int memoryBytes;

  String get identity => '$pid:$startedAt';
  bool get canTerminate => pid > 1;
}

/// 仅在用户打开详情时读取，不参与列表定时采样。
class ProcessDetails {
  const ProcessDetails({
    required this.process,
    required this.parentPid,
    required this.state,
    required this.nice,
    required this.elapsed,
    required this.memoryPercent,
    required this.virtualMemoryBytes,
    this.executablePath,
  });

  final RemoteProcess process;
  final int parentPid;
  final String state;
  final int nice;
  final String elapsed;
  final double memoryPercent;
  final int virtualMemoryBytes;
  final String? executablePath;
}

class ProcessSnapshot {
  const ProcessSnapshot({
    required this.sampledAtSeconds,
    required this.memoryTotal,
    required this.processes,
  });

  final double sampledAtSeconds;
  final int memoryTotal;
  final List<RemoteProcess> processes;
}

class ProcessUsage {
  const ProcessUsage({
    required this.process,
    required this.cpuPercent,
    required this.memoryPercent,
  });

  final RemoteProcess process;

  /// 100% 表示一个逻辑核心；多线程进程可以超过 100%。
  final double cpuPercent;
  final double memoryPercent;

  static List<ProcessUsage> fromSamples(
    ProcessSnapshot sample,
    ProcessSnapshot? previous,
  ) {
    final elapsed = previous == null
        ? 0.0
        : sample.sampledAtSeconds - previous.sampledAtSeconds;
    final old = {
      for (final p in previous?.processes ?? <RemoteProcess>[]) p.identity: p,
    };
    return [
      for (final process in sample.processes)
        ProcessUsage(
          process: process,
          cpuPercent:
              elapsed > 0 &&
                  old[process.identity] != null &&
                  process.cpuSeconds >= old[process.identity]!.cpuSeconds
              ? (process.cpuSeconds - old[process.identity]!.cpuSeconds) /
                    elapsed *
                    100
              : process.cpuPercent,
          memoryPercent: sample.memoryTotal > 0
              ? process.memoryBytes / sample.memoryTotal * 100
              : 0,
        ),
    ];
  }
}

enum ProcessSort { cpu, memory }
