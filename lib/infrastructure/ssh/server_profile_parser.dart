import '../../domain/ssh/agent_ops.dart';

ServerProfile parseServerProfile(String raw) {
  final fields = <String, String>{};
  final sysctl = <String, String>{};
  final packages = <String>{};
  final disks = <ServerDiskProfile>[];
  final services = <DetectedServiceProfile>[];
  for (final line in raw.split('\n')) {
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator);
    final value = line.substring(separator + 1).trim();
    if (value.isEmpty) continue;
    if (key.startsWith('sysctl.') && sysctl.length < 32) {
      sysctl[key.substring(7)] = value;
      continue;
    }
    switch (key) {
      case 'package':
        if (packages.length < 10) packages.add(value);
      case 'disk':
        final parts = value.split('|');
        if (parts.length == 3 && disks.length < 64) {
          disks.add(
            ServerDiskProfile(
              parts[0],
              int.tryParse(parts[1]),
              switch (parts[2]) {
                '0' => false,
                '1' => true,
                _ => null,
              },
            ),
          );
        }
      case 'service':
        final parts = value.split('|');
        if (parts.length == 3 && services.length < 32) {
          services.add(
            DetectedServiceProfile(
              parts[0],
              parts[1].isEmpty ? null : parts[1],
              parts[2].isEmpty ? null : parts[2],
            ),
          );
        }
      default:
        if (fields.length < 24) fields[key] = value;
    }
  }

  String? field(String key) {
    final value = fields[key];
    if (value == null || value.length < 2) return value;
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  int? number(String key) => int.tryParse(field(key) ?? '');
  int? darwinSwap(String fieldName) {
    final match = RegExp('$fieldName\\s*=\\s*([0-9.]+)\\s*([KMGTP])')
        .firstMatch(field('swap_usage') ?? '');
    if (match == null) return null;
    final amount = double.tryParse(match[1]!);
    if (amount == null || !amount.isFinite || amount > 1e9) return null;
    return (amount * (1 << (10 + 'KMGTP'.indexOf(match[2]!) * 10))).round();
  }

  return ServerProfile(
    system: field('system') ?? 'unknown',
    kernel: field('kernel'),
    architecture: field('architecture'),
    distribution: field('PRETTY_NAME'),
    distributionId: field('ID'),
    distributionVersion: field('VERSION_ID'),
    virtualization: field('virtualization'),
    initSystem: field('init'),
    user: field('user'),
    privilege: field('privilege'),
    packageManagers: List.unmodifiable(packages),
    cpuCores: number('cpu_cores'),
    memoryBytes: number('memory_bytes'),
    memoryAvailableBytes: number('available_bytes'),
    swapBytes: number('swap_bytes') ?? darwinSwap('total'),
    swapFreeBytes: number('swap_free_bytes') ?? darwinSwap('free'),
    softOpenFiles: field('nofile_soft'),
    hardOpenFiles: field('nofile_hard'),
    transparentHugePages: field('thp'),
    sysctl: Map.unmodifiable(sysctl),
    disks: List.unmodifiable(disks),
    services: List.unmodifiable(services),
  );
}
