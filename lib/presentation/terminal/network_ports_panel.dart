import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/network_ports_controller.dart';
import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_copy_button.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../shell/workspace_visibility.dart';
import '../theme/app_theme.dart';
import 'network_port_termination_dialog.dart';
import 'panel_refresh_pause_button.dart';
import 'process_details_dialog.dart';
import 'process_termination_dialog.dart';
import 'terminal_search_field.dart';

class NetworkPortsPanel extends StatefulWidget {
  const NetworkPortsPanel({
    required this.source,
    required this.active,
    this.hostname,
    super.key,
  });
  final NetworkPortsSource? source;
  final bool active;
  final String? hostname;
  @override
  State<NetworkPortsPanel> createState() => _NetworkPortsPanelState();
}

class _NetworkPortsPanelState extends State<NetworkPortsPanel>
    with WorkspaceVisibilityObserver<NetworkPortsPanel> {
  NetworkPortsController? _controller;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _showingTermination = false;
  String? _lookingUpPort;

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
        : NetworkPortsController(source: widget.source!);
    _searchChanged();
    onWorkspaceVisibilityChanged();
  }

  @override
  void onWorkspaceVisibilityChanged() =>
      _controller?.setEnabled(widget.active && workspaceVisible);

  @override
  void didUpdateWidget(NetworkPortsPanel oldWidget) {
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

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('network-ports-panel'),
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
                  AppIcons.networkPorts,
                  size: 15,
                  color: AppTheme.serverStatusCpuColor,
                ),
                const SizedBox(width: 8),
                Expanded(child: _heading()),
                if (_controller case final controller?) ...[
                  PanelRefreshPauseButton(
                    key: const ValueKey('network-ports-pause'),
                    paused: controller.autoRefreshPaused,
                    onChanged: controller.setAutoRefreshPaused,
                  ),
                  Obx(
                    () => AppIconButton(
                      key: const ValueKey('network-ports-refresh'),
                      semanticLabel: '刷新网络端口'.tr,
                      tooltip: '刷新网络端口'.tr,
                      icon: const AppIcon(AppIcons.refreshCw, size: 15),
                      onPressed: controller.loading.value || !widget.active
                          ? null
                          : () => unawaited(controller.refreshPorts()),
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
      '网络端口'.tr,
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
                key: const ValueKey('network-ports-updated'),
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
    if (controller == null) return _message('连接未就绪，暂无网络端口信息'.tr);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TerminalSearchField(
            fieldKey: const ValueKey('network-ports-search'),
            clearKey: const ValueKey('network-ports-search-clear'),
            controller: _search,
            semanticLabel: '搜索网络端口'.tr,
            hintText: '搜索端口号或进程名'.tr,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: LayoutBuilder(
            builder: (_, constraints) => Obx(() {
              final count = Text(
                '@shown / @total 个端口'.trParams({
                  'shown': '${controller.visiblePorts.length}',
                  'total': '${controller.ports.length}',
                }),
                key: const ValueKey('network-ports-count'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _secondary,
              );
              final filters = SizedBox(
                width: 156,
                child: shadcn.RadioGroup<NetworkPortsFilter>(
                  value: controller.filter.value,
                  onChanged: (value) => controller.filter.value = value,
                  child: Row(
                    children: [
                      for (final filter in NetworkPortsFilter.values) ...[
                        if (filter != NetworkPortsFilter.all)
                          const SizedBox(width: 4),
                        Expanded(
                          child: shadcn.RadioCard<NetworkPortsFilter>(
                            key: ValueKey(
                              'network-ports-filter-${filter.name}',
                            ),
                            value: filter,
                            theme: const shadcn.RadioCardTheme(
                              padding: EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                filter == NetworkPortsFilter.all
                                    ? '全部'.tr
                                    : filter.name.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
              if (constraints.maxWidth < 256) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [count, const SizedBox(height: 5), filters],
                );
              }
              return Row(
                children: [
                  Expanded(child: count),
                  const SizedBox(width: 6),
                  filters,
                ],
              );
            }),
          ),
        ),
        Expanded(
          child: Obx(() {
            final entries = controller.visiblePorts;
            final actionError = controller.actionError.value;
            final error = controller.error.value;
            final notice = controller.notice.value;
            final failures = controller.actionFailures.toList();
            final loading = controller.loading.value;
            final hasData = controller.updatedAt.value != null;
            final limited = controller.limited.value;
            final missing = controller.ports.any(
              (port) => port.processes.isEmpty,
            );
            return LayoutBuilder(
              builder: (_, constraints) => Column(
                children: [
                  if (error != null ||
                      limited ||
                      missing ||
                      actionError != null ||
                      notice != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .4,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (limited || missing)
                                Text(
                                  (limited
                                          ? '当前权限可能无法显示全部端口及进程信息'
                                          : '部分端口的进程信息不可见')
                                      .tr,
                                  key: const ValueKey(
                                    'network-ports-permissions',
                                  ),
                                  style: _secondary,
                                ),
                              if (error != null)
                                Text(
                                  '${hasData ? '${'更新失败，显示上次数据'.tr}\n' : ''}${AppTranslations.error(error)}',
                                  key: const ValueKey('network-ports-message'),
                                  style: _secondary.copyWith(
                                    color: StatusColors.failed,
                                  ),
                                ),
                              if (actionError != null || notice != null)
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        actionError == null
                                            ? notice!.tr
                                            : [
                                                AppTranslations.error(
                                                  actionError,
                                                ),
                                                for (final failure in failures)
                                                  'PID ${failure.pid} · ${AppTranslations.error(failure.message)}',
                                              ].join('\n'),
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
                      ),
                    ),
                  Expanded(
                    child: entries.isEmpty
                        ? _message(
                            (loading && !hasData
                                    ? '正在获取网络端口…'
                                    : error != null && !hasData
                                    ? '可点击刷新重试'
                                    : controller.query.value
                                              .trim()
                                              .isNotEmpty ||
                                          controller.filter.value !=
                                              NetworkPortsFilter.all
                                    ? '没有匹配的网络端口'
                                    : '暂无监听端口')
                                .tr,
                          )
                        : ListView.builder(
                            key: const ValueKey('network-ports-list'),
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                            itemCount: entries.length,
                            itemBuilder: (_, index) =>
                                _card(controller, entries[index]),
                          ),
                  ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _card(NetworkPortsController controller, ListeningNetworkPort port) {
    final owners = port.processes.where((item) => item.pid > 0).toList();
    return Padding(
      key: ValueKey('network-port-${port.identity}'),
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
                _portNumber(port),
                const SizedBox(width: 8),
                Text(
                  port.protocol.name.toUpperCase(),
                  style: _secondary.copyWith(
                    color: port.protocol == NetworkPortProtocol.tcp
                        ? AppTheme.serverStatusCpuColor
                        : AppTheme.serverStatusMemoryColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _processLink(controller, port, owners)),
                const SizedBox(width: 4),
                if (owners.isNotEmpty)
                  SizedBox.square(
                    dimension: 22,
                    child: AppCopyButton(
                      key: ValueKey('network-port-copy-pid-${port.identity}'),
                      text: owners.map((owner) => owner.pid).toSet().join(','),
                      semanticLabel: '复制进程 ID'.tr,
                    ),
                  ),
                SizedBox.square(
                  dimension: 22,
                  child: port.processes.isEmpty
                      ? _stopButton(controller, port)
                      : Obx(() => _stopButton(controller, port)),
                ),
              ],
            ),
            for (final address in port.addresses)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(address.ipv6 ? 'IPv6' : 'IPv4', style: _secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: shadcn.SelectableText(
                        address.endpoint(port.port),
                        style: _secondary.copyWith(
                          color: AppTheme.terminalForeground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _portNumber(ListeningNetworkPort port) {
    final number = Text(
      '${port.port}',
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    final hostname = widget.hostname;
    if (hostname == null || hostname.isEmpty) return number;
    final address = hostname.contains(':') && !hostname.startsWith('[')
        ? '[$hostname]'
        : hostname;
    return AppIconButton.text(
      key: ValueKey('network-port-copy-host-${port.identity}'),
      semanticLabel: '复制主机端口'.tr,
      tooltip: '复制主机端口'.tr,
      density: shadcn.ButtonDensity.compact,
      icon: number,
      onPressed: () async {
        if (await copyAppText('$address:${port.port}') && mounted) {
          AppNotice.success('已复制');
        }
      },
    );
  }

  String _processLabel(NetworkPortProcess process) =>
      '${process.name.isEmpty ? '进程'.tr : process.name} (${process.pid})';

  Widget _processLink(
    NetworkPortsController controller,
    ListeningNetworkPort port,
    List<NetworkPortProcess> owners,
  ) {
    final showDetails =
        widget.active && controller.canTerminate && owners.isNotEmpty;
    final text = Text(
      owners.isEmpty ? '进程信息不可见'.tr : owners.map(_processLabel).join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: showDetails
          ? _secondary.copyWith(decoration: TextDecoration.underline)
          : _secondary,
    );
    return Align(
      alignment: Alignment.centerRight,
      child: showDetails
          ? Builder(
              builder: (anchor) => shadcn.TextButton(
                key: ValueKey('network-port-process-${port.identity}'),
                size: shadcn.ButtonSize.small,
                density: shadcn.ButtonDensity.compact,
                onPressed: _lookingUpPort != null
                    ? null
                    : () {
                        if (owners.length == 1) {
                          unawaited(
                            _openProcess(controller, port, owners.single),
                          );
                        } else {
                          shadcn.showDropdown<void>(
                            context: anchor,
                            builder: (_) => shadcn.DropdownMenu(
                              children: appMenuItems(
                                [
                                  for (final owner in owners)
                                    (owner, _processLabel(owner)),
                                ],
                                (owner) => unawaited(
                                  _openProcess(controller, port, owner),
                                ),
                              ),
                            ),
                          );
                        }
                      },
                child: _lookingUpPort == port.identity
                    ? const SizedBox.square(
                        key: ValueKey('network-port-process-loading'),
                        dimension: 12,
                        child: shadcn.CircularProgressIndicator(),
                      )
                    : text,
              ),
            )
          : text,
    );
  }

  Future<void> _openProcess(
    NetworkPortsController controller,
    ListeningNetworkPort port,
    NetworkPortProcess owner,
  ) async {
    if (_lookingUpPort != null) return;
    setState(() => _lookingUpPort = port.identity);
    final RemoteProcess process;
    try {
      process = await controller.locateProcess(port, owner);
    } on Object catch (error) {
      if (mounted && widget.active && _controller == controller) {
        AppNotice.error(
          error is SshEngineException ? error.message : '无法读取进程详情，请重试',
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _lookingUpPort = null);
    }
    if (!mounted || !widget.active || _controller != controller) return;
    await AppNavigation.dialog<void>(
      ProcessDetailsDialog(
        process: process,
        readDetails: controller.readProcessDetails,
      ),
    );
  }

  Widget _stopButton(
    NetworkPortsController controller,
    ListeningNetworkPort port,
  ) {
    final busy = port.processes.any(
      (p) =>
          controller.preparing.contains(p.pid) ||
          controller.terminating.contains(p.pid),
    );
    final canStop = controller.canTerminatePort(port);
    final available = widget.active && !_showingTermination && !busy && canStop;
    final icon = AppIcon(
      busy ? AppIcons.hourglass : AppIcons.square,
      size: 13,
      color: available ? StatusColors.failed : AppTheme.terminalMutedForeground,
    );
    return SizedBox.square(
      dimension: 22,
      child: AppIconButton(
        key: ValueKey('network-port-stop-${port.identity}'),
        semanticLabel: '结束全部进程'.tr,
        tooltip: (canStop ? '结束此端口的全部进程' : '无法核对此端口的全部进程').tr,
        density: shadcn.ButtonDensity.compact,
        icon: icon,
        onPressed: available
            ? () => unawaited(_requestTermination(controller, port))
            : null,
      ),
    );
  }

  Future<void> _requestTermination(
    NetworkPortsController controller,
    ListeningNetworkPort port,
  ) async {
    if (_showingTermination || !widget.active) return;
    setState(() => _showingTermination = true);
    try {
      final processes = await controller.prepareTermination(port);
      if (processes == null ||
          processes.isEmpty ||
          !mounted ||
          !widget.active ||
          !identical(controller, _controller)) {
        return;
      }
      final confirmed = await AppNavigation.dialog<bool>(
        processes.length == 1
            ? ProcessTerminationDialog(
                key: const ValueKey('network-port-terminate-confirmation'),
                process: processes.single,
                name: processes.single.name.split('/').last.isEmpty
                    ? processes.single.name
                    : processes.single.name.split('/').last,
              )
            : NetworkPortTerminationDialog(
                key: const ValueKey('network-port-terminate-confirmation'),
                port: port,
                processes: processes,
              ),
      );
      if (confirmed == true &&
          mounted &&
          widget.active &&
          identical(controller, _controller)) {
        await controller.terminate(port, processes);
      }
    } finally {
      if (mounted) setState(() => _showingTermination = false);
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
