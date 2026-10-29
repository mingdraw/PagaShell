import '../entities/folder.dart';
import '../entities/forward_port.dart';
import '../entities/host.dart';
import '../entities/host_tree_item.dart';

/// 文件夹与服务的联合写入边界。
abstract interface class HostTreeRepository {
  Future<Folder> saveFolder(Folder folder);
  Future<void> saveHost(Host host);
  Future<Host> saveForwardPorts(String hostId, List<ForwardPort> ports);
  Future<void> move(HostTreeItem item, HostTreePlacement placement);
  Future<void> removeFolder(String id);
}
