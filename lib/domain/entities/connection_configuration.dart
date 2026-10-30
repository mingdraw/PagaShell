import 'dart:convert';

import '../services/host_tree.dart';
import '../services/identity_protocol_migration.dart';
import '../services/identity_tree.dart';
import 'folder.dart';
import 'forward_port.dart';
import 'host.dart';
import 'identity.dart';
import 'proxy_config.dart';

class ConfigurationException implements Exception {
  const ConfigurationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 仅用于配置迁移。密钥引用不跨设备传递，凭据按用户选择写入导出文件。
class ConnectionConfiguration {
  const ConnectionConfiguration({
    this.serviceFolders = const [],
    this.services = const [],
    this.gatewayFolders = const [],
    this.gateways = const [],
    this.identityFolders = const [],
    this.identities = const [],
    this.identitySecrets = const {},
    this.hostSecrets = const {},
  });

  final List<Folder> serviceFolders;
  final List<Host> services;
  final List<Folder> gatewayFolders;
  final List<Host> gateways;
  final List<Folder> identityFolders;
  final List<Identity> identities;
  final Map<String, String> identitySecrets;
  final Map<String, String> hostSecrets;

  Map<String, Object?> toJson() => {
    'version': 4,
    'serviceFolders': serviceFolders.map(_folderJson).toList(),
    'services': services.map(_hostJson).toList(),
    'gatewayFolders': gatewayFolders.map(_folderJson).toList(),
    'gateways': gateways.map(_hostJson).toList(),
    'identityFolders': identityFolders.map(_folderJson).toList(),
    'identities': [
      for (final identity in identities)
        {
          'id': identity.id,
          'name': identity.name,
          'username': identity.username,
          'authType': identity.authType.name,
          'serviceType': identity.serviceType.name,
          'folderId': identity.folderId,
          'sortOrder': identity.sortOrder,
        },
    ],
    'identitySecrets': identitySecrets,
    'hostSecrets': hostSecrets,
  };

  factory ConnectionConfiguration.fromJson(Map<String, dynamic> json) {
    try {
      final legacy = json['version'] == 1;
      final oldForwards = legacy || json['version'] == 2;
      if (!oldForwards && json['version'] != 3 && json['version'] != 4) {
        throw const FormatException();
      }
      var result = ConnectionConfiguration(
        serviceFolders: _list(json, 'serviceFolders', _folder),
        services: _list(
          json,
          'services',
          (v) => _host(v, discardForwards: oldForwards),
        ),
        gatewayFolders: _list(json, 'gatewayFolders', _folder),
        gateways: _list(
          json,
          'gateways',
          (v) => _host(v, discardForwards: oldForwards),
        ),
        identityFolders: _list(json, 'identityFolders', _folder),
        identities: _list(
          json,
          'identities',
          (value) => Identity(
            id: _text(value, 'id'),
            name: _text(value, 'name'),
            username: _text(value, 'username'),
            authType: AuthType.values.byName(_text(value, 'authType')),
            serviceType: legacy
                ? ServiceType.ssh
                : ServiceType.values.byName(_text(value, 'serviceType')),
            folderId: _ref(value, 'folderId'),
            sortOrder: value['sortOrder'] as int,
          ),
        ),
        identitySecrets: _secrets(json['identitySecrets']),
        hostSecrets: _secrets(json['hostSecrets']),
      );
      if (legacy) {
        final usage = <String, Set<ServiceType>>{};
        for (final h in [...result.services, ...result.gateways]) {
          if (h.identityId != null) {
            (usage[h.identityId!] ??= {}).add(h.serviceType);
          }
        }
        final converted = IdentityProtocolMigration(result.identities, usage);
        result = ConnectionConfiguration(
          serviceFolders: result.serviceFolders,
          services: [
            for (final h in result.services)
              h.copyWith(
                identityId: h.identityId == null
                    ? null
                    : converted.bindings[(h.identityId!, h.serviceType)] ??
                          h.identityId,
              ),
          ],
          gatewayFolders: result.gatewayFolders,
          gateways: result.gateways,
          identityFolders: result.identityFolders,
          identities: converted.identities,
          identitySecrets: {
            ...result.identitySecrets,
            for (final e in converted.sources.entries)
              if (result.identitySecrets.containsKey(e.value))
                e.key: result.identitySecrets[e.value]!,
          },
          hostSecrets: result.hostSecrets,
        );
      }
      result.validate();
      return result;
    } on Object {
      throw const ConfigurationException('配置文件内容无效或引用不完整');
    }
  }

  /// 同时检查层级、跨组 ID、同级名称和服务依赖，不能静默改为直连或丢弃凭据。
  void validate() {
    try {
      _unique([...serviceFolders, ...gatewayFolders].map((v) => v.id));
      _unique([...services, ...gateways].map((v) => v.id));
      _unique(identityFolders.map((v) => v.id));
      _unique(identities.map((v) => v.id));
      _validateFolders(serviceFolders);
      _validateFolders(gatewayFolders);
      _validateFolders(identityFolders);
      final serviceTree = HostTreeSnapshot(
        folders: serviceFolders,
        hosts: services,
      );
      final gatewayTree = HostTreeSnapshot(
        folders: gatewayFolders,
        hosts: gateways,
      );
      final identityTree = IdentityTreeSnapshot(
        folders: identityFolders,
        identities: identities,
      );
      for (final folder in serviceFolders) {
        serviceTree.prepareFolder(folder);
      }
      for (final folder in gatewayFolders) {
        gatewayTree.prepareFolder(folder);
      }
      for (final folder in identityFolders) {
        identityTree.prepareFolder(folder);
      }
      final credentialIds = identities.map((v) => v.id).toSet();
      final gatewayIds = gateways.map((v) => v.id).toSet();
      for (final identity in identities) {
        _name(identity.name);
        if (identity.serviceType != ServiceType.ssh &&
            identity.authType != AuthType.password) {
          throw const FormatException();
        }
        if (identity.sortOrder < 0) throw const FormatException();
        identityTree.prepareIdentity(identity);
        if (identity.authType == AuthType.privateKey &&
            identitySecrets.containsKey(identity.id)) {
          final Object? secret = jsonDecode(identitySecrets[identity.id]!);
          if (secret is! Map<String, dynamic> ||
              secret['version'] != 1 ||
              secret['privateKey'] is! String ||
              (secret['privateKey'] as String).trim().isEmpty ||
              utf8.encode(secret['privateKey'] as String).length >
                  1024 * 1024 ||
              (secret['passphrase'] != null &&
                  secret['passphrase'] is! String)) {
            throw const FormatException();
          }
        }
      }
      for (final host in [...services, ...gateways]) {
        _name(host.name);
        if (host.hostname.trim().isEmpty ||
            host.port < 1 ||
            host.port > 65535 ||
            host.sortOrder < 0 ||
            (host.identityId != null &&
                !credentialIds.contains(host.identityId))) {
          throw const FormatException();
        }
        ForwardPort.validateAll(host.forwardPorts);
        host.proxyConfig.validate();
        if (host.identityId != null &&
            identities.firstWhere((i) => i.id == host.identityId).serviceType !=
                host.serviceType) {
          throw const FormatException();
        }
      }
      for (final host in services) {
        serviceTree.prepareHost(host);
        if (host.forwardPorts.isNotEmpty ||
            host.gatewayType != GatewayType.ssh ||
            (host.gatewayId != null && !gatewayIds.contains(host.gatewayId))) {
          throw const FormatException();
        }
      }
      for (final gateway in gateways) {
        gatewayTree.prepareHost(gateway);
        if (gateway.gatewayId != null || gateway.isDesktop) {
          throw const FormatException();
        }
      }
      if (!identitySecrets.keys.every(credentialIds.contains) ||
          !hostSecrets.keys.every(
            [...services, ...gateways].map((v) => v.id).toSet().contains,
          )) {
        throw const FormatException();
      }
    } on Object {
      throw const ConfigurationException('配置文件内容无效或引用不完整');
    }
  }

  static void _validateFolders(List<Folder> folders) {
    final byId = {for (final folder in folders) folder.id: folder};
    for (final folder in folders) {
      _name(folder.name);
      if (folder.sortOrder < 0) throw const FormatException();
      final visited = <String>{folder.id};
      var parent = folder.parentId;
      while (parent != null) {
        if (!byId.containsKey(parent) || !visited.add(parent)) {
          throw const FormatException();
        }
        parent = byId[parent]!.parentId;
      }
    }
  }

  static void _unique(Iterable<String> ids) {
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || id.length > 200 || !seen.add(id)) {
        throw const FormatException();
      }
    }
    if (seen.length > 10000) throw const FormatException();
  }

  static void _name(String value) {
    if (value.trim().isEmpty || value.length > 1000) {
      throw const FormatException();
    }
  }

  static Map<String, String> _secrets(Object? value) {
    final result = Map<String, String>.from(value! as Map<String, dynamic>);
    if (result.length > 10000) throw const FormatException();
    return result;
  }

  static List<T> _list<T>(
    Map<String, dynamic> json,
    String key,
    T Function(Map<String, dynamic>) parse,
  ) {
    final values = json[key] as List<dynamic>;
    if (values.length > 10000) throw const FormatException();
    return values.map((v) => parse(v as Map<String, dynamic>)).toList();
  }

  static String _text(Map<String, dynamic> json, String key) =>
      json[key] as String;
  static String? _ref(Map<String, dynamic> json, String key) =>
      json[key] as String?;

  static Map<String, Object?> _folderJson(Folder value) => {
    'id': value.id,
    'name': value.name,
    'parentId': value.parentId,
    'sortOrder': value.sortOrder,
  };
  static Folder _folder(Map<String, dynamic> json) => Folder(
    id: _text(json, 'id'),
    name: _text(json, 'name'),
    parentId: _ref(json, 'parentId'),
    sortOrder: json['sortOrder'] as int,
  );

  static Map<String, Object?> _hostJson(Host value) => {
    'id': value.id,
    'name': value.name,
    'hostname': value.hostname,
    'port': value.port,
    'username': value.username,
    'note': value.note,
    'tags': value.tags,
    'folderId': value.folderId,
    'identityId': value.identityId,
    'gatewayId': value.gatewayId,
    'gatewayType': value.gatewayType.name,
    'serviceType': value.serviceType.name,
    'rdpDomain': value.rdpDomain,
    'pageClientId': value.pageClientId,
    'pageServerFingerprint': value.pageServerFingerprint,
    'colorValue': value.colorValue,
    'sortOrder': value.sortOrder,
    'forwardPorts': value.forwardPorts.map((v) => v.toJson()).toList(),
    'proxyConfig': value.proxyConfig.toJson(),
  };
  static Host _host(
    Map<String, dynamic> json, {
    bool discardForwards = false,
  }) => Host(
    id: _text(json, 'id'),
    name: _text(json, 'name'),
    hostname: _text(json, 'hostname'),
    port: json['port'] as int,
    username: _text(json, 'username'),
    note: _text(json, 'note'),
    tags: List<String>.from(json['tags'] as List),
    folderId: _ref(json, 'folderId'),
    identityId: _ref(json, 'identityId'),
    gatewayId: _ref(json, 'gatewayId'),
    gatewayType: GatewayType.values.byName(_text(json, 'gatewayType')),
    serviceType: ServiceType.values.byName(_text(json, 'serviceType')),
    rdpDomain: _text(json, 'rdpDomain'),
    pageClientId: _text(json, 'pageClientId'),
    pageServerFingerprint: _text(json, 'pageServerFingerprint'),
    colorValue: json['colorValue'] as int?,
    sortOrder: json['sortOrder'] as int,
    forwardPorts: discardForwards
        ? const []
        : _list(json, 'forwardPorts', ForwardPort.fromJson),
    proxyConfig: ProxyConfig.fromJson(
      json['proxyConfig'] as Map<String, dynamic>? ?? {},
    ),
  );
}
