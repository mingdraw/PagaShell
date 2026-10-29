import 'dart:math';

import '../../domain/entities/connection_configuration.dart';
import '../../domain/entities/folder.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/repositories/configuration_repository.dart';
import '../../domain/repositories/folder_repository.dart';
import '../../domain/repositories/host_repository.dart';
import '../../domain/repositories/identity_folder_repository.dart';
import '../../domain/repositories/identity_repository.dart';
import '../../domain/vault/secret_store.dart';

/// 元数据在同一事务中提交；凭据写入失败或事务回滚时恢复原值。
abstract class StoredConfigurationRepository
    implements ConfigurationRepository {
  StoredConfigurationRepository({
    required this.serviceFolders,
    required this.services,
    required this.gatewayFolders,
    required this.gateways,
    required this.identityFolders,
    required this.identities,
    required this.secretStore,
  });

  final FolderRepository serviceFolders;
  final HostRepository services;
  final FolderRepository gatewayFolders;
  final HostRepository gateways;
  final IdentityFolderRepository identityFolders;
  final IdentityRepository identities;
  final SecretStore secretStore;

  Future<T> transaction<T>(Future<T> Function() action);

  Future<void> validateImportNamespace(
    ConnectionConfiguration incoming,
  ) async {}

  Future<ConnectionConfiguration> _metadata() async => ConnectionConfiguration(
    serviceFolders: await serviceFolders.getAll(),
    services: await services.getAll(),
    gatewayFolders: await gatewayFolders.getAll(),
    gateways: await gateways.getAll(),
    identityFolders: await identityFolders.getAll(),
    identities: await identities.getAll(),
  );

  @override
  Future<ConnectionConfiguration> read() => transaction(() async {
    final data = await _metadata();
    final identitySecrets = <String, String>{};
    final hostSecrets = <String, String>{};
    for (final identity in data.identities) {
      if (identity.secretRef == null) continue;
      final secret = await secretStore.read(identity.secretRef!);
      if (secret == null) {
        throw const ConfigurationException('凭证密文不存在，请重新输入');
      }
      identitySecrets[identity.id] = secret;
    }
    for (final host in [...data.services, ...data.gateways]) {
      if (host.identityId != null && host.gatewayType != GatewayType.page) {
        continue;
      }
      final secret = await secretStore.read('sec-host-${host.id}');
      if (secret != null) hostSecrets[host.id] = secret;
    }
    return ConnectionConfiguration(
      serviceFolders: data.serviceFolders,
      services: data.services,
      gatewayFolders: data.gatewayFolders,
      gateways: data.gateways,
      identityFolders: data.identityFolders,
      identities: data.identities,
      identitySecrets: identitySecrets,
      hostSecrets: hostSecrets,
    );
  });

  @override
  Future<void> merge(ConnectionConfiguration incoming) async {
    incoming.validate();
    final previousSecrets = <String, String?>{};
    final written = <String>[];
    try {
      await transaction(() async {
        await validateImportNamespace(incoming);
        final current = await _metadata();
        final serviceTree = _mergeTree(
          current.serviceFolders,
          current.services,
          incoming.serviceFolders,
          incoming.services,
        );
        final gatewayTree = _mergeTree(
          current.gatewayFolders,
          current.gateways,
          incoming.gatewayFolders,
          incoming.gateways,
        );
        final identityTree = _mergeTree(
          current.identityFolders,
          current.identities,
          incoming.identityFolders,
          incoming.identities,
        );
        final oldIdentities = {
          for (final item in current.identities) item.id: item,
        };
        final importedIds = incoming.identities.map((v) => v.id).toSet();
        final finalIdentities = <Identity>[
          for (final item in identityTree.items.cast<Identity>())
            if (importedIds.contains(item.id))
              item.copyWith(
                secretRef: incoming.identitySecrets.containsKey(item.id)
                    ? (current.identities.any(
                            (i) =>
                                i.id != item.id &&
                                i.secretRef != null &&
                                i.secretRef ==
                                    oldIdentities[item.id]?.secretRef,
                          )
                          ? _newSecretRef()
                          : oldIdentities[item.id]?.secretRef ??
                                _newSecretRef())
                    : oldIdentities[item.id]?.authType == item.authType &&
                          oldIdentities[item.id]?.serviceType ==
                              item.serviceType
                    ? oldIdentities[item.id]?.secretRef
                    : null,
              )
            else
              item,
        ];
        final merged = ConnectionConfiguration(
          serviceFolders: serviceTree.folders,
          services: serviceTree.items.cast<Host>(),
          gatewayFolders: gatewayTree.folders,
          gateways: gatewayTree.items.cast<Host>(),
          identityFolders: identityTree.folders,
          identities: finalIdentities,
          identitySecrets: incoming.identitySecrets,
          hostSecrets: incoming.hostSecrets,
        );
        // 检查合并后才可能出现的跨组 ID 冲突、层级循环或断裂引用。
        merged.validate();
        final hostRefs = {
          for (final host in [...merged.services, ...merged.gateways])
            'sec-host-${host.id}',
        };
        final identityRefs = <String, Set<String>>{};
        for (final item in finalIdentities) {
          if (item.secretRef case final ref?) {
            (identityRefs[ref] ??= {}).add(item.id);
          }
        }
        // 一个凭据键只能属于一个项目，避免文件中的 ID 间接覆盖其他凭据。
        for (final item in finalIdentities) {
          if (incoming.identitySecrets.containsKey(item.id) &&
              (hostRefs.contains(item.secretRef) ||
                  identityRefs[item.secretRef]!.length != 1)) {
            throw const ConfigurationException('配置文件内容无效或引用不完整');
          }
        }
        for (final id in incoming.hostSecrets.keys) {
          if (identityRefs.containsKey('sec-host-$id')) {
            throw const ConfigurationException('配置文件内容无效或引用不完整');
          }
        }
        final writes = <String, String>{
          for (final item in finalIdentities)
            if (incoming.identitySecrets.containsKey(item.id))
              item.secretRef!: incoming.identitySecrets[item.id]!,
          for (final entry in incoming.hostSecrets.entries)
            'sec-host-${entry.key}': entry.value,
        };
        // 引用键来自本机记录、随机新键或固定服务前缀，不接受文件提供的键名。
        for (final entry in writes.entries) {
          previousSecrets[entry.key] = await secretStore.read(entry.key);
        }
        for (final entry in writes.entries) {
          written.add(entry.key);
          await secretStore.put(entry.key, entry.value);
        }
        for (final folder in merged.identityFolders) {
          await identityFolders.upsert(folder);
        }
        for (final item in merged.identities) {
          await identities.upsert(item);
        }
        for (final folder in merged.gatewayFolders) {
          await gatewayFolders.upsert(folder);
        }
        for (final item in merged.gateways) {
          await gateways.upsert(item);
        }
        for (final folder in merged.serviceFolders) {
          await serviceFolders.upsert(folder);
        }
        for (final item in merged.services) {
          await services.upsert(item);
        }
      });
    } on Object {
      var restored = true;
      for (final ref in written.reversed) {
        try {
          final previous = previousSecrets[ref];
          if (previous == null) {
            await secretStore.delete(ref);
          } else {
            await secretStore.put(ref, previous);
          }
        } on Object {
          restored = false;
        }
      }
      if (!restored) {
        throw const ConfigurationException('配置导入失败，凭据恢复失败，请解锁钥匙串后重试');
      }
      throw const ConfigurationException('配置导入失败，请检查文件或解锁钥匙串后重试');
    }
  }
}

String _newSecretRef() {
  final random = Random.secure();
  final suffix = List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'sec-import-$suffix';
}

typedef _Tree = ({List<Folder> folders, List<Object> items});
typedef _Entry = ({
  String id,
  String name,
  String? parent,
  int order,
  bool folder,
  Object value,
});

/// 导入项保留文件中的混合排序，本机独有项放在对应同级末尾。同名不同 ID 保留两份。
_Tree _mergeTree(
  List<Folder> oldFolders,
  List<Object> oldItems,
  List<Folder> newFolders,
  List<Object> newItems,
) {
  _Entry entry(Object value) => switch (value) {
    Folder() => (
      id: value.id,
      name: value.name,
      parent: value.parentId,
      order: value.sortOrder,
      folder: true,
      value: value,
    ),
    Host() => (
      id: value.id,
      name: value.name,
      parent: value.folderId,
      order: value.sortOrder,
      folder: false,
      value: value,
    ),
    Identity() => (
      id: value.id,
      name: value.name,
      parent: value.folderId,
      order: value.sortOrder,
      folder: false,
      value: value,
    ),
    _ => throw const FormatException(),
  };
  final imported = [...newFolders, ...newItems].map(entry).toList();
  final ids = imported.map((v) => (v.folder, v.id)).toSet();
  final remaining = [
    ...oldFolders,
    ...oldItems,
  ].map(entry).where((v) => !ids.contains((v.folder, v.id))).toList();
  int compare(_Entry a, _Entry b) {
    final order = a.order.compareTo(b.order);
    if (order != 0) return order;
    if (a.folder != b.folder) return a.folder ? -1 : 1;
    final name = a.name.compareTo(b.name);
    return name == 0 ? a.id.compareTo(b.id) : name;
  }

  imported.sort(compare);
  remaining.sort(compare);
  final names = <(String?, bool), Set<String>>{};
  for (final item in remaining) {
    (names[(item.parent, item.folder)] ??= {}).add(item.name);
  }
  final orders = <String?, int>{};
  final folders = <Folder>[];
  final items = <Object>[];
  void append(_Entry item, {required bool rename}) {
    var name = item.name;
    final taken = names[(item.parent, item.folder)] ??= {};
    if (rename) {
      var suffix = 2;
      while (taken.contains(name)) {
        name = '${item.name} ($suffix)';
        suffix++;
      }
      taken.add(name);
    }
    final order = orders.update(
      item.parent,
      (value) => value + 1,
      ifAbsent: () => 0,
    );
    switch (item.value) {
      case final Folder value:
        folders.add(value.copyWith(name: name, sortOrder: order));
      case final Host value:
        items.add(value.copyWith(name: name, sortOrder: order));
      case final Identity value:
        items.add(value.copyWith(name: name, sortOrder: order));
    }
  }

  for (final item in imported) {
    append(item, rename: true);
  }
  for (final item in remaining) {
    append(item, rename: false);
  }
  return (folders: folders, items: items);
}
