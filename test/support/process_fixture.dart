import 'package:pagashell/domain/ssh/process_manager.dart';

RemoteProcess remoteProcess({
  int pid = 42,
  String name = '/usr/bin/worker',
  String user = 'rocky',
  String startedAt = 'Fri Nov 6 14:20:00 2026',
  double seconds = 10,
  double cpu = 30,
  int memory = 104857600,
}) => RemoteProcess(
  pid: pid,
  name: name,
  user: user,
  startedAt: startedAt,
  cpuSeconds: seconds,
  cpuPercent: cpu,
  memoryBytes: memory,
);

ProcessSnapshot processSnapshot({
  double time = 1000,
  List<RemoteProcess>? processes,
}) => ProcessSnapshot(
  sampledAtSeconds: time,
  memoryTotal: 1024 * 1024 * 1024,
  processes:
      processes ??
      [
        remoteProcess(pid: 42, name: '/usr/bin/cpu-worker', cpu: 150),
        remoteProcess(
          pid: 81,
          name: '/Applications/Memory Worker',
          cpu: 5,
          memory: 536870912,
        ),
        remoteProcess(
          pid: 1,
          name: '/sbin/init',
          user: 'root',
          cpu: 0,
          memory: 102400,
        ),
      ],
);

ProcessDetails processDetails({
  RemoteProcess? process,
  String? path = '/usr/local/libexec/cpu-worker',
}) => ProcessDetails(
  process: process ?? remoteProcess(),
  parentPid: 12,
  state: 'S+',
  nice: 0,
  elapsed: '1-02:03:04',
  memoryPercent: 9.8,
  virtualMemoryBytes: 2147483648,
  executablePath: path,
);
