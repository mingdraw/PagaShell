part of 'agent_controller.dart';

const _missingSshTarget =
    'No selected ready SSH session. Specify session_id from CURRENT_CONTEXT when multiple sessions are referenced. Nothing executed.';

const _inspectionLabels = {
  'inspect_server_profile': '采集服务器基线',
  'get_processes': '读取服务器进程',
  'get_network_ports': '读取服务器监听端口',
  'get_docker_resources': '读取 Docker 资源',
  'list_remote_dir': '读取远程目录',
};

bool _readySshTarget(Session? target) =>
    target != null &&
    target.kind == SessionKind.terminal &&
    target.phase == SessionPhase.ready &&
    !target.host.isDesktop &&
    target.engineSession != null;

final _pathControlChars = RegExp(r'[\x00-\x1f\x7f-\x9f]');

bool _validAgentPath(Object? value, {bool directory = false}) =>
    value is String &&
    value.startsWith('/') &&
    value.length <= 1500 &&
    !_pathControlChars.hasMatch(value) &&
    ((directory && value == '/') ||
        value
            .substring(1)
            .split('/')
            .every((part) => part.isNotEmpty && part != '.' && part != '..'));

extension _AgentInspectionOperations on AgentController {
  Future<String> _inspectSsh(AgentToolCall call, Session target) async {
    final source = _boundSession(target)?.engineSession;
    if (source == null) return _missingSshTarget;
    final args = call.arguments;
    Object? result;
    switch (call.name) {
      case 'inspect_server_profile' when source is ServerProfileSource:
        final profile = await (source as ServerProfileSource)
            .readServerProfile();
        result = profile.toJson();
      case 'get_processes' when source is ProcessManagerSource:
        final snapshot = await (source as ProcessManagerSource).readProcesses();
        final processes = snapshot.processes.toList();
        final byMemory = args['sort'] == 'memory';
        processes.sort(
          (a, b) => byMemory
              ? b.memoryBytes.compareTo(a.memoryBytes)
              : b.cpuPercent.compareTo(a.cpuPercent),
        );
        result = {
          'total': processes.length,
          'sort': byMemory ? 'memory' : 'cpu',
          'sampledAtSeconds': snapshot.sampledAtSeconds,
          'processes': [
            for (final p in processes.take(
              _boundedInt(args['limit'], 20, 1, 100),
            ))
              {
                'pid': p.pid,
                'user': p.user,
                'name': p.name,
                'cpuPercent': p.cpuPercent,
                'memoryBytes': p.memoryBytes,
              },
          ],
        };
      case 'get_network_ports' when source is NetworkPortsSource:
        final snapshot = await (source as NetworkPortsSource)
            .readNetworkPorts();
        result = {
          'limited': snapshot.limited,
          'total': snapshot.ports.length,
          'ports': [
            for (final port in snapshot.ports.take(100))
              {
                'protocol': port.protocol.name,
                'port': port.port,
                'addresses': port.addresses
                    .take(12)
                    .map((address) => address.address)
                    .toList(),
                'processes': [
                  for (final process in port.processes.take(8))
                    {'pid': process.pid, 'name': process.name},
                ],
              },
          ],
        };
      case 'get_docker_resources' when source is DockerManagerSource:
        final kind = DockerResourceKind.values
            .where((kind) => kind.name == (args['kind'] ?? 'container'))
            .firstOrNull;
        if (kind == null) return 'Unknown Docker resource kind.';
        final docker = source as DockerManagerSource;
        final resources = await docker.readDockerResources(kind);
        final id = args['resource_id'];
        if (id != null) {
          final resource = resources
              .where((resource) => resource.id == id)
              .firstOrNull;
          if (resource == null || _boundSession(target) == null) {
            return 'No such resource in the selected session. Get its exact ID first.';
          }
          result = _agentDockerResource(
            (await docker.readDockerDetails(resource)).resource,
          );
        } else {
          result = {
            'total': resources.length,
            'resources': resources.take(50).map(_agentDockerResource).toList(),
          };
        }
      case 'list_remote_dir':
        final path = args['path'];
        if (!_validAgentPath(path, directory: true)) {
          return 'An absolute directory path is required.';
        }
        final files = await source.listDir(path! as String);
        result = {
          'path': path,
          'total': files
              .where((file) => file.name != '.' && file.name != '..')
              .length,
          'entries': [
            for (final file
                in files
                    .where((file) => file.name != '.' && file.name != '..')
                    .take(120))
              {
                'name': file.name,
                'directory': file.isDir,
                'sizeBytes': file.size,
                'modified': file.modified?.toUtc().toIso8601String(),
              },
          ],
        };
      default:
        return 'This read-only inspection is not available on the selected connection.';
    }
    if (_boundSession(target) == null) return _missingSshTarget;
    return jsonEncode({'session_id': target.id, 'result': result});
  }
}

Map<String, Object?> _agentDockerResource(DockerResource resource) => {
  'kind': resource.kind.name,
  'id': resource.id,
  'name': resource.name,
  'fields': {
    for (final value in resource.fields.entries)
      if (const {
        DockerField.image,
        DockerField.state,
        DockerField.status,
        DockerField.ports,
        DockerField.networks,
        DockerField.size,
        DockerField.tags,
        DockerField.driver,
        DockerField.health,
        DockerField.exitCode,
        DockerField.restartCount,
        DockerField.platform,
        DockerField.services,
        DockerField.serviceCount,
        DockerField.containerCount,
      }.contains(value.key))
        value.key.name: _truncateToolOutput(
          _scrubAgentOutput(value.value),
          maxChars: 1200,
        ),
  },
};
