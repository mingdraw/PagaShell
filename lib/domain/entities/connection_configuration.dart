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

/// 配置导出范围：支持全局、单个服务/凭证/网关，以及三类文件夹递归导出。
sealed class ConfigurationExportScope {
  const ConfigurationExportScope();

  const factory ConfigurationExportScope.all() = AllConfigurationScope;
  const factory ConfigurationExportScope.service(String id) =
      ServiceConfigurationScope;
  const factory ConfigurationExportScope.serviceFolder(String id) =
      ServiceFolderConfigurationScope;
  const factory ConfigurationExportScope.identity(String id) =
      IdentityConfigurationScope;
  const factory ConfigurationExportScope.identityFolder(String id) =
      IdentityFolderConfigurationScope;
  const factory ConfigurationExportScope.gateway(String id) =
      GatewayConfigurationScope;
  const factory ConfigurationExportScope.gatewayFolder(String id) =
      GatewayFolderConfigurationScope;
}

final class AllConfigurationScope extends ConfigurationExportScope {
  const AllConfigurationScope();

  @override
  bool operator ==(Object other) => other is AllConfigurationScope;

  @override
  int get hashCode => runtimeType.hashCode;
}

final class ServiceConfigurationScope extends ConfigurationExportScope {
  const ServiceConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is ServiceConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

final class ServiceFolderConfigurationScope extends ConfigurationExportScope {
  const ServiceFolderConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is ServiceFolderConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

final class IdentityConfigurationScope extends ConfigurationExportScope {
  const IdentityConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is IdentityConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

final class IdentityFolderConfigurationScope extends ConfigurationExportScope {
  const IdentityFolderConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is IdentityFolderConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

final class GatewayConfigurationScope extends ConfigurationExportScope {
  const GatewayConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is GatewayConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

final class GatewayFolderConfigurationScope extends ConfigurationExportScope {
  const GatewayFolderConfigurationScope(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is GatewayFolderConfigurationScope && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
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
    this.partial = false,
  });

  final List<Folder> serviceFolders;
  final List<Host> services;
  final List<Folder> gatewayFolders;
  final List<Host> gateways;
  final List<Folder> identityFolders;
  final List<Identity> identities;
  final Map<String, String> identitySecrets;
  final Map<String, String> hostSecrets;

  /// 是否为单项或文件夹局部导出。导入时根级已有项目保留原所在目录。
  final bool partial;

  /// 按范围提取可独立导入的配置子集，自动补齐所依赖的网关、凭证及密文。
  ConnectionConfiguration select(ConfigurationExportScope scope) {
    switch (scope) {
      case AllConfigurationScope():
        return this;
      case ServiceConfigurationScope(:final id):
        final host = _findById(
          services,
          id,
          (h) => h.id,
          const ConfigurationException('所选服务已不存在'),
        );
        return _selectServices(
          selectedFolders: const [],
          selectedServices: [host.copyWith(folderId: null, sortOrder: 0)],
        );
      case ServiceFolderConfigurationScope(:final id):
        final subtree = _selectFolderSubtree(serviceFolders, id);
        final folderIds = subtree.map((f) => f.id).toSet();
        final selectedServices = [
          for (final host in services)
            if (folderIds.contains(host.folderId)) host,
        ];
        return _selectServices(
          selectedFolders: subtree,
          selectedServices: selectedServices,
        );
      case IdentityConfigurationScope(:final id):
        final identity = _findById(
          identities,
          id,
          (i) => i.id,
          const ConfigurationException('所选凭证已不存在'),
        );
        final selected = [identity.copyWith(folderId: null, sortOrder: 0)];
        return _subset(identities: selected);
      case IdentityFolderConfigurationScope(:final id):
        final subtree = _selectFolderSubtree(identityFolders, id);
        final folderIds = subtree.map((f) => f.id).toSet();
        final selected = [
          for (final identity in identities)
            if (folderIds.contains(identity.folderId)) identity,
        ];
        return _subset(identityFolders: subtree, identities: selected);
      case GatewayConfigurationScope(:final id):
        final gateway = _findById(
          gateways,
          id,
          (g) => g.id,
          const ConfigurationException('所选网关已不存在'),
        );
        return _selectGateways(
          selectedFolders: const [],
          selectedGateways: [gateway.copyWith(folderId: null, sortOrder: 0)],
        );
      case GatewayFolderConfigurationScope(:final id):
        final subtree = _selectFolderSubtree(gatewayFolders, id);
        final folderIds = subtree.map((f) => f.id).toSet();
        final selectedGateways = [
          for (final gateway in gateways)
            if (folderIds.contains(gateway.folderId)) gateway,
        ];
        return _selectGateways(
          selectedFolders: subtree,
          selectedGateways: selectedGateways,
        );
    }
  }

  ConnectionConfiguration _selectServices({
    required List<Folder> selectedFolders,
    required List<Host> selectedServices,
  }) {
    final gatewayIds = {for (final host in selectedServices) ?host.gatewayId};
    final gatewayDeps = _selectHostDependencies(
      allFolders: gatewayFolders,
      allHosts: gateways,
      targetIds: gatewayIds,
    );
    final identityIds = {
      for (final host in selectedServices) ?host.identityId,
      for (final gateway in gatewayDeps.items) ?gateway.identityId,
    };
    final identityDeps = _selectIdentityDependencies(
      allFolders: identityFolders,
      allIdentities: identities,
      targetIds: identityIds,
    );
    return _subset(
      serviceFolders: selectedFolders,
      services: selectedServices,
      gatewayFolders: gatewayDeps.folders,
      gateways: gatewayDeps.items,
      identityFolders: identityDeps.folders,
      identities: identityDeps.items,
    );
  }

  ConnectionConfiguration _selectGateways({
    required List<Folder> selectedFolders,
    required List<Host> selectedGateways,
  }) {
    final identityIds = {
      for (final gateway in selectedGateways) ?gateway.identityId,
    };
    final identityDeps = _selectIdentityDependencies(
      allFolders: identityFolders,
      allIdentities: identities,
      targetIds: identityIds,
    );
    return _subset(
      gatewayFolders: selectedFolders,
      gateways: selectedGateways,
      identityFolders: identityDeps.folders,
      identities: identityDeps.items,
    );
  }

  ConnectionConfiguration _subset({
    List<Folder> serviceFolders = const [],
    List<Host> services = const [],
    List<Folder> gatewayFolders = const [],
    List<Host> gateways = const [],
    List<Folder> identityFolders = const [],
    List<Identity> identities = const [],
  }) {
    final identityIds = identities.map((v) => v.id).toSet();
    final hostIds = [...services, ...gateways].map((v) => v.id).toSet();
    return ConnectionConfiguration(
      serviceFolders: serviceFolders,
      services: services,
      gatewayFolders: gatewayFolders,
      gateways: gateways,
      identityFolders: identityFolders,
      identities: identities,
      identitySecrets: {
        for (final entry in identitySecrets.entries)
          if (identityIds.contains(entry.key)) entry.key: entry.value,
      },
      hostSecrets: {
        for (final entry in hostSecrets.entries)
          if (hostIds.contains(entry.key)) entry.key: entry.value,
      },
      partial: true,
    );
  }

  static T _findById<T>(
    List<T> items,
    String id,
    String Function(T) idOf,
    ConfigurationException notFound,
  ) {
    for (final item in items) {
      if (idOf(item) == id) return item;
    }
    throw notFound;
  }

  static List<Folder> _selectFolderSubtree(
    List<Folder> allFolders,
    String rootId,
  ) {
    _findById(
      allFolders,
      rootId,
      (f) => f.id,
      const ConfigurationException('所选文件夹已不存在'),
    );
    final childrenByParent = <String?, List<Folder>>{};
    for (final folder in allFolders) {
      (childrenByParent[folder.parentId] ??= []).add(folder);
    }
    final included = <String>{rootId};
    final queue = <String>[rootId];
    for (var i = 0; i < queue.length; i++) {
      for (final child in childrenByParent[queue[i]] ?? const <Folder>[]) {
        if (included.add(child.id)) queue.add(child.id);
      }
    }
    return [
      for (final folder in allFolders)
        if (included.contains(folder.id))
          folder.id == rootId
              ? folder.copyWith(parentId: null, sortOrder: 0)
              : folder,
    ];
  }

  static ({List<Folder> folders, List<Host> items}) _selectHostDependencies({
    required List<Folder> allFolders,
    required List<Host> allHosts,
    required Set<String> targetIds,
  }) => _selectDependencies<Host>(
    allFolders: allFolders,
    allItems: allHosts,
    targetIds: targetIds,
    idOf: (h) => h.id,
    nameOf: (h) => h.name,
    folderIdOf: (h) => h.folderId,
    detach: (h, sortOrder) => h.copyWith(folderId: null, sortOrder: sortOrder),
  );

  static ({List<Folder> folders, List<Identity> items})
  _selectIdentityDependencies({
    required List<Folder> allFolders,
    required List<Identity> allIdentities,
    required Set<String> targetIds,
  }) => _selectDependencies<Identity>(
    allFolders: allFolders,
    allItems: allIdentities,
    targetIds: targetIds,
    idOf: (i) => i.id,
    nameOf: (i) => i.name,
    folderIdOf: (i) => i.folderId,
    detach: (i, sortOrder) => i.copyWith(folderId: null, sortOrder: sortOrder),
  );

  /// 依赖项默认脱离原目录导出；仅当依赖集合内出现同名项时保留其祖先目录，避免同级重名冲突。
  static ({List<Folder> folders, List<T> items}) _selectDependencies<T>({
    required List<Folder> allFolders,
    required List<T> allItems,
    required Set<String> targetIds,
    required String Function(T) idOf,
    required String Function(T) nameOf,
    required String? Function(T) folderIdOf,
    required T Function(T, int sortOrder) detach,
  }) {
    if (targetIds.isEmpty) {
      return (folders: const [], items: const []);
    }
    final selected = [
      for (final item in allItems)
        if (targetIds.contains(idOf(item))) item,
    ];
    if (selected.length != targetIds.length) {
      throw const ConfigurationException('配置文件内容无效或引用不完整');
    }
    final nameCounts = <String, int>{};
    for (final item in selected) {
      final name = nameOf(item);
      nameCounts[name] = (nameCounts[name] ?? 0) + 1;
    }
    final foldersById = {for (final folder in allFolders) folder.id: folder};
    final requiredFolderIds = <String>{};
    final items = <T>[];
    var rootOrder = 0;
    for (final item in selected) {
      final folderId = folderIdOf(item);
      if (folderId != null && nameCounts[nameOf(item)]! > 1) {
        String? current = folderId;
        final visited = <String>{};
        while (current != null) {
          if (!visited.add(current)) {
            throw const ConfigurationException('配置文件内容无效或引用不完整');
          }
          final folder = foldersById[current];
          if (folder == null) {
            throw const ConfigurationException('配置文件内容无效或引用不完整');
          }
          requiredFolderIds.add(current);
          current = folder.parentId;
        }
        items.add(item);
      } else {
        items.add(detach(item, rootOrder++));
      }
    }
    final folders = [
      for (final folder in allFolders)
        if (requiredFolderIds.contains(folder.id)) folder,
    ];
    return (folders: folders, items: items);
  }

  Map<String, Object?> toJson() => {
    'version': 5,
    if (partial) 'partial': true,
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
          'rdpDomain': identity.rdpDomain,
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
      if (!oldForwards &&
          json['version'] != 3 &&
          json['version'] != 4 &&
          json['version'] != 5) {
        throw const FormatException();
      }
      final partialValue = json['partial'];
      if (partialValue != null && partialValue is! bool) {
        throw const FormatException();
      }
      final partial = partialValue == true;
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
            rdpDomain: _ref(value, 'rdpDomain'),
            folderId: _ref(value, 'folderId'),
            sortOrder: value['sortOrder'] as int,
          ),
        ),
        identitySecrets: _secrets(json['identitySecrets']),
        hostSecrets: _secrets(json['hostSecrets']),
        partial: partial,
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
          partial: result.partial,
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
