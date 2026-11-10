import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/network_ports_controller.dart';
import '../../domain/ssh/network_ports.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';
import 'network_port_termination_dialog.dart';
import 'process_termination_dialog.dart';

class NetworkPortsPanel extends StatefulWidget {
  const NetworkPortsPanel({
    required this.source,
    required this.active,
    super.key,
  });
  final NetworkPortsSource? source;
  final bool active;
  @override
  State<NetworkPortsPanel> createState() => _NetworkPortsPanelState();
}

class _NetworkPortsPanelState extends State<NetworkPortsPanel> {
  NetworkPortsController? _controller;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _showingTermination = false;

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
    _controller?.setEnabled(widget.active);
  }

  @override
  void didUpdateWidget(NetworkPortsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _controller?.onClose();
      _createController();
    } else {
      _controller?.setEnabled(widget.active);
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
                if (_controller case final controller?)
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
          child: Semantics(
            label: '搜索网络端口'.tr,
            child: AppTextFormField(
              key: const ValueKey('network-ports-search'),
              controller: _search,
              compact: true,
              decoration: AppInputDecoration(
                hintText: '搜索端口号或进程名'.tr,
                suffixIcon: const AppIcon(AppIcons.search, size: 14),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Obx(
            () => Row(
              children: [
                Expanded(
                  child: Text(
                    '@shown / @total 个端口'.trParams({
                      'shown': '${controller.visiblePorts.length}',
                      'total': '${controller.ports.length}',
                    }),
                    key: const ValueKey('network-ports-count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _secondary,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
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
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Obx(() {
            final entries = controller.visiblePorts;
            final actionError = controller.actionError.value;
            final error = actionError ?? controller.error.value;
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
                  if (error != null || notice != null || limited || missing)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .4,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              error != null
                                  ? '${actionError == null && hasData ? '${'更新失败，显示上次数据'.tr}\n' : ''}${AppTranslations.error(error)}${failures.isEmpty ? '' : '\n${failures.map((f) => 'PID ${f.pid} · ${AppTranslations.error(f.message)}').join('\n')}'}'
                                  : notice != null
                                  ? notice.tr
                                  : (limited
                                            ? '当前权限可能无法显示全部端口及进程信息'
                                            : '部分端口的进程信息不可见')
                                        .tr,
                              key: const ValueKey('network-ports-message'),
                              style: _secondary.copyWith(
                                color: error != null
                                    ? StatusColors.failed
                                    : notice != null
                                    ? AppTheme.serverStatusCpuColor
                                    : AppTheme.terminalMutedForeground,
                              ),
                            ),
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
                                Obx(() => _card(controller, entries[index])),
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
    final processes = port.processes
        .map((p) => '${p.name.isEmpty ? '进程'.tr : p.name} (${p.pid})')
        .join(' · ');
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
                Text(
                  '${port.port}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
                Expanded(
                  child: shadcn.Tooltip(
                    tooltip: (_) => shadcn.TooltipContainer(
                      child: Text(processes.isEmpty ? '进程信息不可见'.tr : processes),
                    ),
                    child: Text(
                      processes.isEmpty ? '进程信息不可见'.tr : processes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: _secondary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _stopButton(controller, port),
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

  Widget _stopButton(
    NetworkPortsController controller,
    ListeningNetworkPort port,
  ) {
    final pending = controller.preparing.toSet()
      ..addAll(controller.terminating.toSet());
    final busy = port.processes.any((p) => pending.contains(p.pid));
    final available =
        widget.active &&
        !_showingTermination &&
        !busy &&
        controller.canTerminatePort(port);
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
        tooltip:
            (controller.canTerminatePort(port) ? '结束此端口的全部进程' : '无法核对此端口的全部进程')
                .tr,
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
