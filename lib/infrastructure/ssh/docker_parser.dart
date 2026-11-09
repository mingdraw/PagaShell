import 'dart:convert';

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';

final _hexId = RegExp(r'^[a-fA-F0-9]{12,64}$');
final _volumeId = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}$');
final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]');

List<DockerResource> parseDockerResources(String raw, DockerResourceKind kind) {
  try {
    final resources = <String, DockerResource>{};
    final usedImages = <String>{};
    var imageUsageComplete = false;
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      final data = _object(jsonDecode(line));
      if (kind == DockerResourceKind.image && !data.containsKey('id')) {
        if (data.containsKey('usedImageId')) {
          usedImages.add(_id(data['usedImageId'], DockerResourceKind.image));
        } else if (data['imageUsageComplete'] == true) {
          imageUsageComplete = true;
        } else {
          _invalid();
        }
        continue;
      }
      final id = _id(data['id'], kind);
      final fields = <DockerField, String>{};
      String name;
      switch (kind) {
        case DockerResourceKind.container:
          name = _requiredText(data['name']);
          _strings(data, fields, const {
            DockerField.image: 'image',
            DockerField.state: 'state',
            DockerField.status: 'status',
            DockerField.ports: 'ports',
            DockerField.networks: 'networks',
            DockerField.createdAt: 'createdAt',
          });
        case DockerResourceKind.image:
          final repository = _text(data['repository']);
          final tag = _text(data['tag']);
          final reference =
              repository.isEmpty ||
                  repository == '<none>' ||
                  tag.isEmpty ||
                  tag == '<none>'
              ? ''
              : '$repository:$tag';
          final old = resources[id];
          final tags = <String>{
            ...?old?.fields[DockerField.tags]?.split('\n'),
            if (reference.isNotEmpty) reference,
          };
          final digest = _text(data['digest']);
          final digests = <String>{
            ...?old?.fields[DockerField.digests]?.split('\n'),
            if (digest.isNotEmpty && digest != '<none>') digest,
          };
          name = tags.isEmpty
              ? id.replaceFirst('sha256:', '').substring(0, 12)
              : tags.first;
          fields[DockerField.tags] = tags.join('\n');
          fields[DockerField.digests] = digests.join('\n');
          _strings(data, fields, const {
            DockerField.createdAt: 'createdAt',
            DockerField.size: 'size',
          });
        case DockerResourceKind.network:
        case DockerResourceKind.volume:
          name = _requiredText(data['name']);
          if (kind == DockerResourceKind.volume && name != id) _invalid();
          _strings(data, fields, const {
            DockerField.driver: 'driver',
            DockerField.scope: 'scope',
          });
      }
      resources[id] = DockerResource(
        kind: kind,
        id: id,
        name: name,
        fields: fields,
      );
    }
    return List.unmodifiable(
      resources.values.map((resource) {
        if (kind != DockerResourceKind.image || !imageUsageComplete) {
          return resource;
        }
        return DockerResource(
          kind: resource.kind,
          id: resource.id,
          name: resource.name,
          fields: {
            ...resource.fields,
            DockerField.usage: usedImages.contains(resource.id)
                ? 'used'
                : 'unused',
          },
        );
      }),
    );
  } on Object {
    throw const SshEngineException('Docker 数据格式无效');
  }
}

DockerDetails parseDockerDetails(String raw, DockerResource requested) {
  try {
    final data = _object(jsonDecode(raw));
    final kind = requested.kind;
    final id = _id(data['id'], kind);
    if (id != _id(requested.id, kind)) _invalid();
    final fields = <DockerField, String>{};
    _strings(data, fields, const {DockerField.createdAt: 'createdAt'});
    var name = _text(data['name']);
    switch (kind) {
      case DockerResourceKind.container:
        name = name.replaceFirst(RegExp(r'^/'), '');
        _strings(data, fields, const {
          DockerField.image: 'image',
          DockerField.state: 'state',
          DockerField.health: 'health',
          DockerField.startedAt: 'startedAt',
          DockerField.finishedAt: 'finishedAt',
        });
        for (final field in const {
          DockerField.exitCode: 'exitCode',
          DockerField.restartCount: 'restartCount',
        }.entries) {
          if (data[field.value] case final Object value) {
            fields[field.key] = '${_number(value)}';
          }
        }
        fields[DockerField.ports] = _ports(data['ports']);
        fields[DockerField.networks] = _networks(data['networks']);
        fields[DockerField.mounts] = _mounts(data['mounts']);
      case DockerResourceKind.image:
        final tags = _texts(data['tags']);
        fields[DockerField.tags] = tags.join('\n');
        fields[DockerField.digests] = _texts(data['digests']).join('\n');
        if (data['size'] case final Object size) {
          fields[DockerField.size] = _bytes(_number(size));
        }
        _strings(data, fields, const {
          DockerField.platform: 'platform',
          DockerField.architecture: 'architecture',
        });
        name = tags.isEmpty ? requested.name : tags.first;
      case DockerResourceKind.network:
        _strings(data, fields, const {
          DockerField.driver: 'driver',
          DockerField.scope: 'scope',
        });
        for (final field in const {
          DockerField.internal: 'internal',
          DockerField.ipv6: 'ipv6',
          DockerField.attachable: 'attachable',
          DockerField.ingress: 'ingress',
        }.entries) {
          final value = data[field.value];
          if (value != null) {
            if (value is! bool) _invalid();
            fields[field.key] = '$value';
          }
        }
        fields[DockerField.ipam] = _ipam(data['ipam']);
        fields[DockerField.containers] = _containers(data['containers']);
      case DockerResourceKind.volume:
        if (name.isNotEmpty && name != id) _invalid();
        _strings(data, fields, const {
          DockerField.driver: 'driver',
          DockerField.scope: 'scope',
          DockerField.mountpoint: 'mountpoint',
        });
    }
    return DockerDetails(
      DockerResource(
        kind: kind,
        id: id,
        name: name.isEmpty ? requested.name : name,
        fields: fields,
      ),
    );
  } on Object {
    throw const SshEngineException('Docker 详情格式无效，请刷新后重试');
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

String _text(Object? value) {
  if (value == null) return '';
  if (value is! String) _invalid();
  return value.replaceAll(_controls, '').trim();
}

String _requiredText(Object? value) {
  final text = _text(value);
  if (text.isEmpty) _invalid();
  return text;
}

String _id(Object? value, DockerResourceKind kind) {
  if (value is! String) _invalid();
  if (kind == DockerResourceKind.volume) {
    if (!_volumeId.hasMatch(value)) _invalid();
    return value;
  }
  final hex = kind == DockerResourceKind.image
      ? value.replaceFirst('sha256:', '')
      : value;
  if (!_hexId.hasMatch(hex)) _invalid();
  return kind == DockerResourceKind.image
      ? 'sha256:${hex.toLowerCase()}'
      : hex.toLowerCase();
}

void _strings(
  Map<String, dynamic> data,
  Map<DockerField, String> fields,
  Map<DockerField, String> keys,
) {
  for (final entry in keys.entries) {
    final value = _text(data[entry.value]);
    if (value.isNotEmpty) fields[entry.key] = value;
  }
}

List<Object?> _list(Object? value) {
  if (value == null) return const [];
  if (value is! List) _invalid();
  return value;
}

List<String> _texts(Object? value) => [
  for (final item in _list(value)) _requiredText(item),
];

int _number(Object value) {
  if (value is! int || value < 0) _invalid();
  return value;
}

String _ports(Object? value) {
  if (value == null) return '';
  return _object(value).entries
      .map((entry) {
        final bindings = _list(entry.value)
            .map((binding) {
              final data = _object(binding);
              final host = _text(data['HostIp']);
              return '${host.contains(':') ? '[$host]' : host}:${_text(data['HostPort'])}';
            })
            .join(', ');
        return '${_text(entry.key)}${bindings.isEmpty ? '' : ' ← $bindings'}';
      })
      .join('\n');
}

String _networks(Object? value) {
  if (value == null) return '';
  return _object(value).entries
      .map((entry) {
        final data = _object(entry.value);
        final addresses = [
          _text(data['IPAddress']),
          _text(data['GlobalIPv6Address']),
        ].where((value) => value.isNotEmpty).join(' · ');
        return '${_text(entry.key)}${addresses.isEmpty ? '' : ' · $addresses'}';
      })
      .join('\n');
}

String _mounts(Object? value) => _list(value)
    .map((item) {
      final data = _object(item);
      final source = _text(data['Source']);
      final destination = _text(data['Destination']);
      final mode = data['RW'] == true ? 'rw' : 'ro';
      return '${_text(data['Type'])} · $source → $destination ($mode)';
    })
    .join('\n');

String _ipam(Object? value) => _list(value)
    .map((item) {
      final data = _object(item);
      return [
        _text(data['Subnet']),
        _text(data['Gateway']),
        _text(data['IPRange']),
      ].where((value) => value.isNotEmpty).join(' · ');
    })
    .where((value) => value.isNotEmpty)
    .join('\n');

String _containers(Object? value) {
  if (value == null) return '';
  return _object(value).entries
      .map((entry) {
        final data = _object(entry.value);
        return [
          _text(data['Name']),
          _text(data['IPv4Address']),
          _text(data['IPv6Address']),
        ].where((value) => value.isNotEmpty).join(' · ');
      })
      .join('\n');
}

String _bytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var amount = value.toDouble();
  var index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index++;
  }
  return '${amount.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
}

Never _invalid() => throw const FormatException('Invalid Docker data');
