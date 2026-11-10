import 'package:pagashell/domain/ssh/docker_manager.dart';

DockerResource dockerResource({
  DockerResourceKind kind = DockerResourceKind.container,
  String? id,
  String? name,
  Map<DockerField, String>? fields,
}) => DockerResource(
  kind: kind,
  id:
      id ??
      (kind == DockerResourceKind.volume || kind == DockerResourceKind.compose
          ? kind == DockerResourceKind.compose
                ? 'app'
                : 'app_data'
          : '${kind == DockerResourceKind.image ? 'sha256:' : ''}${'a'.padRight(64, 'a')}'),
  name:
      name ??
      switch (kind) {
        DockerResourceKind.compose => 'app',
        DockerResourceKind.container => 'web-api',
        DockerResourceKind.image => 'nginx:stable',
        DockerResourceKind.network => 'app_net',
        DockerResourceKind.volume => 'app_data',
      },
  fields:
      fields ??
      switch (kind) {
        DockerResourceKind.compose => {
          DockerField.state: 'running',
          DockerField.status: 'running (2)',
          DockerField.serviceCount: '2',
          DockerField.containerCount: '2',
          DockerField.services: 'api\ndb',
          DockerField.workingDirectory: '/srv/app',
          DockerField.configFiles: '/srv/app/compose.yaml',
        },
        DockerResourceKind.container => {
          DockerField.image: 'nginx:stable',
          DockerField.state: 'running',
          DockerField.status: 'Up 2 hours',
          DockerField.ports: '0.0.0.0:8080->80/tcp',
        },
        DockerResourceKind.image => {
          DockerField.tags: 'nginx:stable\nnginx:latest',
          DockerField.usage: 'used',
          DockerField.size: '192MB',
          DockerField.createdAt: '2026-11-01 08:00:00 +0000 UTC',
        },
        DockerResourceKind.network || DockerResourceKind.volume => {
          DockerField.driver: kind == DockerResourceKind.network
              ? 'bridge'
              : 'local',
          DockerField.scope: 'local',
        },
      },
);

DockerResource dockerImage({
  required String hex,
  List<String> tags = const [],
  bool? inUse = false,
}) => dockerResource(
  kind: DockerResourceKind.image,
  id: 'sha256:${hex.padRight(64, hex)}',
  name: tags.isEmpty ? hex.padRight(12, hex) : tags.first,
  fields: {
    DockerField.tags: tags.join('\n'),
    DockerField.size: '192MB',
    if (inUse != null) DockerField.usage: inUse ? 'used' : 'unused',
  },
);

DockerDetails dockerDetails(DockerResource resource) => DockerDetails(
  DockerResource(
    kind: resource.kind,
    id: resource.id,
    name: resource.name,
    fields: {
      ...resource.fields,
      DockerField.createdAt: '2026-11-01T08:00:00Z',
      if (resource.kind == DockerResourceKind.container)
        DockerField.mounts:
            'volume · /var/lib/docker/volumes/app_data/_data → /data (rw)',
      if (resource.kind == DockerResourceKind.volume)
        DockerField.mountpoint: '/var/lib/docker/volumes/app_data/_data',
    },
  ),
);
