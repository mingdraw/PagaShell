import '../../domain/entities/folder.dart';
import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/host_tree_item.dart';
import '../../domain/repositories/folder_repository.dart';
import '../../domain/repositories/host_repository.dart';
import '../../domain/repositories/host_tree_repository.dart';
import '../../domain/services/host_tree.dart';

/// 在一次存储事务中读取权威快照、验证并写入树变更。
abstract class StoredHostTreeRepository implements HostTreeRepository {
  StoredHostTreeRepository({required this.folders, required this.hosts});

  final FolderRepository folders;
  final HostRepository hosts;

  Future<T> transaction<T>(Future<T> Function() action);

  Future<HostTreeSnapshot> _snapshot() async => HostTreeSnapshot(
    folders: await folders.getAll(),
    hosts: await hosts.getAll(),
  );

  @override
  Future<Folder> saveFolder(Folder folder) => transaction(() async {
    final saved = (await _snapshot()).prepareFolder(folder);
    await folders.upsert(saved);
    return saved;
  });

  @override
  Future<void> saveHost(Host host) => transaction(() async {
    await hosts.upsert((await _snapshot()).prepareHost(host));
  });

  @override
  Future<Host> saveForwardPorts(String hostId, List<ForwardPort> ports) =>
      transaction(() async {
        ForwardPort.validateAll(ports);
        final all = await hosts.getAll();
        final matches = all.where((host) => host.id == hostId);
        if (matches.isEmpty) throw StateError('所选服务已不存在');
        final host = matches.first.copyWith(
          forwardPorts: List.unmodifiable(ports),
        );
        await hosts.upsert(host);
        return host;
      });

  @override
  Future<void> move(HostTreeItem item, HostTreePlacement placement) =>
      transaction(() async {
        await _apply((await _snapshot()).planMove(item, placement));
      });

  @override
  Future<void> removeFolder(String id) => transaction(() async {
    await _apply((await _snapshot()).planRemoveFolder(id));
  });

  Future<void> _apply(HostTreeChanges changes) async {
    for (final folder in changes.folders) {
      await folders.upsert(folder);
    }
    for (final host in changes.hosts) {
      await hosts.upsert(host);
    }
    final removed = changes.removedFolderId;
    if (removed != null) await folders.remove(removed);
  }
}
