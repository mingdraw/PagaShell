import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 解析固定脚本的分段输出；Linux 读取内核计数，macOS 使用 C 语言环境。
ServerStatusSample parseServerStatus(String output) {
  final sections = <String, List<String>>{};
  String? section;
  var ended = false;
  for (final line in output.split('\n')) {
    final text = line.trim();
    if (text.startsWith('PAGASHELL_STATUS_')) {
      section = text.substring('PAGASHELL_STATUS_'.length);
      if (section == 'END') {
        ended = true;
        break;
      }
      sections[section] = [];
    } else if (section != null && text.isNotEmpty) {
      sections[section]!.add(text);
    }
  }
  final os = sections['OS']?.firstOrNull;
  if (os != null && os != 'Linux' && os != 'Darwin') {
    throw const SshEngineException('服务状态仅支持 Linux 和 macOS');
  }
  try {
    if (!ended || os == null) throw const FormatException('incomplete sample');
    if (os == 'Darwin') return _parseMacStatus(sections);
    final uptime = double.parse(_fields(sections['UPTIME']!.single).first);
    final cpu = _fields(sections['CPU']!.first);
    // guest/guest_nice 已包含在 user/nice 中，不能重复计入。
    final ticks = cpu.skip(1).take(8).map(int.parse).toList();
    if (cpu.first != 'cpu' || ticks.length < 4 || uptime <= 0) {
      throw const FormatException('invalid cpu counters');
    }
    final cpuCores = <int, CpuCounters>{};
    for (final line in sections['CPU']!.skip(1)) {
      final fields = _fields(line);
      final id = RegExp(r'^cpu(\d+)$').firstMatch(fields.first);
      if (id == null) continue;
      final coreTicks = fields.skip(1).take(8).map(int.tryParse).toList();
      if (coreTicks.length < 4 ||
          coreTicks.any((tick) => tick == null || tick < 0)) {
        continue;
      }
      cpuCores[int.parse(id.group(1)!)] = CpuCounters(
        coreTicks.fold(0, (sum, tick) => sum + tick!),
        coreTicks[3]! + (coreTicks.length > 4 ? coreTicks[4]! : 0),
      );
    }
    final memory = <String, int>{};
    for (final line in sections['MEMORY']!) {
      final fields = _fields(line);
      if (fields.length >= 2) {
        memory[fields.first.replaceAll(':', '')] = int.parse(fields[1]) * 1024;
      }
    }
    final total = memory['MemTotal']!;
    final available =
        memory['MemAvailable'] ??
        (memory['MemFree']! +
            (memory['Buffers'] ?? 0) +
            (memory['Cached'] ?? 0) +
            (memory['SReclaimable'] ?? 0) -
            (memory['Shmem'] ?? 0));
    if (total <= 0) throw const FormatException('invalid memory');
    final network = <String, IoCounters>{};
    for (final line in sections['NETWORK'] ?? <String>[]) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim();
      final fields = _fields(line.substring(colon + 1));
      if (name == 'lo' || fields.length < 16) continue;
      network[name] = IoCounters(int.parse(fields[0]), int.parse(fields[8]));
    }
    final disks = <String, IoCounters>{};
    for (final line in sections['DISKS'] ?? <String>[]) {
      final fields = _fields(line);
      if (fields.length < 12) continue;
      // 内核块设备统计使用固定 512 字节扇区，与物理扇区大小无关。
      disks[fields.first] = IoCounters(
        int.parse(fields[3]) * 512,
        int.parse(fields[7]) * 512,
      );
    }
    return ServerStatusSample(
      systemRelease: _linuxRelease(sections['OS_RELEASE']),
      uptimeSeconds: uptime,
      cpuTotal: ticks.fold(0, (sum, value) => sum + value),
      cpuIdle: ticks[3] + (ticks.length > 4 ? ticks[4] : 0),
      cpuCores: cpuCores,
      memoryTotal: total,
      memoryAvailable: available.clamp(0, total),
      filesystems: _filesystems(sections['FILESYSTEMS']),
      network: network,
      disks: disks,
    );
  } on Object {
    throw const SshEngineException('无法解析服务状态，请检查远端系统及读取权限');
  }
}

List<String> _fields(String line) => line.trim().split(RegExp(r'\s+'));

String? _linuxRelease(List<String>? lines) {
  final values = <String, String>{};
  for (final line in lines ?? <String>[]) {
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator);
    var value = line.substring(separator + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value
          .substring(1, value.length - 1)
          .replaceAllMapped(RegExp(r'\\(["\\$`])'), (match) => match.group(1)!);
    } else if (value.length >= 2 &&
        value.startsWith("'") &&
        value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isNotEmpty) values[key] = value;
  }
  final name = values['NAME'];
  final version = values['VERSION_ID'];
  if (name != null && version != null) return '$name $version';
  return values['PRETTY_NAME'] ?? name;
}

List<FilesystemUsage> _filesystems(List<String>? lines) {
  final result = <FilesystemUsage>[];
  for (final line in lines ?? <String>[]) {
    final fields = _fields(line);
    if (fields.length < 6 || int.tryParse(fields[1]) == null) continue;
    final total = int.parse(fields[1]) * 1024;
    if (total <= 0) continue;
    // macOS df 额外列出 iused/ifree/%iused，挂载点从第 9 列开始。
    final mountIndex = fields.length >= 9 && fields[7].endsWith('%') ? 8 : 5;
    result.add(
      FilesystemUsage(
        mount: fields.skip(mountIndex).join(' '),
        total: total,
        used: int.parse(fields[2]) * 1024,
        available: int.parse(fields[3]) * 1024,
      ),
    );
  }
  return result;
}

ServerStatusSample _parseMacStatus(Map<String, List<String>> sections) {
  final cpuLines = sections['MAC_CPU']!
      .where((line) => line.startsWith('CPU usage:'))
      .toList();
  if (cpuLines.length < 2) throw const FormatException('incomplete CPU sample');
  final idle = RegExp(r'([\d.]+)% idle').firstMatch(cpuLines.last);
  final cpu = 1 - double.parse(idle!.group(1)!) / 100;
  final memoryLines = sections['MAC_MEMORY']!;
  final total = int.parse(memoryLines.first);
  final pageSize = int.parse(
    RegExp(r'page size of (\d+) bytes').firstMatch(memoryLines[1])!.group(1)!,
  );
  final pages = <String, int>{};
  for (final line in memoryLines.skip(2)) {
    final match = RegExp(r'^(Pages [^:]+):\s+(\d+)\.').firstMatch(line);
    if (match != null) pages[match.group(1)!] = int.parse(match.group(2)!);
  }
  // 可回收的文件页与空闲页作为可用内存，压缩器占用仍计为已用。
  final available =
      (pages['Pages free']! +
          pages['Pages inactive']! +
          (pages['Pages speculative'] ?? 0)) *
      pageSize;
  final network = <String, IoCounters>{};
  for (final line in sections['MAC_NETWORK'] ?? <String>[]) {
    final fields = _fields(line);
    if (fields.length < 10 || !line.contains('<Link#')) continue;
    final name = fields.first.replaceAll('*', '');
    if (name == 'lo0' || fields.first.endsWith('*')) continue;
    // Link 行可能没有 MAC 地址，尾部 7 列的位置始终一致。
    final counters = fields.skip(fields.length - 7).toList();
    network[name] = IoCounters(int.parse(counters[2]), int.parse(counters[5]));
  }
  final disks = <String, IoCounters>{};
  IoCounters? current;
  for (final line in sections['MAC_DISKS'] ?? <String>[]) {
    if (line.contains('<class IOBlockStorageDriver,')) current = null;
    if (line.contains('"Statistics"')) {
      final read = RegExp(r'"Bytes \(Read\)"=(\d+)').firstMatch(line);
      final write = RegExp(r'"Bytes \(Write\)"=(\d+)').firstMatch(line);
      if (read != null && write != null) {
        current = IoCounters(
          int.parse(read.group(1)!),
          int.parse(write.group(1)!),
        );
      }
    }
    final name = RegExp(r'"BSD Name" = "(disk\d+)"').firstMatch(line);
    if (name != null && current != null) {
      disks[name.group(1)!] = current;
      current = null;
    }
  }
  final uptime = double.parse(_fields(sections['UPTIME']!.single).first);
  if (uptime <= 0 || total <= 0 || cpu < 0 || cpu > 1) {
    throw const FormatException('invalid macOS sample');
  }
  return ServerStatusSample(
    system: 'macOS',
    systemRelease: sections['MAC_VERSION']?.firstOrNull == null
        ? null
        : 'macOS ${sections['MAC_VERSION']!.first}',
    measuredCpuFraction: cpu,
    uptimeSeconds: uptime,
    cpuTotal: 0,
    cpuIdle: 0,
    cpuCores: _macCpuCores(sections['MAC_CPU_CORES']),
    memoryTotal: total,
    memoryAvailable: available.clamp(0, total),
    filesystems: _macSystemFilesystem(
      sections['FILESYSTEMS'],
      sections['MAC_DISK_NAME']?.firstOrNull,
    ),
    network: network,
    disks: disks,
  );
}

Map<int, CpuCounters> _macCpuCores(List<String>? lines) {
  final cores = <int, CpuCounters>{};
  for (final line in lines ?? <String>[]) {
    final fields = _fields(line);
    if (fields.length != 3) continue;
    final id = RegExp(r'^cpu(\d+)$').firstMatch(fields.first);
    final total = int.tryParse(fields[1]);
    final idle = int.tryParse(fields[2]);
    if (id == null ||
        total == null ||
        idle == null ||
        total < 0 ||
        idle < 0 ||
        idle > total) {
      continue;
    }
    cores[int.parse(id.group(1)!)] = CpuCounters(total, idle);
  }
  return cores;
}

List<FilesystemUsage> _macSystemFilesystem(List<String>? lines, String? name) {
  final root = _filesystems(lines).where((fs) => fs.mount == '/').firstOrNull;
  if (root == null) return [];
  final available = root.available.clamp(0, root.total);
  // APFS 的 Used 仅属于当前卷；总容量减共享可用空间才反映系统容器占用。
  return [
    FilesystemUsage(
      mount: root.mount,
      name: name,
      total: root.total,
      used: root.total - available,
      available: available,
    ),
  ];
}
