import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/firewall_controller.dart';
import '../../domain/ssh/firewall.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../shell/workspace_visibility.dart';
import '../theme/app_theme.dart';
import 'firewall_confirm_dialog.dart';
import 'firewall_rule_dialog.dart';
import 'terminal_search_field.dart';

class FirewallPanel extends StatefulWidget {
  const FirewallPanel({required this.source, required this.active, super.key});

  final FirewallSource? source;
  final bool active;

  @override
  State<FirewallPanel> createState() => _FirewallPanelState();
}

class _FirewallPanelState extends State<FirewallPanel>
    with WorkspaceVisibilityObserver<FirewallPanel> {
  FirewallController? _controller;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _showingDialog = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
    _createController();
  }

  void _searchChanged() => _controller?.query.value = _search.text;

  void _createController() {
    _controller = widget.source == null
        ? null
        : FirewallController(source: widget.source!);
    _searchChanged();
    onWorkspaceVisibilityChanged();
  }

  @override
  void onWorkspaceVisibilityChanged() =>
      _controller?.setEnabled(widget.active && workspaceVisible);

  @override
  void didUpdateWidget(FirewallPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _controller?.onClose();
      _createController();
    } else {
      onWorkspaceVisibilityChanged();
    }
  }

  @override
  void dispose() {
    _controller?.onClose();
    _search.removeListener(_searchChanged);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _canAddRule(FirewallController controller) {
    final snapshot = controller.snapshot.value;
    if (snapshot == null || controller.busy || !widget.active) return false;
    return snapshot.isActive ||
        snapshot.backend == FirewallBackend.nftables ||
        snapshot.backend == FirewallBackend.iptables;
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('firewall-panel'),
    color: AppTheme.terminalBackground,
    child: Column(
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                const AppIcon(
                  AppIcons.firewall,
                  size: 15,
                  color: AppTheme.serverStatusCpuColor,
                ),
                const SizedBox(width: 8),
                Expanded(child: _heading()),
                if (_controller case final controller?) ...[
                  Obx(
                    () => AppIconButton(
                      key: const ValueKey('firewall-create'),
                      semanticLabel: '创建规则'.tr,
                      tooltip: '创建规则'.tr,
                      icon: const AppIcon(AppIcons.plus, size: 15),
                      onPressed: _canAddRule(controller) && !_showingDialog
                          ? () => unawaited(_openCreateDialog(controller))
                          : null,
                    ),
                  ),
                  Obx(
                    () => AppIconButton(
                      key: const ValueKey('firewall-refresh'),
                      semanticLabel: '刷新防火墙规则'.tr,
                      tooltip: '刷新防火墙规则'.tr,
                      icon: const AppIcon(AppIcons.refreshCw, size: 15),
                      onPressed:
                          controller.loading.value ||
                              controller.busy ||
                              !widget.active
                          ? null
                          : () => unawaited(controller.refreshFirewall()),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _heading() {
    final title = Text(
      '防火墙'.tr,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    final controller = _controller;
    if (controller == null) return title;
    return LayoutBuilder(
      builder: (_, constraints) => Obx(() {
        final updated = controller.updatedAt.value;
        final time = updated == null
            ? null
            : '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}:${updated.second.toString().padLeft(2, '0')}';
        return Row(
          children: [
            Flexible(child: title),
            if (time != null) ...[
              const SizedBox(width: 8),
              Text(
                constraints.maxWidth >= 200
                    ? '更新于 @time'.trParams({'time': time})
                    : time,
                key: const ValueKey('firewall-updated'),
                style: _secondary.copyWith(fontSize: 10),
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _body() {
    final controller = _controller;
    if (controller == null) return _message('连接未就绪，暂无防火墙信息'.tr);
    return Obx(() {
      final snapshot = controller.snapshot.value;
      final rules = controller.visibleRules;
      final error = controller.error.value;
      final actionError = controller.actionError.value;
      final notice = controller.notice.value;
      final loading = controller.loading.value;
      final hasData = snapshot != null;
      if (!hasData && error == firewallUnsupportedSystemMessage) {
        return Center(
          key: const ValueKey('firewall-unsupported'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(
                  AppIcons.shieldOff,
                  size: 28,
                  color: AppTheme.terminalMutedForeground,
                ),
                const SizedBox(height: 10),
                Text(
                  '不支持当前系统的防火墙'.tr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.terminalForeground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '仅支持 Linux（firewalld、ufw、nftables、iptables）'.tr,
                  textAlign: TextAlign.center,
                  style: _secondary,
                ),
              ],
            ),
          ),
        );
      }
      return Column(
        children: [
          if (snapshot != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: _statusCard(controller, snapshot),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: TerminalSearchField(
              fieldKey: const ValueKey('firewall-search'),
              clearKey: const ValueKey('firewall-search-clear'),
              controller: _search,
              semanticLabel: '搜索防火墙规则'.tr,
              hintText: '搜索端口、IP、进程或描述'.tr,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: _filterBar(controller, rules.length),
          ),
          if (error != null || actionError != null || notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null)
                    Text(
                      '${hasData ? '${'更新失败，显示上次数据'.tr}\n' : ''}${AppTranslations.error(error)}',
                      key: const ValueKey('firewall-error'),
                      style: _secondary.copyWith(color: StatusColors.failed),
                    ),
                  if (actionError != null || notice != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            actionError == null
                                ? notice!.tr
                                : AppTranslations.error(actionError),
                            key: const ValueKey('firewall-feedback'),
                            style: _secondary.copyWith(
                              color: actionError == null
                                  ? AppTheme.serverStatusCpuColor
                                  : StatusColors.failed,
                            ),
                          ),
                        ),
                        AppIconButton(
                          semanticLabel: '关闭提示'.tr,
                          tooltip: '关闭提示'.tr,
                          onPressed: controller.clearActionFeedback,
                          icon: const AppIcon(AppIcons.x, size: 12),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          Expanded(
            child: rules.isEmpty
                ? _message(_emptyMessage(controller, snapshot, loading, error))
                : ListView.builder(
                    key: const ValueKey('firewall-rules-list'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                    itemCount: rules.length,
                    itemBuilder: (_, index) =>
                        Obx(() => _ruleCard(controller, rules[index])),
                  ),
          ),
        ],
      );
    });
  }

  String _emptyMessage(
    FirewallController controller,
    FirewallSnapshot? snapshot,
    bool loading,
    String? error,
  ) {
    if (loading && snapshot == null) return '正在获取防火墙规则…'.tr;
    if (error != null && snapshot == null) return '可点击刷新重试'.tr;
    if (snapshot != null && !snapshot.isActive && controller.rules.isEmpty) {
      if (snapshot.serviceActions.contains(FirewallServiceAction.enable)) {
        return '防火墙未启用，可点击上方「开启」启用防火墙'.tr;
      }
      return '暂无端口规则，可点击右上角「+」创建规则'.tr;
    }
    if (controller.query.value.trim().isNotEmpty ||
        controller.actionFilter.value != FirewallActionFilter.all ||
        controller.protocolFilter.value != FirewallProtocolFilter.all) {
      return '没有匹配的防火墙规则'.tr;
    }
    return '暂无 TCP/UDP 端口规则'.tr;
  }

  Widget _statusCard(FirewallController controller, FirewallSnapshot snapshot) {
    final active = snapshot.isActive;
    final busy = controller.busy || controller.loading.value || !widget.active;
    return shadcn.Card(
      key: const ValueKey('firewall-status-card'),
      theme: shadcn.CardTheme(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: AppTheme.terminalControlBackground,
        borderColor: AppTheme.terminalBorder,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: 5,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _backendBadge(controller, snapshot, busy: busy),
                _pill(
                  key: const ValueKey('firewall-state-badge'),
                  text: (active ? '已启用' : '未启用').tr,
                  color: active
                      ? StatusColors.ready
                      : AppTheme.serverStatusWarningColor,
                  dot: true,
                ),
                if (snapshot.version.isNotEmpty)
                  shadcn.Tooltip(
                    tooltip: (_) => shadcn.TooltipContainer(
                      child: Text(
                        '版本 @version'.trParams({'version': snapshot.version}),
                      ),
                    ),
                    child: Text(
                      snapshot.version.startsWith('v')
                          ? snapshot.version
                          : 'v${snapshot.version}',
                      key: const ValueKey('firewall-version'),
                      style: _secondary,
                    ),
                  ),
                if (snapshot.zone.isNotEmpty)
                  _pill(
                    text: snapshot.zone,
                    color: AppTheme.terminalMutedForeground,
                  ),
                if (snapshot.policy.isNotEmpty)
                  _pill(
                    text: '默认 @policy'.trParams({'policy': snapshot.policy}),
                    color: snapshot.policy == 'DROP'
                        ? AppTheme.serverStatusLoadColor
                        : AppTheme.terminalMutedForeground,
                  ),
              ],
            ),
          ),
          if (snapshot.serviceActions.isNotEmpty) ...[
            const SizedBox(width: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (snapshot.serviceActions.contains(
                  FirewallServiceAction.enable,
                ))
                  shadcn.TextButton(
                    key: const ValueKey('firewall-service-enable'),
                    size: shadcn.ButtonSize.small,
                    density: shadcn.ButtonDensity.compact,
                    onPressed: busy || _showingDialog
                        ? null
                        : () => unawaited(
                            _openServiceAction(
                              controller,
                              snapshot.backend,
                              FirewallServiceAction.enable,
                            ),
                          ),
                    child: Text(
                      '开启'.tr,
                      style: const TextStyle(
                        fontSize: 11,
                        color: StatusColors.ready,
                      ),
                    ),
                  ),
                if (snapshot.serviceActions.contains(
                  FirewallServiceAction.disable,
                ))
                  shadcn.TextButton(
                    key: const ValueKey('firewall-service-disable'),
                    size: shadcn.ButtonSize.small,
                    density: shadcn.ButtonDensity.compact,
                    onPressed: busy || _showingDialog
                        ? null
                        : () => unawaited(
                            _openServiceAction(
                              controller,
                              snapshot.backend,
                              FirewallServiceAction.disable,
                            ),
                          ),
                    child: Text(
                      '停用'.tr,
                      style: const TextStyle(
                        fontSize: 11,
                        color: StatusColors.failed,
                      ),
                    ),
                  ),
                if (snapshot.serviceActions.contains(
                  FirewallServiceAction.reload,
                )) ...[
                  if (snapshot.serviceActions.contains(
                        FirewallServiceAction.enable,
                      ) ||
                      snapshot.serviceActions.contains(
                        FirewallServiceAction.disable,
                      ))
                    const SizedBox(width: 4),
                  shadcn.TextButton(
                    key: const ValueKey('firewall-service-reload'),
                    size: shadcn.ButtonSize.small,
                    density: shadcn.ButtonDensity.compact,
                    onPressed: busy || _showingDialog
                        ? null
                        : () => unawaited(
                            _openServiceAction(
                              controller,
                              snapshot.backend,
                              FirewallServiceAction.reload,
                            ),
                          ),
                    child: Text(
                      '重载'.tr,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.serverStatusMemoryColor,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _backendBadge(
    FirewallController controller,
    FirewallSnapshot snapshot, {
    required bool busy,
  }) {
    final label = Text(
      snapshot.backend.displayName,
      key: const ValueKey('firewall-backend-name'),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppTheme.serverStatusCpuColor,
      ),
    );
    final decoration = BoxDecoration(
      color: AppTheme.serverStatusCpuColor.withValues(alpha: .14),
      border: Border.all(
        color: AppTheme.serverStatusCpuColor.withValues(alpha: .35),
      ),
      borderRadius: BorderRadius.circular(4),
    );
    if (!snapshot.canSwitchBackend) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: decoration,
        child: label,
      );
    }
    return DecoratedBox(
      decoration: decoration,
      child: AppMenuButton<FirewallBackend>(
        key: const ValueKey('firewall-backend-switcher'),
        density: shadcn.ButtonDensity.compact,
        tooltip: '切换防火墙后端'.tr,
        semanticLabel: '切换防火墙后端'.tr,
        selectedValue: snapshot.backend,
        enabled: !busy,
        items: [
          for (final item in snapshot.availableBackends)
            (item, item.displayName),
        ],
        onSelected: (backend) => unawaited(controller.selectBackend(backend)),
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            label,
            const SizedBox(width: 2),
            const AppIcon(
              AppIcons.chevronDown,
              size: 12,
              color: AppTheme.serverStatusCpuColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill({
    required String text,
    required Color color,
    bool dot = false,
    Key? key,
  }) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
        ],
        Text(text, style: TextStyle(fontSize: 10, color: color)),
      ],
    ),
  );

  Widget _filterBar(
    FirewallController controller,
    int shownCount,
  ) => LayoutBuilder(
    builder: (_, constraints) {
      final count = Text(
        '@shown / @total 条规则'.trParams({
          'shown': '$shownCount',
          'total': '${controller.rules.length}',
        }),
        key: const ValueKey('firewall-rules-count'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _secondary,
      );
      final actionGroup = SizedBox(
        width: 138,
        child: shadcn.RadioGroup<FirewallActionFilter>(
          value: controller.actionFilter.value,
          onChanged: (value) => controller.actionFilter.value = value,
          child: Row(
            children: [
              for (final item in FirewallActionFilter.values) ...[
                if (item != FirewallActionFilter.all) const SizedBox(width: 3),
                Expanded(
                  child: shadcn.RadioCard<FirewallActionFilter>(
                    key: ValueKey('firewall-filter-action-${item.name}'),
                    value: item,
                    theme: const shadcn.RadioCardTheme(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    ),
                    child: Center(
                      child: Text(
                        switch (item) {
                          FirewallActionFilter.all => '全部'.tr,
                          FirewallActionFilter.allow => '允许'.tr,
                          FirewallActionFilter.deny => '拒绝'.tr,
                        },
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      final protoGroup = SizedBox(
        width: 138,
        child: shadcn.RadioGroup<FirewallProtocolFilter>(
          value: controller.protocolFilter.value,
          onChanged: (value) => controller.protocolFilter.value = value,
          child: Row(
            children: [
              for (final item in FirewallProtocolFilter.values) ...[
                if (item != FirewallProtocolFilter.all)
                  const SizedBox(width: 3),
                Expanded(
                  child: shadcn.RadioCard<FirewallProtocolFilter>(
                    key: ValueKey('firewall-filter-proto-${item.name}'),
                    value: item,
                    theme: const shadcn.RadioCardTheme(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    ),
                    child: Center(
                      child: Text(
                        item == FirewallProtocolFilter.all
                            ? '全部'.tr
                            : item.name.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      if (constraints.maxWidth < 310) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            count,
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [actionGroup, protoGroup],
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: count),
              actionGroup,
              const SizedBox(width: 6),
              protoGroup,
            ],
          ),
        ],
      );
    },
  );

  Widget _ruleCard(FirewallController controller, FirewallRule rule) {
    final allow = rule.action == FirewallAction.allow;
    final actionColor = allow ? StatusColors.ready : StatusColors.failed;
    final protoColor = switch (rule.protocol) {
      FirewallProtocol.tcp => AppTheme.serverStatusCpuColor,
      FirewallProtocol.udp => AppTheme.serverStatusMemoryColor,
      FirewallProtocol.tcpUdp => AppTheme.serverStatusDiskColor,
    };
    final busy = controller.busy || controller.busyRuleIds.contains(rule.id);
    final canMutate = widget.active && !busy && !_showingDialog;
    final sourceDisplay = rule.isAnySource
        ? '${rule.source.isEmpty ? '0.0.0.0/0, ::/0' : rule.source} (${'任何位置'.tr})'
        : rule.source;

    return Padding(
      key: ValueKey('firewall-rule-${rule.id}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: shadcn.Card(
        theme: shadcn.CardTheme(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          filled: true,
          fillColor: AppTheme.terminalBackground,
          borderColor: AppTheme.terminalBorder,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppIcon(
                  allow ? AppIcons.circleCheck : AppIcons.circleX,
                  size: 13,
                  color: actionColor,
                ),
                const SizedBox(width: 4),
                Text(
                  (allow ? '允许' : '拒绝').tr,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: actionColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  rule.protocol.label,
                  style: _secondary.copyWith(color: protoColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    rule.port,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (rule.priority case final priority?) ...[
                  const SizedBox(width: 4),
                  shadcn.Tooltip(
                    tooltip: (_) => shadcn.TooltipContainer(
                      child: Text(
                        '优先级 @priority'.trParams({'priority': '$priority'}),
                      ),
                    ),
                    child: _pill(
                      text: 'P:$priority',
                      color: AppTheme.terminalMutedForeground,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                SizedBox.square(
                  dimension: 22,
                  child: AppIconButton(
                    key: ValueKey('firewall-rule-delete-${rule.id}'),
                    semanticLabel: '删除规则'.tr,
                    tooltip: '删除规则'.tr,
                    density: shadcn.ButtonDensity.compact,
                    icon: AppIcon(
                      busy ? AppIcons.hourglass : AppIcons.trash2,
                      size: 13,
                      color: canMutate
                          ? StatusColors.failed
                          : AppTheme.terminalMutedForeground,
                    ),
                    onPressed: canMutate
                        ? () => unawaited(_openDeleteDialog(controller, rule))
                        : null,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 36, child: Text('IP'.tr, style: _secondary)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: shadcn.SelectableText(
                      sourceDisplay,
                      style: _secondary.copyWith(
                        color: AppTheme.terminalForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (rule.usedProcesses.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text('已使用'.tr, style: _secondary),
                    ),
                    const SizedBox(width: 4),
                    Expanded(child: _usedProcesses(rule.usedProcesses)),
                  ],
                ),
              ),
            if (rule.comment.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text('描述'.tr, style: _secondary),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        rule.comment,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _secondary,
                      ),
                    ),
                  ],
                ),
              ),
            if (rule.chain.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  rule.chain,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _secondary.copyWith(fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _usedProcesses(List<FirewallUsedProcess> processes) {
    final visible = processes.take(2).toList();
    final overflow = processes.length - visible.length;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final process in visible)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.terminalControlBackground,
              border: Border.all(color: AppTheme.terminalBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              process.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.terminalForeground,
              ),
            ),
          ),
        if (overflow > 0)
          shadcn.Tooltip(
            tooltip: (_) => shadcn.TooltipContainer(
              child: Text(processes.map((p) => p.label).join('\n')),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.terminalControlBackground,
                border: Border.all(color: AppTheme.terminalBorder),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '+$overflow',
                style: _secondary.copyWith(fontSize: 10),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openCreateDialog(FirewallController controller) async {
    final snapshot = controller.snapshot.value;
    if (_showingDialog || snapshot == null || !widget.active) return;
    setState(() => _showingDialog = true);
    try {
      await AppNavigation.dialog<bool>(
        FirewallRuleDialog(
          backend: snapshot.backend,
          onSubmit: controller.addRules,
        ),
      );
    } finally {
      if (mounted) setState(() => _showingDialog = false);
    }
  }

  Future<void> _openDeleteDialog(
    FirewallController controller,
    FirewallRule rule,
  ) async {
    if (_showingDialog || !widget.active) return;
    setState(() => _showingDialog = true);
    try {
      await AppNavigation.dialog<bool>(
        FirewallDeleteRuleDialog(
          rule: rule,
          onConfirm: () => controller.deleteRule(rule),
        ),
      );
    } finally {
      if (mounted) setState(() => _showingDialog = false);
    }
  }

  Future<void> _openServiceAction(
    FirewallController controller,
    FirewallBackend backend,
    FirewallServiceAction action,
  ) async {
    if (_showingDialog || !widget.active) return;
    setState(() => _showingDialog = true);
    try {
      await AppNavigation.dialog<bool>(
        FirewallServiceActionDialog(
          backend: backend,
          action: action,
          onConfirm: () => controller.runServiceAction(action),
        ),
      );
    } finally {
      if (mounted) setState(() => _showingDialog = false);
    }
  }

  Widget _message(String value) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(value, textAlign: TextAlign.center, style: _secondary),
    ),
  );

  static const _secondary = TextStyle(
    fontSize: 11,
    color: AppTheme.terminalMutedForeground,
  );
}
