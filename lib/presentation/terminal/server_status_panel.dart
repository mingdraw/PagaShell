import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/server_status_controller.dart';
import '../../domain/ssh/server_status.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_tree_expansion.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';
import 'server_system_logo.dart';

/// 服务状态内容；宿主侧面板保留它的状态，仅可见时采样。
class ServerStatusPanel extends StatefulWidget {
  const ServerStatusPanel({
    required this.source,
    required this.active,
    this.sourceUnavailableMessage,
    super.key,
  });

  final ServerStatusSource? source;
  final bool active;
  final String? sourceUnavailableMessage;

  @override
  State<ServerStatusPanel> createState() => _ServerStatusPanelState();
}

class _ServerStatusPanelState extends State<ServerStatusPanel> {
  ServerStatusController? _controller;
  bool _loadExpanded = false;
  bool _cpuExpanded = false;
  bool _memoryExpanded = false;
  final _expandedDisks = <String>{};
  String? _selectedNetwork;
  String? _selectedDisk;
  final _networkAnchor = Object();
  final _diskAnchor = Object();

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    final source = widget.source;
    _controller = source == null
        ? null
        : ServerStatusController(source: source);
    _syncSampling();
  }

  void _syncSampling() => _controller?.setEnabled(widget.active);

  @override
  void didUpdateWidget(ServerStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _controller?.onClose();
      _createController();
    } else {
      _syncSampling();
    }
  }

  @override
  void dispose() {
    _controller?.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('server-status-details'),
      decoration: const BoxDecoration(color: AppTheme.terminalBackground),
      child: Column(
        children: [
          SizedBox(
            key: const ValueKey('server-status-heading'),
            height: 44,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  const AppIcon(
                    AppIcons.statusOverview,
                    size: 15,
                    color: AppTheme.serverStatusCpuColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _heading()),
                  AppIconButton(
                    semanticLabel: '刷新服务状态'.tr,
                    tooltip: '刷新服务状态'.tr,
                    icon: const AppIcon(AppIcons.statusRefresh, size: 15),
                    onPressed: _controller == null
                        ? null
                        : () => _controller?.refreshStatus(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _heading() {
    final title = Text(
      '服务状态'.tr,
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
        final label = '更新于 @time'.trParams({'time': time ?? ''});
        return Row(
          children: [
            Flexible(child: title),
            if (time != null) ...[
              const SizedBox(width: 8),
              Semantics(
                label: label,
                excludeSemantics: true,
                child: Text(
                  constraints.maxWidth >= 200 ? label : time,
                  key: const ValueKey('server-status-updated'),
                  maxLines: 1,
                  style: _secondaryStyle.copyWith(fontSize: 10),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _body(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.sourceUnavailableMessage ?? '此连接不支持服务状态采集'.tr,
            textAlign: TextAlign.center,
            style: _secondaryStyle,
          ),
        ),
      );
    }
    return Obx(() {
      final status = controller.status.value;
      final error = controller.error.value;
      final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
      return SingleChildScrollView(
        key: const ValueKey('server-status-scroll'),
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _errorColor.withValues(alpha: .08),
                  border: Border.all(color: _errorColor.withValues(alpha: .3)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  AppTranslations.error(error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _errorColor),
                ),
              ),
              if (status != null) ...[
                const SizedBox(height: 6),
                Text(
                  '更新失败，显示上次数据'.tr,
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              ],
              const SizedBox(height: 16),
            ],
            if (status == null && error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(child: Text('正在获取服务状态…'.tr)),
              ),
            if (status != null) ...[
              _card(
                'basic',
                '基础'.tr,
                ServerSystemLogo(
                  system: status.sample.system,
                  systemRelease: status.sample.systemRelease,
                ),
                [
                  _fact('系统版本'.tr, status.sample.systemLabel),
                  _fact('架构'.tr, status.sample.architecture ?? '—'),
                  _fact('运行时长'.tr, _uptime(status.sample.uptimeSeconds)),
                  const SizedBox(height: 4),
                  _loadAverage(status),
                ],
              ),
              _card(
                'cpu',
                'CPU',
                const AppIcon(AppIcons.statusCpu),
                [
                  _usage(
                    '平均占用'.tr,
                    status.cpuFraction,
                    color: AppTheme.serverStatusCpuColor,
                    valueLabel: status.cpuFraction == null ? '采样中'.tr : null,
                    detail: status.cpuFraction == null ? '等待下一次采样'.tr : null,
                  ),
                  AppTreeExpansion(
                    expanded: _cpuExpanded,
                    children: [
                      const SizedBox(height: 12),
                      if (status.cpuCores.isEmpty) _empty(),
                      for (final core in status.cpuCores.entries)
                        _cpuCore(core.key, core.value),
                    ],
                  ),
                ],
                trailing: _expandButton(
                  key: const ValueKey('server-status-cpu-toggle'),
                  expanded: _cpuExpanded,
                  label: (_cpuExpanded ? '折叠 CPU 核心' : '展开 CPU 核心').tr,
                  toggle: () => setState(() => _cpuExpanded = !_cpuExpanded),
                ),
              ),
              _card(
                'memory',
                '内存'.tr,
                const AppIcon(AppIcons.statusMemory),
                [
                  _usage(
                    '内存占用'.tr,
                    status.sample.memoryFraction,
                    color: AppTheme.serverStatusMemoryColor,
                    detail:
                        '${_bytes(status.sample.memoryUsed)} / ${_bytes(status.sample.memoryTotal)}',
                  ),
                  AppTreeExpansion(
                    expanded: _memoryExpanded,
                    children: [
                      const SizedBox(height: 14),
                      _usage(
                        'Swap',
                        status.sample.swapFraction,
                        color: AppTheme.serverStatusMemoryColor,
                        detail:
                            status.sample.swapTotal == null ||
                                status.sample.swapUsed == null
                            ? '暂无可用数据'.tr
                            : status.sample.swapTotal == 0
                            ? '未启用 Swap'.tr
                            : '${_bytes(status.sample.swapUsed!)} / ${_bytes(status.sample.swapTotal!)}',
                      ),
                    ],
                  ),
                ],
                trailing: _expandButton(
                  key: const ValueKey('server-status-memory-toggle'),
                  expanded: _memoryExpanded,
                  label: (_memoryExpanded ? '折叠交换区' : '展开交换区').tr,
                  toggle: () =>
                      setState(() => _memoryExpanded = !_memoryExpanded),
                ),
              ),
              _card('storage', '硬盘'.tr, const AppIcon(AppIcons.statusDisk), [
                if (status.sample.storage.isEmpty) _empty(),
                for (
                  var index = 0;
                  index < status.sample.storage.length;
                  index++
                ) ...[
                  if (index > 0) const SizedBox(height: 16),
                  _disk(status.sample.storage[index]),
                ],
              ]),
              _ioCard(
                'network',
                '网络 I/O'.tr,
                AppIcons.statusNetwork,
                status.network,
                '接收'.tr,
                '发送'.tr,
              ),
              _ioCard(
                'disk-io',
                '磁盘 I/O'.tr,
                AppIcons.statusDisk,
                status.disks,
                '读取'.tr,
                '写入'.tr,
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _loadAverage(ServerStatus status) {
    final loads = status.sample.loadAverage;
    final cores = status.sample.cpuCores.length;
    const windows = [1, 5, 15];
    double? fraction(int index) => cores > 0 && index < loads.length
        ? (loads[index] / cores).clamp(0, 1).toDouble()
        : null;
    String percentage(int index) => cores > 0 && index < loads.length
        ? '${(loads[index] / cores * 100).toStringAsFixed(1)}%'
        : '—';
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppTheme.sidebarTransitionDuration;
    return LayoutBuilder(
      builder: (_, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .4,
                ),
                child: Text(
                  '整体负载'.tr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: duration,
                  child: _loadExpanded
                      ? const SizedBox.shrink()
                      : LayoutBuilder(
                          key: const ValueKey('server-status-load-summary'),
                          builder: (_, summaryConstraints) => Row(
                            children: [
                              Expanded(
                                child: _progress(
                                  fraction(0),
                                  AppTheme.serverStatusLoadColor,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: summaryConstraints.maxWidth * .65,
                                ),
                                child: Text(
                                  percentage(0),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _secondaryStyle.copyWith(
                                    color: _usageColor(
                                      fraction(0),
                                      AppTheme.serverStatusLoadColor,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 4),
              _expandButton(
                key: const ValueKey('server-status-load-toggle'),
                expanded: _loadExpanded,
                label: (_loadExpanded ? '折叠平均负载' : '展开平均负载').tr,
                toggle: () => setState(() => _loadExpanded = !_loadExpanded),
              ),
            ],
          ),
          AppTreeExpansion(
            expanded: _loadExpanded,
            children: [
              for (var index = 0; index < windows.length; index++) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: ValueKey('server-status-load-${windows[index]}'),
                  child: _usage(
                    '@minutes 分钟'.trParams({'minutes': '${windows[index]}'}),
                    fraction(index),
                    color: AppTheme.serverStatusLoadColor,
                    valueLabel: percentage(index),
                  ),
                ),
              ],
            ],
          ),
          if (cores == 0) ...[
            const SizedBox(height: 10),
            Text(
              '未获取核心数，无法计算负载百分比'.tr,
              style: _secondaryStyle.copyWith(fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Widget _usage(
    String label,
    double? fraction, {
    required Color color,
    String? detail,
    String? valueLabel,
    Widget? trailing,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 4), trailing],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            valueLabel ??
                (fraction == null
                    ? '—'
                    : '${(fraction * 100).toStringAsFixed(1)}%'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: _figures,
              color: _usageColor(fraction, color),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _progress(fraction, color),
      if (detail != null) ...[
        const SizedBox(height: 7),
        Text(detail, style: _secondaryStyle),
      ],
    ],
  );

  Widget _card(
    String id,
    String title,
    Widget icon,
    List<Widget> children, {
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: shadcn.Card(
      key: ValueKey('server-status-card-$id'),
      theme: shadcn.CardTheme(
        padding: const EdgeInsets.all(12),
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
              IconTheme.merge(
                data: const IconThemeData(
                  size: 15,
                  color: AppTheme.terminalMutedForeground,
                ),
                child: icon,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    ),
  );

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 4, child: Text(label, style: _secondaryStyle)),
        const SizedBox(width: 10),
        Expanded(
          flex: 5,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: _secondaryStyle.copyWith(color: AppTheme.terminalForeground),
          ),
        ),
      ],
    ),
  );

  Widget _expandButton({
    required Key key,
    required bool expanded,
    required String label,
    required VoidCallback toggle,
  }) => Semantics(
    expanded: expanded,
    child: SizedBox.square(
      dimension: 22,
      child: AppIconButton(
        key: key,
        semanticLabel: label,
        tooltip: label,
        density: shadcn.ButtonDensity.compact,
        icon: AnimatedRotation(
          turns: expanded ? .25 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : AppTheme.sidebarTransitionDuration,
          curve: Curves.easeInOutCubic,
          child: const RotatedBox(
            quarterTurns: 1,
            child: AppIcon(AppIcons.statusAngle, size: 14),
          ),
        ),
        onPressed: toggle,
      ),
    ),
  );

  Widget _disk(DiskUsage disk) {
    final expanded = _expandedDisks.contains(disk.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _usage(
          disk.name,
          disk.fraction,
          color: AppTheme.serverStatusDiskColor,
          detail: disk.used == null
              ? '未挂载或无法读取容量'.tr
              : '${_bytes(disk.used!)} / ${_bytes(disk.total)}',
          trailing: disk.filesystems.isEmpty
              ? null
              : _expandButton(
                  key: ValueKey('server-status-disk-toggle-${disk.id}'),
                  expanded: expanded,
                  label: (expanded ? '折叠挂载路径' : '展开挂载路径').tr,
                  toggle: () => setState(() {
                    if (!_expandedDisks.add(disk.id)) {
                      _expandedDisks.remove(disk.id);
                    }
                  }),
                ),
        ),
        if (disk.name != disk.devices.join(' + ')) ...[
          const SizedBox(height: 4),
          Text(disk.devices.join(' + '), style: _secondaryStyle),
        ],
        AppTreeExpansion(
          expanded: expanded,
          children: [
            for (final fs in disk.filesystems)
              Padding(
                key: ValueKey('server-status-mount-${disk.id}-${fs.mount}'),
                padding: const EdgeInsets.only(left: 8, top: 14),
                child: _usage(
                  fs.mount,
                  fs.fraction,
                  color: AppTheme.serverStatusDiskColor,
                  detail: '${_bytes(fs.used)} / ${_bytes(fs.total)}',
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _ioCard(
    String id,
    String title,
    AppIcons icon,
    Map<String, IoRate> rates,
    String readLabel,
    String writeLabel,
  ) {
    var selected = id == 'network' ? _selectedNetwork : _selectedDisk;
    if (!rates.containsKey(selected)) selected = rates.keys.firstOrNull;
    if (id == 'network') {
      _selectedNetwork = selected;
    } else {
      _selectedDisk = selected;
    }
    final rate = rates[selected];
    final device = selected;
    return LayoutBuilder(
      builder: (_, constraints) => _card(
        id,
        title,
        AppIcon(icon),
        [
          if (device == null)
            _empty()
          else
            Row(
              children: [
                Expanded(child: _ioValue('↓ $readLabel', rate?.readPerSecond)),
                const SizedBox(width: 8),
                Expanded(
                  child: _ioValue('↑ $writeLabel', rate?.writePerSecond),
                ),
              ],
            ),
        ],
        trailing: device == null
            ? null
            : SizedBox(
                width: math.min(
                  180,
                  math.max(0, constraints.maxWidth - 26) * .42,
                ),
                child: _ioSelector(id, device, rates.keys),
              ),
      ),
    );
  }

  Widget _ioSelector(String id, String selected, Iterable<String> devices) {
    final anchor = id == 'network' ? _networkAnchor : _diskAnchor;
    return Semantics(
      label: (id == 'network' ? '选择网卡' : '选择硬盘').tr,
      child: shadcn.OverlayAnchor(
        anchor: anchor,
        child: shadcn.Select<String>(
          key: ValueKey('server-status-$id-select'),
          value: selected,
          expandIcon: const RotatedBox(
            quarterTurns: 2,
            child: AppIcon(AppIcons.statusAngle, size: 12),
          ),
          theme: shadcn.SelectTheme(
            adaptiveOverlay: false,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            popupConstraints: const BoxConstraints(maxHeight: 240),
            overlayConfiguration: shadcn.PopoverConfiguration(
              anchor: shadcn.LinkedAnchor(anchor),
              alignment: Alignment.topCenter,
              offset: const Offset(0, 4),
              widthConstraint: shadcn.PopoverConstraint.anchorFixedSize,
            ),
          ),
          itemBuilder: (_, value) => Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _secondaryStyle.copyWith(color: AppTheme.terminalForeground),
          ),
          popup: shadcn.SelectPopup<String>(
            key: ValueKey('server-status-$id-popup'),
            items: shadcn.SelectItemList(
              children: [
                for (final name in devices)
                  shadcn.SelectItemButton<String>(
                    value: name,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ).call,
          onChanged: (value) => setState(() {
            if (id == 'network') {
              _selectedNetwork = value;
            } else {
              _selectedDisk = value;
            }
          }),
        ),
      ),
    );
  }

  Widget _ioValue(String label, double? value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: _secondaryStyle),
      const SizedBox(height: 6),
      Text(
        _speed(value),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _secondaryStyle.copyWith(color: AppTheme.terminalForeground),
      ),
    ],
  );

  Widget _cpuCore(int id, double? fraction) => Padding(
    key: ValueKey('server-status-cpu-core-$id'),
    padding: const EdgeInsets.only(left: 8, bottom: 8),
    child: Row(
      children: [
        SizedBox(
          width: AppTheme.serverStatusCoreLabelWidth,
          child: Text('CPU $id', style: _secondaryStyle),
        ),
        const SizedBox(width: 8),
        Expanded(child: _progress(fraction, AppTheme.serverStatusCpuColor)),
        const SizedBox(width: 8),
        SizedBox(
          width: AppTheme.serverStatusCoreValueWidth,
          child: Text(
            fraction == null ? '—' : '${(fraction * 100).toStringAsFixed(1)}%',
            textAlign: TextAlign.right,
            style: _secondaryStyle.copyWith(
              color: _usageColor(fraction, AppTheme.serverStatusCpuColor),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text('暂无可用数据'.tr, style: _secondaryStyle),
  );

  static const _errorColor = StatusColors.failed;
  static const _figures = [FontFeature.tabularFigures()];
  static const _secondaryStyle = TextStyle(
    fontSize: 11,
    color: AppTheme.terminalMutedForeground,
    fontFeatures: _figures,
  );

  Color _usageColor(double? fraction, Color normal) => fraction == null
      ? AppTheme.terminalMutedForeground
      : fraction >= .9
      ? StatusColors.failed
      : fraction >= .8
      ? AppTheme.serverStatusWarningColor
      : normal;

  Widget _progress(double? fraction, Color color) =>
      shadcn.ComponentTheme<shadcn.LinearProgressIndicatorTheme>(
        data: shadcn.LinearProgressIndicatorTheme(
          color: _usageColor(fraction, color),
          backgroundColor: AppTheme.terminalControlBackground,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
          disableAnimation: true,
        ),
        child: shadcn.LinearProgressIndicator(value: fraction ?? 0),
      );

  static String _speed(double? value) =>
      value == null ? '—' : '${_bytes(value)}/s';

  static String _uptime(double seconds) {
    final minutes = seconds ~/ 60;
    return '@days 天 @hours 小时 @minutes 分钟'.trParams({
      'days': '${minutes ~/ 1440}',
      'hours': '${minutes ~/ 60 % 24}',
      'minutes': '${minutes % 60}',
    });
  }

  static String _bytes(num value) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var amount = value.toDouble();
    var index = 0;
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024;
      index++;
    }
    return '${amount.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
  }
}
