import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/server_status_controller.dart';
import '../../domain/ssh/server_status.dart';
import '../components/app_icon_button.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';

/// 每个终端保留自己的展开状态；隐藏页签及收起面板不轮询。
class ServerStatusPanel extends StatefulWidget {
  const ServerStatusPanel({
    required this.source,
    required this.active,
    required this.availableWidth,
    required this.availableHeight,
    required this.terminal,
    super.key,
  });

  final ServerStatusSource? source;
  final bool active;
  final double availableWidth;
  final double availableHeight;
  final Widget terminal;

  @override
  State<ServerStatusPanel> createState() => _ServerStatusPanelState();
}

class _ServerStatusPanelState extends State<ServerStatusPanel> {
  ServerStatusController? _controller;
  bool _expanded = false;
  bool _cpuExpanded = false;

  bool get _canExpand =>
      widget.availableWidth >= 520 && widget.availableHeight >= 160;
  bool get _visible => _expanded && _canExpand;

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

  void _syncSampling() => _controller?.setEnabled(_visible && widget.active);

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
    final colors = shadcn.Theme.of(context).colorScheme;
    final visible = _visible;
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          children: [
            Expanded(child: widget.terminal),
            if (visible) _expandedPanel(context),
          ],
        ),
        if (!visible)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              key: const ValueKey('server-status-floating-toggle'),
              decoration: BoxDecoration(
                color: colors.background.withValues(alpha: .94),
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: _toggleButton(floating: true),
            ),
          ),
      ],
    );
  }

  Widget _expandedPanel(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('server-status-details'),
      width: math.min(320, widget.availableWidth * .42),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 41,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
              child: Row(
                children: [
                  const Icon(shadcn.LucideIcons.activity, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '服务状态'.tr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  AppIconButton(
                    semanticLabel: '刷新服务状态'.tr,
                    icon: const Icon(shadcn.LucideIcons.refreshCw, size: 15),
                    onPressed: () => _controller?.refreshStatus(),
                  ),
                  _toggleButton(),
                ],
              ),
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _toggleButton({bool floating = false}) => AppIconButton(
    semanticLabel: (_visible ? '折叠服务状态' : '展开服务状态').tr,
    icon: Icon(
      floating ? shadcn.LucideIcons.activity : shadcn.LucideIcons.chevronRight,
      size: 16,
    ),
    onPressed: !_canExpand
        ? null
        : () {
            setState(() => _expanded = !_expanded);
            _syncSampling();
          },
  );

  Widget _body(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Center(child: Text('此连接不支持服务状态采集'.tr));
    }
    return Obx(() {
      final status = controller.status.value;
      final error = controller.error.value;
      final updated = controller.updatedAt.value;
      final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: shadcn.OutlineBadge(
                    child: Text(
                      status?.sample.systemLabel ?? 'SSH',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (updated != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '更新于 @time'.trParams({
                      'time':
                          '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}:${updated.second.toString().padLeft(2, '0')}',
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (error != null) ...[
            Text(
              AppTranslations.error(error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: shadcn.Theme.of(context).colorScheme.destructive,
              ),
            ),
            if (status != null)
              Text(
                '更新失败，显示上次数据'.tr,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            const SizedBox(height: 8),
          ],
          if (status == null && error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(child: Text('正在获取服务状态…'.tr)),
            ),
          if (status != null) ...[
            _usage(
              'CPU',
              status.cpuFraction,
              detail: status.cpuFraction == null ? '等待下一次采样'.tr : null,
              leading: Semantics(
                expanded: _cpuExpanded,
                child: AppIconButton(
                  key: const ValueKey('server-status-cpu-toggle'),
                  semanticLabel: (_cpuExpanded ? '折叠 CPU 核心' : '展开 CPU 核心').tr,
                  icon: Icon(
                    _cpuExpanded
                        ? shadcn.LucideIcons.chevronDown
                        : shadcn.LucideIcons.chevronRight,
                    size: 14,
                  ),
                  onPressed: () => setState(() => _cpuExpanded = !_cpuExpanded),
                ),
              ),
            ),
            if (_cpuExpanded) ...[
              if (status.cpuCores.isEmpty) _empty(),
              for (final core in status.cpuCores.entries)
                _cpuCore(core.key, core.value),
              const SizedBox(height: 12),
            ],
            _usage(
              '内存'.tr,
              status.sample.memoryFraction,
              detail:
                  '${_bytes(status.sample.memoryUsed)} / ${_bytes(status.sample.memoryTotal)}',
            ),
            _section('磁盘占用'.tr),
            if (status.sample.filesystems.isEmpty) _empty(),
            for (final fs in status.sample.filesystems)
              _usage(
                fs.name ??
                    (status.sample.system == 'macOS' ? '系统磁盘'.tr : fs.mount),
                fs.fraction,
                detail: '${_bytes(fs.used)} / ${_bytes(fs.total)}',
              ),
            _section('网络 I/O'.tr),
            _directions('接收'.tr, '发送'.tr),
            if (status.network.isEmpty) _empty(),
            for (final entry in status.network.entries)
              _io(entry.key, entry.value),
            const SizedBox(height: 12),
            _section('磁盘 I/O'.tr),
            _directions('读取'.tr, '写入'.tr),
            if (status.disks.isEmpty) _empty(),
            for (final entry in status.disks.entries)
              _io(entry.key, entry.value),
          ],
        ],
      );
    });
  }

  Widget _usage(
    String label,
    double? fraction, {
    String? detail,
    Widget? leading,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 4)],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              fraction == null
                  ? '采样中'.tr
                  : '${(fraction * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // 首次采样使用零值占位，避免持续动画遮蔽数值是否已就绪。
        shadcn.LinearProgressIndicator(
          value: fraction ?? 0,
          theme: const shadcn.LinearProgressIndicatorTheme(
            disableAnimation: true,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 5),
          Text(detail, style: const TextStyle(fontSize: 11)),
        ],
      ],
    ),
  );

  Widget _cpuCore(int id, double? fraction) => Padding(
    key: ValueKey('server-status-cpu-core-$id'),
    padding: const EdgeInsets.only(left: 8, bottom: 8),
    child: Row(
      children: [
        SizedBox(
          width: AppTheme.serverStatusCoreLabelWidth,
          child: Text('CPU $id', style: const TextStyle(fontSize: 11)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: shadcn.LinearProgressIndicator(
            value: fraction ?? 0,
            theme: const shadcn.LinearProgressIndicatorTheme(
              disableAnimation: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: AppTheme.serverStatusCoreValueWidth,
          child: Text(
            fraction == null ? '—' : '${(fraction * 100).toStringAsFixed(1)}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 10),
    child: Text(
      label,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget _directions(String read, String write) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        const Expanded(child: SizedBox()),
        Expanded(
          child: Text(
            '↓ $read',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Expanded(
          child: Text(
            '↑ $write',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Widget _io(String name, IoRate rate) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Expanded(
          child: Text(
            _speed(rate.readPerSecond),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Expanded(
          child: Text(
            _speed(rate.writePerSecond),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Widget _empty() => Text('暂无可用数据'.tr, style: const TextStyle(fontSize: 11));

  static String _speed(double? value) =>
      value == null ? '—' : '${_bytes(value)}/s';

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
