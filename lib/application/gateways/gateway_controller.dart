import '../../domain/entities/host.dart';
import '../../domain/repositories/host_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../folders/folder_controller.dart';
import '../hosts/host_controller.dart';
import '../hosts/host_tree_controller.dart';
import '../session/session_controller.dart';

/// 网关复用 SSH 端点和树操作，仓库按分组隔离服务与网关。
class GatewayController extends HostController {
  GatewayController({
    required super.repository,
    required super.secretStore,
    required super.treeRepository,
    required this.services,
    super.sessions,
  }) : _sessions = sessions,
       _gateways = repository;

  final SessionController? _sessions;
  final HostRepository _gateways;
  final HostRepository services;

  /// 启动前读取已保存配置，避免树订阅尚未刷新时沿用旧端点。
  Future<Host?> findSaved(String id) async {
    for (final gateway in await _gateways.getAll()) {
      if (gateway.id == id) return gateway;
    }
    return null;
  }

  @override
  Future<void> remove(String id) async {
    if ((await services.getAll()).any((host) => host.gatewayId == id)) {
      throw const SshEngineException('网关正在被服务使用，请先修改服务的网关配置');
    }
    final password = await passwordOf(id);
    // Restore system settings before deleting credentials or metadata. A failed
    // restoration must leave the gateway available for retry.
    await _sessions?.closeProxyForHost(id);
    // 钥匙串不可用时保留网关，允许用户重试删除。
    await clearPassword(id);
    try {
      // 数据库在事务中复查引用，防止检查后被另一个服务绑定。
      await _gateways.remove(id);
    } on Object {
      if (password != null) {
        try {
          await savePassword(id, password);
        } on Object {
          throw const SecretStoreException('网关删除失败，密码恢复失败，请解锁系统钥匙串后重新保存网关密码');
        }
      }
      rethrow;
    }
    await _sessions?.closeForwardForHost(id);
  }
}

class GatewayFolderController extends FolderController {
  GatewayFolderController({
    required super.folderRepository,
    required super.hostRepository,
    required super.treeRepository,
  });
}

class GatewayTreeController extends HostTreeController {
  GatewayTreeController({
    required super.repository,
    required GatewayFolderController folders,
    required GatewayController hosts,
  }) : super(folders: folders, hosts: hosts);
}
