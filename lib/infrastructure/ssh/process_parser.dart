import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/ssh_engine.dart';

final _processRow = RegExp(
  r'^\s*(\d+)\s+(\S+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+'
  r'(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+?)\s*$',
);
final _whitespace = RegExp(r'\s+');
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');
final _detailsRow = RegExp(
  r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+'
  r'(\d+)\s+(\S+)\s+(-?\d+)\s+(\S+)\s+(\S+)\s+'
  r'(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+?)\s*$',
);

ProcessSnapshot parseProcesses(String output) {
  final lines = output.split('\n');
  final begin = lines.indexOf('PAGA_PROCESSES_V1');
  final end = lines.indexOf('PAGA_PROCESSES_END', begin + 1);
  if (begin < 0 || end < 0) _invalid();
  double? sampledAt;
  int? memoryTotal;
  var inTable = false;
  var sawRow = false;
  final processes = <RemoteProcess>[];
  final seen = <int>{};
  for (final line in lines.sublist(begin + 1, end)) {
    if (line == 'PROCESSES') {
      inTable = true;
      continue;
    }
    if (!inTable) {
      if (line.startsWith('TIME ')) {
        sampledAt = double.tryParse(line.substring(5));
      } else if (line.startsWith('MEMORY ')) {
        memoryTotal = int.tryParse(line.substring(7));
      } else if (line == 'UNSUPPORTED') {
        throw const SshEngineException('进程管理仅支持 Linux 和 macOS');
      }
      continue;
    }
    if (line.trim().isEmpty) continue;
    sawRow = true;
    final match = _processRow.firstMatch(line);
    if (match == null) continue; // 采样中退出的进程可能只留下不完整的行。
    final pid = int.tryParse(match[1]!);
    final cpu = double.tryParse(match[3]!);
    final memory = int.tryParse(match[4]!);
    final seconds = _cpuSeconds(match[5]!);
    if (pid == null ||
        pid < 1 ||
        cpu == null ||
        !cpu.isFinite ||
        cpu < 0 ||
        memory == null ||
        seconds == null ||
        !seen.add(pid)) {
      continue;
    }
    processes.add(
      RemoteProcess(
        pid: pid,
        user: match[2]!,
        name: match[7]!.replaceAll(_controlCharacters, '�'),
        startedAt: match[6]!.split(_whitespace).join(' '),
        cpuSeconds: seconds,
        cpuPercent: cpu,
        memoryBytes: memory * 1024,
      ),
    );
  }
  if (!inTable ||
      (sawRow && processes.isEmpty) ||
      sampledAt == null ||
      !sampledAt.isFinite ||
      sampledAt <= 0 ||
      memoryTotal == null ||
      memoryTotal <= 0) {
    _invalid();
  }
  return ProcessSnapshot(
    sampledAtSeconds: sampledAt,
    memoryTotal: memoryTotal,
    processes: List.unmodifiable(processes),
  );
}

ProcessDetails parseProcessDetails(String output, RemoteProcess expected) {
  const beginMarker = 'PAGA_PROCESS_DETAILS_V1\n';
  const pathMarker = '\nPAGA_PROCESS_PATH\x00';
  const endMarker = '\x00\nPAGA_PROCESS_DETAILS_END';
  final begin = output.indexOf(beginMarker);
  final pathStart = output.indexOf(pathMarker, begin + 1);
  final end = output.lastIndexOf(endMarker);
  if (begin < 0 ||
      pathStart < begin + beginMarker.length ||
      end < pathStart + pathMarker.length ||
      output.substring(end + endMarker.length).trim().isNotEmpty) {
    _invalid();
  }
  final match = _detailsRow.firstMatch(
    output.substring(begin + beginMarker.length, pathStart),
  );
  if (match == null) _invalid();
  final pid = int.tryParse(match[1]!);
  final parent = int.tryParse(match[2]!);
  final cpu = double.tryParse(match[4]!);
  final memoryPercent = double.tryParse(match[5]!);
  final memory = int.tryParse(match[6]!);
  final virtualMemory = int.tryParse(match[7]!);
  final nice = int.tryParse(match[9]!);
  final seconds = _cpuSeconds(match[11]!);
  if (pid == null ||
      pid < 1 ||
      parent == null ||
      cpu == null ||
      !cpu.isFinite ||
      cpu < 0 ||
      memoryPercent == null ||
      !memoryPercent.isFinite ||
      memoryPercent < 0 ||
      memory == null ||
      virtualMemory == null ||
      nice == null ||
      seconds == null) {
    _invalid();
  }
  final startedAt = match[12]!.split(_whitespace).join(' ');
  if (pid != expected.pid || startedAt != expected.startedAt) {
    throw const SshEngineException('进程已变化，请刷新后重试');
  }
  final path = output.substring(pathStart + pathMarker.length, end);
  if (path.contains('\x00')) _invalid();
  return ProcessDetails(
    process: RemoteProcess(
      pid: pid,
      user: match[3]!,
      name: match[13]!.replaceAll(_controlCharacters, '�'),
      startedAt: startedAt,
      cpuSeconds: seconds,
      cpuPercent: cpu,
      memoryBytes: memory * 1024,
    ),
    parentPid: parent,
    state: match[8]!,
    nice: nice,
    elapsed: match[10]!,
    memoryPercent: memoryPercent,
    virtualMemoryBytes: virtualMemory * 1024,
    executablePath: path.startsWith('/')
        ? path.replaceAll(_controlCharacters, '�')
        : null,
  );
}

double? _cpuSeconds(String value) {
  final days = value.split('-');
  if (days.length > 2) return null;
  final day = days.length == 2 ? int.tryParse(days.first) : 0;
  final parts = days.last.split(':');
  if (day == null || day < 0 || parts.length < 2 || parts.length > 3) {
    return null;
  }
  var seconds = day * 86400.0;
  for (var index = 0; index < parts.length; index++) {
    final number = double.tryParse(parts[index]);
    if (number == null || !number.isFinite || number < 0) return null;
    final weight = parts.length - index - 1;
    seconds +=
        number *
        (weight == 2
            ? 3600
            : weight == 1
            ? 60
            : 1);
  }
  return seconds;
}

Never _invalid() => throw const SshEngineException('进程数据格式无效');
