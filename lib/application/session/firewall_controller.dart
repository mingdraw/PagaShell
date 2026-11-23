import 'dart:async';

import 'package:get/get.dart';

import '../../domain/ssh/firewall.dart';
import '../../domain/ssh/ssh_engine.dart';

enum FirewallActionFilter { all, allow, deny }

enum FirewallProtocolFilter { all, tcp, udp }

class FirewallController extends GetxController {
  FirewallController({
    required this.source,
    this.queryTimeout = firewallQueryTimeout,
    this.mutateTimeout = firewallMutateTimeout,
  });

  final FirewallSource source;
  final Duration queryTimeout;
  final Duration mutateTimeout;

  final snapshot = Rxn<FirewallSnapshot>();
  final selectedBackend = Rxn<FirewallBackend>();
  final query = ''.obs;
  final actionFilter = FirewallActionFilter.all.obs;
  final protocolFilter = FirewallProtocolFilter.all.obs;
  final loading = false.obs;
  final mutating = false.obs;
  final busyRuleIds = <String>{}.obs;
  final error = RxnString();
  final actionError = RxnString();
  final notice = RxnString();
  final updatedAt = Rxn<DateTime>();

  Timer? _feedbackTimer;
  bool _enabled = false;
  bool _disposed = false;
  bool _inFlight = false;
  bool _queuedRefresh = false;
  int _generation = 0;

  bool get busy => mutating.value || busyRuleIds.isNotEmpty;

  List<FirewallRule> get rules => snapshot.value?.rules ?? const [];

  List<FirewallRule> get visibleRules {
    final term = query.value.trim().toLowerCase();
    final action = switch (actionFilter.value) {
      FirewallActionFilter.all => null,
      FirewallActionFilter.allow => FirewallAction.allow,
      FirewallActionFilter.deny => FirewallAction.deny,
    };
    final protocol = switch (protocolFilter.value) {
      FirewallProtocolFilter.all => null,
      FirewallProtocolFilter.tcp => FirewallProtocol.tcp,
      FirewallProtocolFilter.udp => FirewallProtocol.udp,
    };
    return rules
        .where(
          (rule) =>
              (action == null || rule.action == action) &&
              rule.matchesProtocolFilter(protocol) &&
              rule.matchesQuery(term),
        )
        .toList(growable: false);
  }

  void setEnabled(bool enabled) {
    if (_disposed || enabled == _enabled) return;
    _enabled = enabled;
    _generation++;
    loading.value = false;
    if (enabled) {
      unawaited(refreshFirewall());
    }
  }

  Future<void> selectBackend(FirewallBackend backend) async {
    if (_disposed || busy) return;
    selectedBackend.value = backend;
    clearActionFeedback();
    await refreshFirewall(backend: backend);
  }

  Future<void> refreshFirewall({FirewallBackend? backend}) async {
    if (_disposed || !_enabled) return;
    if (_inFlight) {
      _queuedRefresh = true;
      return;
    }
    _inFlight = true;
    _queuedRefresh = false;
    final generation = _generation;
    final requestedBackend = backend ?? selectedBackend.value;
    loading.value = true;
    try {
      final result = await source
          .readFirewall(backend: requestedBackend)
          .timeout(queryTimeout);
      if (_disposed || !_enabled || generation != _generation) return;
      snapshot.value = result;
      if (selectedBackend.value != null &&
          !result.availableBackends.contains(selectedBackend.value)) {
        selectedBackend.value = null;
      }
      updatedAt.value = DateTime.now();
      error.value = null;
    } on Object catch (e) {
      if (_disposed || !_enabled || generation != _generation) return;
      error.value = e is TimeoutException
          ? '防火墙查询超时，请重试'
          : e is SshEngineException
          ? e.message
          : '无法读取防火墙配置，请重试';
    } finally {
      _inFlight = false;
      if (!_disposed && _enabled) {
        loading.value = false;
        if (_queuedRefresh) {
          _queuedRefresh = false;
          unawaited(refreshFirewall());
        }
      }
    }
  }

  Future<void> addRules(List<FirewallRuleInput> inputs) async {
    final current = snapshot.value;
    if (_disposed || !_enabled || current == null || busy) {
      throw const SshEngineException('防火墙状态未就绪，请刷新后重试');
    }
    mutating.value = true;
    clearActionFeedback();
    try {
      await source
          .addFirewallRules(current.backend, inputs)
          .timeout(mutateTimeout);
      if (_disposed) return;
      notice.value = '防火墙规则已创建';
      _expireActionFeedback();
      await refreshFirewall(backend: current.backend);
    } on TimeoutException {
      throw const SshEngineException('防火墙操作超时，请刷新规则列表确认状态');
    } finally {
      if (!_disposed) mutating.value = false;
    }
  }

  Future<void> deleteRule(FirewallRule rule) async {
    if (_disposed || !_enabled || busy) {
      throw const SshEngineException('防火墙状态未就绪，请刷新后重试');
    }
    mutating.value = true;
    busyRuleIds.add(rule.id);
    clearActionFeedback();
    try {
      await source.deleteFirewallRule(rule).timeout(mutateTimeout);
      if (_disposed) return;
      notice.value = '防火墙规则已删除';
      _expireActionFeedback();
      await refreshFirewall(backend: rule.backend);
    } on TimeoutException {
      throw const SshEngineException('防火墙操作超时，请刷新规则列表确认状态');
    } finally {
      if (!_disposed) {
        mutating.value = false;
        busyRuleIds.remove(rule.id);
      }
    }
  }

  Future<void> runServiceAction(FirewallServiceAction action) async {
    final current = snapshot.value;
    if (_disposed || !_enabled || current == null || busy) {
      throw const SshEngineException('防火墙状态未就绪，请刷新后重试');
    }
    mutating.value = true;
    clearActionFeedback();
    try {
      await source
          .runFirewallServiceAction(current.backend, action)
          .timeout(mutateTimeout);
      if (_disposed) return;
      notice.value = switch (action) {
        FirewallServiceAction.enable => '防火墙已开启',
        FirewallServiceAction.disable => '防火墙已关闭',
        FirewallServiceAction.reload => '防火墙规则已重载',
      };
      _expireActionFeedback();
      await refreshFirewall(backend: current.backend);
    } on TimeoutException {
      throw const SshEngineException('防火墙操作超时，请刷新规则列表确认状态');
    } finally {
      if (!_disposed) mutating.value = false;
    }
  }

  void clearActionFeedback() {
    _feedbackTimer?.cancel();
    actionError.value = null;
    notice.value = null;
  }

  void _expireActionFeedback() {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(seconds: 8), clearActionFeedback);
  }

  @override
  void onClose() {
    _disposed = true;
    _generation++;
    _feedbackTimer?.cancel();
    super.onClose();
  }
}
