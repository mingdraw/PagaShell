import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';

typedef _DockerResourceSnapshot = ({
  int revision,
  List<DockerResource> resources,
});

typedef DockerPendingAction = ({
  String resourceId,
  DockerContainerAction? action,
  DockerImageAction? imageAction,
});

class DockerResourceState {
  final RxList<DockerResource> resources = <DockerResource>[].obs;
  final RxString query = ''.obs;
  final RxBool loading = false.obs;
  final RxnString error = RxnString();
  final Rxn<DateTime> updatedAt = Rxn<DateTime>();
  int _revision = 0;
  int _nextRequest = 0;

  List<DockerResource> get visibleResources => resources
      .where((resource) => resource.matches(query.value))
      .toList(growable: false);
}

/// 分类各自保留列表和搜索；只刷新当前可见分类，详情另行按需读取。
class DockerManagerController extends GetxController {
  DockerManagerController({
    required this.source,
    this.interval = const Duration(seconds: 5),
    this.timeout = dockerQueryTimeout,
  });

  final DockerManagerSource source;
  final Duration interval;
  final Duration timeout;
  final Rx<DockerResourceKind> selected = DockerResourceKind.container.obs;
  final states = {
    for (final kind in DockerResourceKind.values) kind: DockerResourceState(),
  };
  DockerResourceState get current => states[selected.value]!;
  final Rxn<DockerPendingAction> pendingAction = Rxn<DockerPendingAction>();
  bool get canMutate => source is DockerContainerActions;
  bool get canMutateImages => source is DockerImageActions;
  bool get busy => pendingAction.value != null;
  Timer? _timer;
  bool _enabled = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _refreshAgain = false;
  bool _manualRefreshQueued = false;
  bool _automaticRefreshPaused = false;
  int _failureRevision = 0;
  int _generation = 0;
  bool _refreshAfterAction = false;

  void setEnabled(bool enabled) {
    if (_disposed || enabled == _enabled) return;
    _enabled = enabled;
    _generation++;
    _timer?.cancel();
    _refreshAgain = false;
    _manualRefreshQueued = false;
    for (final state in states.values) {
      state.loading.value = false;
    }
    if (enabled) {
      final manual = _refreshAfterAction;
      _refreshAfterAction = false;
      unawaited(_refreshResources(automatic: !manual));
    }
  }

  void select(DockerResourceKind kind) {
    if (_disposed || selected.value == kind) return;
    selected.value = kind;
    _timer?.cancel();
    if (_enabled) unawaited(_refreshResources(automatic: true));
  }

  /// 工具栏手动刷新；只有手动请求成功后才能解除错误造成的暂停。
  Future<void> refreshResources() => _refreshResources(automatic: false);

  Future<void> _refreshResources({required bool automatic}) async {
    if (_disposed ||
        !_enabled ||
        busy ||
        (automatic && _automaticRefreshPaused)) {
      return;
    }
    if (_inFlight) {
      _refreshAgain = true;
      if (!automatic) _manualRefreshQueued = true;
      return;
    }
    _timer?.cancel();
    _inFlight = true;
    _refreshAgain = false;
    _manualRefreshQueued = false;
    final generation = _generation;
    final failureRevision = _failureRevision;
    final kind = selected.value;
    final state = states[kind]!;
    final revision = ++state._nextRequest;
    state.loading.value = true;
    try {
      final resources = await _withinTimeout(source.readDockerResources(kind));
      if (!_isCurrent(generation)) return;
      _applyResources(state, resources, revision);
      if (!automatic) _resumeAutomaticRefresh(failureRevision);
    } on Object catch (e) {
      if (!_isCurrent(generation) ||
          revision <= state._revision ||
          failureRevision != _failureRevision) {
        return;
      }
      state.error.value = e is SshEngineException
          ? e.message
          : '无法读取 Docker 列表，请重试';
      _pauseAutomaticRefresh();
    } finally {
      _inFlight = false;
      if (!_disposed) {
        state.loading.value = false;
        if (_enabled && (!_automaticRefreshPaused || _manualRefreshQueued)) {
          final manual = _manualRefreshQueued;
          _scheduleRefresh(
            manual ||
                    _refreshAgain ||
                    kind != selected.value ||
                    generation != _generation
                ? Duration.zero
                : interval,
            automatic: !manual,
          );
        }
      }
    }
  }

  Future<DockerDetails> readDetails(DockerResource resource) async {
    if (_disposed || !_enabled) {
      throw const SshEngineException('Docker 管理连接已关闭');
    }
    if (busy) throw const SshEngineException('容器正在执行操作，请稍后查看信息');
    final generation = _generation;
    final failureRevision = _failureRevision;
    var active = true;
    void checkCurrent() {
      if (!active || !_isCurrent(generation)) {
        throw const SshEngineException('Docker 管理连接已关闭');
      }
    }

    try {
      final (details, snapshot) = await _withinTimeout(
        _readCurrentDetails(resource, checkCurrent),
      );
      checkCurrent();
      if (snapshot != null) {
        _applyResources(
          states[resource.kind]!,
          snapshot.resources,
          snapshot.revision,
        );
      }
      _resumeAutomaticRefresh(failureRevision);
      return details;
    } on Object {
      if (_isCurrent(generation) && failureRevision == _failureRevision) {
        _pauseAutomaticRefresh();
      }
      rethrow;
    } finally {
      active = false;
    }
  }

  Future<(DockerDetails, _DockerResourceSnapshot?)> _readCurrentDetails(
    DockerResource resource,
    void Function() checkCurrent,
  ) async {
    var target = resource;
    _DockerResourceSnapshot? snapshot;
    late final DockerDetails details;
    try {
      details = await source.readDockerDetails(target);
    } on SshEngineException catch (e) {
      checkCurrent();
      if (resource.kind != DockerResourceKind.container ||
          e.message != 'Docker 资源可能已移除，请刷新后重试') {
        rethrow;
      }
      // 外部更新可能重建同名容器；只在明确不存在时重新解析其当前 ID。
      final revision = ++states[resource.kind]!._nextRequest;
      final resources = await source.readDockerResources(
        DockerResourceKind.container,
      );
      checkCurrent();
      final matches = resources
          .where(
            (candidate) =>
                candidate.kind == resource.kind &&
                candidate.name == resource.name,
          )
          .toList();
      if (matches.length != 1 || matches.single.id == resource.id) rethrow;
      target = matches.single;
      snapshot = (revision: revision, resources: resources);
      details = await source.readDockerDetails(target);
    }
    checkCurrent();
    if (details.resource.identity != target.identity ||
        (snapshot != null && details.resource.name != resource.name)) {
      throw const SshEngineException('Docker 资源已变化，请刷新后重试');
    }
    return (details, snapshot);
  }

  bool _isCurrent(int generation) =>
      !_disposed && _enabled && generation == _generation;

  Future<DockerActionResult> runContainerAction(
    DockerResource container,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) async {
    if (_disposed || !_enabled) {
      throw const SshEngineException('Docker 管理连接已关闭');
    }
    if (!canMutate) throw const SshEngineException('此连接不支持 Docker 容器操作');
    if (busy) throw const SshEngineException('容器正在执行其他操作，请稍后再试');
    if (container.kind != DockerResourceKind.container) {
      throw const SshEngineException('此操作仅支持容器');
    }
    return _runAction(
      pending: (
        resourceId: container.identity,
        action: action,
        imageAction: null,
      ),
      run: () => (source as DockerContainerActions).runDockerContainerAction(
        container,
        action,
        targetImage: targetImage,
        forcePull: forcePull,
      ),
      failureMessage: 'Docker 容器操作失败，请刷新列表检查',
    );
  }

  Future<DockerActionResult> runImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) async {
    if (!canMutateImages) throw const SshEngineException('此连接不支持 Docker 镜像操作');
    if (action == DockerImageAction.delete) {
      if (image == null || image.kind != DockerResourceKind.image) {
        throw const SshEngineException('此操作仅支持镜像');
      }
      if (image.imageInUse != false) {
        throw SshEngineException(
          image.imageInUse == true ? '镜像正在被容器使用，无法删除' : '无法核对镜像使用状态，请刷新后重试',
        );
      }
    } else if (image != null) {
      throw const SshEngineException('Docker 操作参数无效');
    }
    return _runAction(
      pending: (
        resourceId: image?.identity ?? 'images:prune',
        action: null,
        imageAction: action,
      ),
      run: () => (source as DockerImageActions).runDockerImageAction(
        action,
        image: image,
      ),
      failureMessage: 'Docker 镜像操作失败，请刷新列表检查',
    );
  }

  Future<DockerActionResult> _runAction({
    required DockerPendingAction pending,
    required Future<DockerActionResult> Function() run,
    required String failureMessage,
  }) async {
    if (_disposed || !_enabled) {
      throw const SshEngineException('Docker 管理连接已关闭');
    }
    if (busy) throw const SshEngineException('Docker 正在执行其他操作，请稍后再试');
    _timer?.cancel();
    _generation++;
    _refreshAgain = false;
    _manualRefreshQueued = false;
    for (final state in states.values) {
      state.loading.value = false;
    }
    pendingAction.value = pending;
    var succeeded = false;
    try {
      final result = await run();
      succeeded = true;
      return result;
    } on Object catch (error) {
      if (!_disposed) _pauseAutomaticRefresh();
      if (error is SshEngineException) rethrow;
      throw SshEngineException(failureMessage);
    } finally {
      pendingAction.value = null;
      if (succeeded && !_disposed) {
        _refreshAfterAction = true;
        if (_enabled) {
          _refreshAfterAction = false;
          await refreshResources();
        }
      }
    }
  }

  void _applyResources(
    DockerResourceState state,
    List<DockerResource> resources,
    int revision,
  ) {
    // 轮询与详情重查共用请求顺序，迟到的旧快照不能覆盖新结果。
    if (revision <= state._revision) return;
    state._revision = revision;
    state.resources.value = resources;
    state.updatedAt.value = DateTime.now();
    state.error.value = null;
  }

  void _pauseAutomaticRefresh() {
    _automaticRefreshPaused = true;
    _failureRevision++;
    _refreshAgain = false;
    _manualRefreshQueued = false;
    _timer?.cancel();
  }

  void _resumeAutomaticRefresh(int failureRevision) {
    if (failureRevision != _failureRevision) return;
    final wasPaused = _automaticRefreshPaused;
    _automaticRefreshPaused = false;
    if (wasPaused && !_inFlight) _scheduleRefresh(interval);
  }

  void _scheduleRefresh(Duration delay, {bool automatic = true}) {
    if (_disposed ||
        !_enabled ||
        busy ||
        (automatic && _automaticRefreshPaused)) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      delay,
      () => unawaited(_refreshResources(automatic: automatic)),
    );
  }

  Future<T> _withinTimeout<T>(Future<T> request) async {
    try {
      return await request.timeout(timeout);
    } on TimeoutException {
      throw const SshEngineException('Docker 查询超时，请重试');
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.onClose();
  }
}
