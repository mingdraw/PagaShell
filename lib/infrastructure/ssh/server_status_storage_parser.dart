import 'dart:convert';

import '../../domain/ssh/server_status.dart';

/// lsblk 的树可能重复列出跨盘 LVM/RAID 节点，先收集所有父设备关系。
List<DiskUsage> parseLinuxStorage(
  List<String>? lines,
  List<FilesystemUsage> filesystems, {
  List<String>? deviceAliases,
}) {
  final data = _json(lines);
  final nodes = <String, Map<String, Object?>>{};
  final aliases = <String, String>{};
  final parents = <String, Set<String>>{};
  void visit(Object? value, String? parent) {
    final node = _map(value);
    final id = _device(node['kname'] ?? node['name']);
    if (id.isEmpty) return;
    nodes[id] = node;
    aliases[_device(node['name'])] = id;
    aliases[id] = id;
    final parentId = _device(node['pkname']);
    if (parent != null) (parents[id] ??= {}).add(parent);
    if (parentId.isNotEmpty) (parents[id] ??= {}).add(parentId);
    for (final child in _list(node['children'])) {
      visit(child, id);
    }
  }

  for (final node in _list(data['blockdevices'])) {
    visit(node, null);
  }
  for (final line in deviceAliases ?? <String>[]) {
    final fields = line.split('\t');
    if (fields.length != 2) continue;
    final source = _device(fields.first);
    final target = _device(fields.last);
    if (source.isNotEmpty && target.isNotEmpty) {
      aliases[source] = aliases[target] ?? target;
    }
  }
  Set<String> roots(String id, Set<String> visited) {
    id = aliases[id] ?? id;
    if (!visited.add(id)) return {};
    if (nodes[id]?['type'] == 'disk') return {id};
    return {
      for (final parent in parents[id] ?? <String>{})
        ...roots(parent, {...visited}),
    };
  }

  final uuidDevices = <String, Set<String>>{};
  for (final entry in nodes.entries) {
    final uuid = entry.value['uuid'];
    if (uuid is String && uuid.isNotEmpty) {
      (uuidDevices[uuid] ??= {}).addAll(roots(entry.key, {}));
    }
  }
  final groups = <String, _DiskGroup>{};
  for (final fs in filesystems) {
    final device = _device(fs.device);
    final id = aliases[device] ?? device;
    final uuid = nodes[id]?['uuid'];
    final physical = uuidDevices[uuid] ?? roots(id, {});
    final devices = physical.toList()..sort();
    final key = devices.isEmpty ? id : devices.join('+');
    final group = groups.putIfAbsent(
      key,
      () => _DiskGroup(key, devices.isEmpty ? [id] : devices),
    );
    group.add(fs, uuid is String && uuid.isNotEmpty ? uuid : id);
  }
  final groupedDevices = {for (final group in groups.values) ...group.devices};
  for (final entry in nodes.entries) {
    if (entry.value['type'] != 'disk' || groupedDevices.contains(entry.key)) {
      continue;
    }
    groups[entry.key] = _DiskGroup(entry.key, [entry.key])
      ..deviceCapacity = _integer(entry.value['size']);
  }
  return [for (final group in groups.values) group.build()];
}

/// APFS 各卷共享容器空间；容量按容器计一次，再归属到物理磁盘。
({List<FilesystemUsage> filesystems, List<DiskUsage> storage}) parseMacStorage(
  List<String>? diskLines,
  List<String>? apfsLines,
  List<FilesystemUsage> filesystems, {
  String? legacyRootName,
}) {
  final disks = _json(diskLines);
  final apfs = _json(apfsLines);
  final physical = <String, Map<String, Object?>>{};
  final owners = <String, String>{};
  final names = <String, String>{};
  for (final item in _list(disks['AllDisksAndPartitions'])) {
    final disk = _map(item);
    final id = _device(disk['DeviceIdentifier']);
    if (id.isEmpty) continue;
    physical[id] = disk;
    owners[id] = id;
    for (final partition in [disk, ..._list(disk['Partitions']).map(_map)]) {
      final device = _device(partition['DeviceIdentifier']);
      owners[device] = id;
      final name = partition['VolumeName'];
      if (name is String && name.isNotEmpty) names[device] = name;
    }
  }
  final containers = <String, Map<String, Object?>>{};
  final volumeContainers = <String, String>{};
  final hiddenVolumes = <String>{};
  for (final item in _list(apfs['Containers'])) {
    final container = _map(item);
    final id = _device(container['ContainerReference']);
    if (id.isEmpty) continue;
    containers[id] = container;
    for (final item in _list(container['Volumes'])) {
      final volume = _map(item);
      final device = _device(volume['DeviceIdentifier']);
      volumeContainers[device] = id;
      final name = volume['Name'];
      if (name is String && name.isNotEmpty) names[device] = name;
      final roles = _list(volume['Roles']);
      if (roles.isNotEmpty &&
          !roles.contains('System') &&
          !roles.contains('Data')) {
        hiddenVolumes.add(device);
      }
    }
  }
  final groups = <String, _DiskGroup>{};
  final mounted = <FilesystemUsage>[];
  final fallbackContainers = {
    for (final fs in filesystems)
      if (RegExp(r'^disk\d+s\d+s\d+$').hasMatch(_device(fs.device)))
        _macWholeDevice(_device(fs.device)),
  };
  for (final fs in filesystems) {
    final source = _device(fs.device);
    if (!source.startsWith('disk')) continue;
    // 根卷可能挂载为 disk3s1s1 快照，其容量仍属于 disk3s1 所在容器。
    final volume = volumeContainers.containsKey(source)
        ? source
        : source.replaceFirst(RegExp(r's\d+$'), '');
    if (hiddenVolumes.contains(volume) || _macHelperMount(fs.mount)) continue;
    final containerId = volumeContainers[volume];
    final container = containers[containerId];
    final stores = _list(container?['PhysicalStores']);
    final devices =
        stores
            .map((item) => _device(_map(item)['DeviceIdentifier']))
            .map((id) => owners[id] ?? _macWholeDevice(id))
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (devices.isEmpty) devices.add(owners[source] ?? _macWholeDevice(source));
    // 已拿到真实物理盘清单时排除磁盘镜像及其 APFS 容器。
    if (physical.isNotEmpty && devices.any((id) => !physical.containsKey(id))) {
      continue;
    }
    final name =
        names[source] ??
        names[volume] ??
        (fs.mount == '/' ? legacyRootName : null);
    final named = FilesystemUsage(
      mount: fs.mount,
      device: fs.device,
      name: name,
      total: fs.total,
      used: fs.used,
      available: fs.available,
    );
    mounted.add(named);
    final key = devices.join('+');
    final group = groups.putIfAbsent(key, () => _DiskGroup(key, devices));
    if (name != null && (group.name == null || fs.mount == '/')) {
      group.name = name;
    }
    final capacity = _integer(container?['CapacityCeiling']);
    final free = _integer(container?['CapacityFree']);
    if (containerId != null &&
        capacity != null &&
        free != null &&
        capacity > 0) {
      group.add(
        named,
        containerId,
        total: capacity,
        used: capacity - free.clamp(0, capacity),
        available: free.clamp(0, capacity),
      );
    } else {
      // diskutil 不可用时按合成设备共享容量去重，不叠加同一 APFS 盘的卷。
      final shared =
          volumeContainers.isEmpty &&
          fallbackContainers.contains(_macWholeDevice(source));
      group.add(
        named,
        containerId ?? (shared ? _macWholeDevice(source) : source),
        used: shared ? fs.total - fs.available.clamp(0, fs.total) : fs.used,
      );
    }
  }
  final groupedDevices = {for (final group in groups.values) ...group.devices};
  for (final entry in physical.entries) {
    if (groupedDevices.contains(entry.key)) continue;
    groups[entry.key] = _DiskGroup(entry.key, [entry.key])
      ..deviceCapacity = _integer(entry.value['Size']);
  }
  return (
    filesystems: mounted,
    storage: [for (final group in groups.values) group.build()],
  );
}

bool _macHelperMount(String mount) =>
    mount.startsWith('/System/Volumes/') && mount != '/System/Volumes/Data';

String _macWholeDevice(String device) =>
    RegExp(r'^disk\d+').firstMatch(device)?.group(0) ?? device;

String _device(Object? value) =>
    value is String ? value.replaceFirst(RegExp(r'^/dev/'), '') : '';

int? _integer(Object? value) => value is num
    ? value.toInt()
    : value is String
    ? int.tryParse(value)
    : null;

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

Map<String, Object?> _json(List<String>? lines) {
  if (lines == null || lines.isEmpty) return const {};
  try {
    return _map(jsonDecode(lines.join('\n')));
  } on FormatException {
    return const {};
  }
}

class _DiskGroup {
  _DiskGroup(this.id, this.devices);

  final String id;
  final List<String> devices;
  String? name;
  int? deviceCapacity;
  final _counted = <String>{};
  final _mounts = <String>{};
  final _filesystems = <FilesystemUsage>[];
  int _total = 0;
  int _used = 0;
  int _available = 0;

  void add(
    FilesystemUsage fs,
    String identity, {
    int? total,
    int? used,
    int? available,
  }) {
    if (_mounts.add(fs.mount)) _filesystems.add(fs);
    if (!_counted.add(identity)) return;
    _total += total ?? fs.total;
    _used += used ?? fs.used;
    _available += available ?? fs.available;
  }

  DiskUsage build() => DiskUsage(
    id: id,
    name: name ?? devices.join(' + '),
    devices: devices,
    total: _counted.isEmpty ? deviceCapacity ?? 0 : _total,
    used: _counted.isEmpty ? null : _used,
    available: _counted.isEmpty ? null : _available,
    filesystems: _filesystems,
  );
}
