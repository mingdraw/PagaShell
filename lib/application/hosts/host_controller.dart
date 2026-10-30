import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/host_tree_item.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/repositories/host_repository.dart';
import '../../domain/repositories/host_tree_repository.dart';
import '../../domain/vault/secret_store.dart';
import '../session/session.dart';
import '../session/session_controller.dart';

/// 主机列表控制器：订阅仓库变化，提供搜索过滤与增删改入口，
/// 并维护「主机自有密码」（在编辑对话框中直接填写、不建凭证的登录方式）。
///
/// 密码密文经 [SecretStore] 进系统钥匙串，引用键按主机 id 派生，
/// 不落库、不进日志。依赖通过构造函数显式注入（装配见 AppBinding）。
class HostController extends GetxController {
  HostController({
    required this._repository,
    required this._secretStore,
    required this._treeRepository,
    this._sessions,
  });

  final HostRepository _repository;
  final SecretStore _secretStore;
  final HostTreeRepository _treeRepository;
  final SessionController? _sessions;

  final RxList<Host> hosts = <Host>[].obs;

  /// 侧边栏搜索词。
  final RxString searchQuery = ''.obs;

  StreamSubscription<List<Host>>? _subscription;

  @override
  void onInit() {
    super.onInit();
    _subscription = _repository.watchAll().listen(hosts.assignAll);
  }

  @override
  void onClose() {
    _subscription?.cancel();
    super.onClose();
  }

  /// 全量列表按名称排序（命令面板用，不受侧边栏搜索词影响）。
  List<Host> get sorted {
    final result = List<Host>.of(hosts);
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  /// 侧边栏展示的过滤后列表（按名称排序）。
  List<Host> get filtered {
    final query = searchQuery.value.trim().toLowerCase();
    final result = query.isEmpty
        ? List<Host>.of(hosts)
        : hosts.where((Host h) => h.searchText.contains(query)).toList();
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  /// [folderId] 同级（同文件夹）下是否已有同名主机（表单即时校验用，
  /// 读响应式缓存）。[excludeId] 用于编辑时排除自身。
  bool isNameTaken(String name, {String? folderId, String? excludeId}) {
    final trimmed = name.trim();
    return hosts.any(
      (h) => h.id != excludeId && h.folderId == folderId && h.name == trimmed,
    );
  }

  /// 保存主机；同级（同文件夹）下主机名必须唯一。
  ///
  /// 兜底校验读仓库权威状态，避免依赖流投递时机；表单层应先用
  /// [isNameTaken] 校验并就地提示。
  Future<void> save(Host host) => _treeRepository.saveHost(host);

  Future<Host> saveForwardPorts(String id, List<ForwardPort> ports) async {
    final session = _sessions?.findByHost(id, kind: SessionKind.portForward);
    if (session?.phase.isAlive ?? false) {
      throw StateError('请先停止端口转发再编辑配置');
    }
    final saved = await _treeRepository.saveForwardPorts(id, ports);
    _sessions?.updateForwardHost(saved);
    return saved;
  }

  Future<Host> saveProxyConfig(String id, ProxyConfig config) async {
    final session = _sessions?.findByHost(id, kind: SessionKind.dynamicProxy);
    if (session?.phase.isAlive ?? false) {
      throw StateError('请先停止动态代理再编辑配置');
    }
    final saved = await _treeRepository.saveProxyConfig(id, config);
    _sessions?.updateProxyHost(saved);
    return saved;
  }

  /// 把主机移动到 [folderId]（null 表示根级/未分组）。
  ///
  /// 目标同级已有重名主机时抛 [ArgumentError]；拖拽端应先用
  /// [isNameTaken] 预判并拒绝放置。已在目标层级时为无操作。
  Future<void> moveToFolder(String id, String? folderId) async {
    final all = await _repository.getAll();
    for (final host in all) {
      if (host.id != id) continue;
      if (host.folderId == folderId) return;
      await _treeRepository.move(
        HostTreeItem.host(id),
        HostTreePlacement(parentId: folderId),
      );
      return;
    }
  }

  /// 删除主机时一并清掉其自有密码密文。
  Future<void> remove(String id) async {
    final password = await passwordOf(id);
    await clearPassword(id);
    try {
      await _repository.remove(id);
    } on Object {
      if (password != null) await savePassword(id, password);
      rethrow;
    }
    await _sessions?.closeForwardForHost(id);
  }

  /// 保存主机自有密码（覆盖旧值）。
  Future<void> savePassword(String hostId, String password) =>
      _secretStore.put(_secretRefOf(hostId), password);

  /// 读取主机自有密码；未保存时返回 null。
  Future<String?> passwordOf(String hostId) =>
      _secretStore.read(_secretRefOf(hostId));

  /// 清除主机自有密码（切换为凭证登录时调用）。
  Future<void> clearPassword(String hostId) =>
      _secretStore.delete(_secretRefOf(hostId));

  /// 主机自有密码在钥匙串中的引用键，按主机 id 派生，无需入库。
  String _secretRefOf(String hostId) => 'sec-host-$hostId';
}
