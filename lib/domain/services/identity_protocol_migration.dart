import '../entities/host.dart';
import '../entities/identity.dart';

/// Splits legacy credentials by their actual use, preserving existing bindings.
/// Clones initially share the encrypted reference; secret edits use copy-on-write.
class IdentityProtocolMigration {
  IdentityProtocolMigration(
    List<Identity> source,
    Map<String, Set<ServiceType>> usage,
  ) {
    final ids = source.map((i) => i.id).toSet();
    final names = <String?, Set<String>>{};
    final orders = <String?, int>{};
    for (final i in source) {
      (names[i.folderId] ??= {}).add(i.name);
      final old = orders[i.folderId] ?? -1;
      if (i.sortOrder > old) orders[i.folderId] = i.sortOrder;
    }
    for (final i in source) {
      final types = usage[i.id] ?? {ServiceType.ssh};
      final primary = types.contains(ServiceType.ssh)
          ? ServiceType.ssh
          : types.first;
      identities.add(i.copyWith(serviceType: primary));
      bindings[(i.id, primary)] = i.id;
      for (final type in types.where((t) => t != primary)) {
        final baseId =
            '${i.id.length > 175 ? i.id.substring(0, 175) : i.id}-${type.name}';
        var id = baseId;
        var suffix = 2;
        while (!ids.add(id)) {
          id = '$baseId-${suffix++}';
        }
        final baseName =
            '${i.name.length > 975 ? i.name.substring(0, 975) : i.name} (${type.label})';
        var name = baseName;
        suffix = 2;
        final taken = names[i.folderId]!;
        while (!taken.add(name)) {
          name = '$baseName (${suffix++})';
        }
        final order = (orders[i.folderId] ?? -1) + 1;
        orders[i.folderId] = order;
        identities.add(
          Identity(
            id: id,
            name: name,
            username: i.username,
            authType: i.authType,
            serviceType: type,
            secretRef: i.secretRef,
            folderId: i.folderId,
            sortOrder: order,
          ),
        );
        bindings[(i.id, type)] = id;
        sources[id] = i.id;
      }
    }
  }

  final List<Identity> identities = [];
  final Map<(String, ServiceType), String> bindings = {};
  final Map<String, String> sources = {};
}
