import '../terminal/terminal_frame.dart';

/// 包括后台连接、列表或详情读取在内，每次请求的总时限。
const dockerQueryTimeout = Duration(seconds: 10);

/// Docker 查询是 SSH 后台连接的可选能力，不使用交互终端或 PTY。
abstract interface class DockerManagerSource {
  Future<List<DockerResource>> readDockerResources(DockerResourceKind kind);
  Future<DockerDetails> readDockerDetails(DockerResource resource);
}

enum DockerContainerAction { start, stop, upgrade, delete }

enum DockerImageAction { delete, pruneUntagged, pruneUnused }

class DockerActionResult {
  const DockerActionResult({this.warning});
  final String? warning;
}

/// 变更操作使用专用连接，生命周期不依赖面板的采集连接。
abstract interface class DockerContainerActions {
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource container,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  });
}

abstract interface class DockerImageActions {
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  });
}

/// 容器交互终端使用独立 SSH 连接，帧和 ACK 沿用终端内核。
abstract interface class DockerTerminalSource {
  Stream<TerminalFrame> startDockerTerminalShell({
    required DockerTerminalTarget target,
    required int cols,
    required int rows,
    int scrollback = 10000,
  });
}

class DockerTerminalTarget {
  const DockerTerminalTarget({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DockerTerminalTarget && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

enum DockerResourceKind { container, image, network, volume }

enum DockerField {
  image,
  state,
  status,
  ports,
  networks,
  createdAt,
  size,
  tags,
  digests,
  driver,
  scope,
  health,
  startedAt,
  finishedAt,
  exitCode,
  restartCount,
  mounts,
  platform,
  architecture,
  internal,
  ipv6,
  attachable,
  ingress,
  ipam,
  containers,
  mountpoint,
  usage,
}

class DockerResource {
  DockerResource({
    required this.kind,
    required this.id,
    required this.name,
    Map<DockerField, String> fields = const {},
  }) : fields = Map.unmodifiable(fields);

  final DockerResourceKind kind;
  final String id;
  final String name;
  final Map<DockerField, String> fields;

  String get identity => '${kind.name}:$id';
  bool get isUntaggedImage =>
      kind == DockerResourceKind.image &&
      (fields[DockerField.tags] ?? '').isEmpty;
  bool? get imageInUse => switch (fields[DockerField.usage]) {
    'used' => true,
    'unused' => false,
    _ => null,
  };
  String get shortId => kind == DockerResourceKind.volume
      ? id
      : id.replaceFirst('sha256:', '').substring(0, 12);

  bool matches(String query) {
    final term = query.trim().toLowerCase();
    return term.isEmpty ||
        id.toLowerCase().contains(term) ||
        name.toLowerCase().contains(term) ||
        fields.values.any((value) => value.toLowerCase().contains(term));
  }
}

/// 只在打开详情或手动刷新详情时读取。
class DockerDetails {
  const DockerDetails(this.resource);

  final DockerResource resource;
}
