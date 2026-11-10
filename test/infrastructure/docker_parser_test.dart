import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/docker_parser.dart';

import '../support/docker_fixture.dart';

void main() {
  final id = 'a'.padRight(64, 'a');

  test('编排按项目汇总运行和停止服务，排除临时容器，只暴露允许的元数据', () {
    String row(
      String hex,
      String project,
      String service,
      String state, {
      bool oneoff = false,
    }) => jsonEncode({
      'id': project,
      'containerId': hex.padRight(64, hex),
      'name': '$project-$service-1',
      'service': service,
      'state': state,
      'oneoff': oneoff ? 'True' : 'False',
      'workingDirectory': '/srv/$project',
      'configFiles': '/srv/$project/compose.yaml,/srv/$project/override.yaml',
      'composeVersion': '2.40.0',
      'Env': ['TOKEN=secret'],
      'Labels': {'secret': 'hidden'},
    });
    final raw = [
      row('a', 'app', 'api', 'running'),
      row('b', 'app', 'db', 'exited'),
      row('c', 'old', 'api', 'exited'),
      row('d', 'app', 'task', 'running', oneoff: true),
    ].join('\n');
    final projects = parseDockerResources(raw, DockerResourceKind.compose);
    expect(projects.map((p) => p.id), ['app', 'old']);
    final app = projects.first;
    expect(app.shortId, 'app');
    expect(app.fields[DockerField.services], 'api\ndb');
    expect(app.fields[DockerField.serviceCount], '2');
    expect(app.fields[DockerField.containerCount], '2');
    expect(app.fields[DockerField.state], 'running');
    expect(projects.last.fields[DockerField.state], 'exited');
    expect(
      app.fields[DockerField.configFiles],
      '/srv/app/compose.yaml\n/srv/app/override.yaml',
    );
    expect(app.matches('db'), isTrue);
    expect(app.fields.values.join(), isNot(contains('secret')));
    final details = parseDockerDetails(
      [
        row('a', 'app', 'api', 'running'),
        row('b', 'app', 'db', 'exited'),
      ].join('\n'),
      app,
    );
    expect(
      details.resource.fields[DockerField.containers],
      contains('app-db-1 · exited'),
    );
    expect(
      () => parseDockerDetails(row('c', 'old', 'api', 'exited'), app),
      throwsA(isA<SshEngineException>()),
    );
    expect(
      () => parseDockerDetails('', app),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 资源可能已移除，请刷新后重试',
        ),
      ),
    );
  });

  test('四类列表包含停止容器和卷，镜像按 ID 合并所有引用，空列表合法', () {
    final containers = parseDockerResources(
      [
        jsonEncode({
          'id': id,
          'name': 'api',
          'image': 'nginx:stable',
          'state': 'running',
        }),
        jsonEncode({
          'id': 'b'.padRight(64, 'b'),
          'name': 'old-api',
          'state': 'exited',
        }),
      ].join('\n'),
      DockerResourceKind.container,
    );
    expect(containers, hasLength(2));
    expect(containers.last.fields[DockerField.state], 'exited');
    final images = parseDockerResources(
      [
        for (final tag in ['stable', 'latest'])
          jsonEncode({
            'id': 'sha256:$id',
            'repository': 'nginx',
            'tag': tag,
            'digest': 'sha256:digest',
            'size': '192MB',
          }),
      ].join('\n'),
      DockerResourceKind.image,
    );
    expect(images, hasLength(1));
    expect(
      images.single.fields[DockerField.tags],
      'nginx:stable\nnginx:latest',
    );
    expect(images.single.fields[DockerField.digests], 'sha256:digest');
    expect(images.single.matches('LATEST'), true);
    final network = parseDockerResources(
      jsonEncode({
        'id': id,
        'name': 'app_net',
        'driver': 'bridge',
        'scope': 'local',
      }),
      DockerResourceKind.network,
    ).single;
    expect(network.fields[DockerField.driver], 'bridge');
    final volume = parseDockerResources(
      jsonEncode({'id': 'app_data', 'name': 'app_data', 'driver': 'local'}),
      DockerResourceKind.volume,
    ).single;
    expect(volume.name, 'app_data');
    for (final kind in DockerResourceKind.values) {
      expect(parseDockerResources('\n \n', kind), isEmpty);
    }
  });

  test('悬空镜像可查看详情，列表清理控制字符，类型或标识错误不伪装为空', () {
    final image = parseDockerResources(
      jsonEncode({
        'id': id,
        'repository': '<none>',
        'tag': '<none>',
        'digest': '<none>',
      }),
      DockerResourceKind.image,
    ).single;
    expect(image.id, 'sha256:$id');
    expect(image.shortId, 'a'.padRight(12, 'a'));
    expect(image.fields[DockerField.tags], '');
    final container = parseDockerResources(
      jsonEncode({'id': id, 'name': 'web\u001b[31m\napi\u202e'}),
      DockerResourceKind.container,
    ).single;
    expect(container.name, 'web[31mapi');
    for (final invalid in [
      '{}',
      '[]',
      'not-json',
      jsonEncode({'id': id, 'name': 12}),
      jsonEncode({'id': '--help', 'name': 'api'}),
    ]) {
      expect(
        () => parseDockerResources(invalid, DockerResourceKind.container),
        throwsA(isA<SshEngineException>()),
      );
    }
  });

  test('镜像保留无标签和仅有摘要的条目，按不可变 ID 标记引用，缺少完整采集时状态未知', () {
    final raw = [
      for (final (hex, repository, tag) in [
        ('a', 'app', 'latest'),
        ('b', '<none>', '<none>'),
        ('c', 'registry/app', '<none>'),
        ('d', 'unused', 'old'),
      ])
        jsonEncode({
          'id': 'sha256:${hex.padRight(64, hex)}',
          'repository': repository,
          'tag': tag,
        }),
      jsonEncode({'usedImageId': 'sha256:${'b'.padRight(64, 'b')}'}),
      jsonEncode({'usedImageId': 'sha256:$id'}),
    ];
    final partial = parseDockerResources(
      raw.join('\n'),
      DockerResourceKind.image,
    );
    expect(partial.every((image) => image.imageInUse == null), isTrue);
    final images = parseDockerResources(
      [
        ...raw,
        jsonEncode({'imageUsageComplete': true}),
      ].join('\n'),
      DockerResourceKind.image,
    );
    expect(images, hasLength(4));
    expect(images.map((image) => image.imageInUse), [true, true, false, false]);
    expect(images.map((image) => image.isUntaggedImage), [
      false,
      true,
      true,
      false,
    ]);
    expect(images[1].fields[DockerField.tags], isEmpty);
    expect(images[2].name, 'c'.padRight(12, 'c'));
    expect(
      () => parseDockerResources(
        '{"usedImageId":"--help"}',
        DockerResourceKind.image,
      ),
      throwsA(isA<SshEngineException>()),
    );
  });

  test('容器详情只解析允许字段，以可读文本展示端口、网络和挂载', () {
    final resource = dockerResource();
    final details = parseDockerDetails(
      jsonEncode({
        'id': resource.id,
        'name': '/web-api',
        'state': 'running',
        'exitCode': 0,
        'restartCount': 2,
        'ports': {
          '80/tcp': [
            {'HostIp': '::', 'HostPort': '8080'},
          ],
          '443/tcp': null,
        },
        'networks': {
          'app_net': {'IPAddress': '172.18.0.2', 'GlobalIPv6Address': ''},
        },
        'mounts': [
          {
            'Type': 'volume',
            'Source': '/data',
            'Destination': '/app',
            'RW': true,
          },
        ],
        'Env': ['TOKEN=should-not-appear'],
        'Labels': {'password': 'should-not-appear'},
      }),
      resource,
    ).resource;
    expect(details.name, 'web-api');
    expect(details.fields[DockerField.ports], '80/tcp ← [::]:8080\n443/tcp');
    expect(details.fields[DockerField.networks], 'app_net · 172.18.0.2');
    expect(details.fields[DockerField.mounts], 'volume · /data → /app (rw)');
    expect(details.fields.values.join(), isNot(contains('should-not-appear')));
  });

  test('镜像、网络、卷详情兼容可选字段，核对资源身份，错误固定不透传原文', () {
    final image = dockerResource(kind: DockerResourceKind.image);
    final imageDetails = parseDockerDetails(
      jsonEncode({
        'id': image.id,
        'tags': ['nginx:stable'],
        'digests': null,
        'size': 2048,
        'platform': 'linux',
        'architecture': 'arm64',
      }),
      image,
    ).resource;
    expect(imageDetails.fields[DockerField.size], '2.0 KiB');
    final network = dockerResource(kind: DockerResourceKind.network);
    final net = parseDockerDetails(
      jsonEncode({
        'id': network.id,
        'internal': false,
        'ipv6': true,
        'ipam': [
          {'Subnet': '172.18.0.0/16', 'Gateway': '172.18.0.1'},
        ],
        'containers': {
          id: {'Name': 'web-api', 'IPv4Address': '172.18.0.2/16'},
        },
      }),
      network,
    ).resource;
    expect(net.fields[DockerField.internal], 'false');
    expect(net.fields[DockerField.ipam], '172.18.0.0/16 · 172.18.0.1');
    expect(net.fields[DockerField.containers], 'web-api · 172.18.0.2/16');
    final volume = dockerResource(kind: DockerResourceKind.volume);
    final details = parseDockerDetails(
      jsonEncode({
        'id': volume.id,
        'name': volume.name,
        'mountpoint': '/var/lib/docker/volumes/app_data/_data',
      }),
      volume,
    );
    expect(
      details.resource.fields[DockerField.mountpoint],
      contains('/app_data/'),
    );
    for (final raw in [
      'sensitive/platform/error',
      jsonEncode({'id': 'b'.padRight(64, 'b')}),
      jsonEncode({'id': network.id, 'ipv6': 'yes'}),
    ]) {
      expect(
        () => parseDockerDetails(raw, network),
        throwsA(
          isA<SshEngineException>().having(
            (e) => e.message,
            'message',
            'Docker 详情格式无效，请刷新后重试',
          ),
        ),
      );
    }
  });
}
