import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/process_manager_controller.dart';
import '../../domain/ssh/process_manager.dart';
import '../components/app_copy_button.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../shell/workspace_visibility.dart';
import '../theme/app_theme.dart';
import 'panel_refresh_pause_button.dart';
import 'process_details_dialog.dart';
import 'process_termination_dialog.dart';
import 'terminal_search_field.dart';

class ProcessManagerPanel extends StatefulWidget {
  const ProcessManagerPanel({
    required this.source,
    required this.active,
    super.key,
  });

  final ProcessManagerSource? source;
  final bool active;

  @override
  State<ProcessManagerPanel> createState() => _ProcessManagerPanelState();
}

class _ProcessManagerPanelState extends State<ProcessManagerPanel>
    with WorkspaceVisibilityObserver<ProcessManagerPanel> {
  ProcessManagerController? _controller;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _confirming = <String>{};
  bool _showingDetails = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
    _createController();
  }

  void _searchChanged() => _controller?.query.value = _search.text;

  void _createController() {
    final source = widget.source;
    _controller = source == null
        ? null
        : ProcessManagerController(source: source);
    _searchChanged();
    onWorkspaceVisibilityChanged();
  }

  @override
  void onWorkspaceVisibilityChanged() =>
      _controller?.setEnabled(widget.active && workspaceVisible);

  @override
  void didUpdateWidget(ProcessManagerPanel oldWidget) {
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
    key: const ValueKey('process-manager-details'),
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
                  AppIcons.processes,
                  size: 15,
                  color: AppTheme.serverStatusCpuColor,
                ),
                const SizedBox(width: 8),
                Expanded(child: _heading()),
                if (_controller case final controller?) ...[
                  PanelRefreshPauseButton(
                    key: const ValueKey('process-manager-pause'),
                    paused: controller.autoRefreshPaused,
                    onChanged: controller.setAutoRefreshPaused,
                  ),
                  Obx(
                    () => AppIconButton(
                      key: const ValueKey('process-manager-refresh'),
                      semanticLabel: '刷新进程列表'.tr,
                      tooltip: '刷新进程列表'.tr,
                      icon: const AppIcon(AppIcons.refreshCw, size: 15),
                      onPressed: controller.loading.value || !widget.active
                          ? null
                          : () => unawaited(controller.refreshProcesses()),
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
      '进程管理'.tr,
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
                  key: const ValueKey('process-manager-updated'),
                  style: _secondaryStyle.copyWith(fontSize: 10),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _body() {
    final controller = _controller;
    if (controller == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '连接未就绪，暂无进程信息'.tr,
            style: _secondaryStyle,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TerminalSearchField(
            fieldKey: const ValueKey('process-manager-search'),
            clearKey: const ValueKey('process-manager-search-clear'),
            controller: _search,
            semanticLabel: '搜索进程'.tr,
            hintText: '搜索名称、PID 或用户'.tr,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: LayoutBuilder(
            builder: (_, constraints) => Obx(() {
              final count = Text(
                '@shown / @total 个进程'.trParams({
                  'shown': '${controller.visibleProcesses.length}',
                  'total': '${controller.processes.length}',
                }),
                key: const ValueKey('process-manager-count'),
                style: _secondaryStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
              final sort = SizedBox(
                width: Get.locale?.languageCode == 'en' ? 152 : 136,
                child: _sortSelector(controller),
              );
              if (constraints.maxWidth < 256) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [count, const SizedBox(height: 5), sort],
                );
              }
              return Row(
                children: [
                  Expanded(child: count),
                  const SizedBox(width: 8),
                  sort,
                ],
              );
            }),
          ),
        ),
        Expanded(
          child: Obx(() {
            final entries = controller.visibleProcesses;
            final error = controller.error.value;
            final actionError = controller.actionError.value;
            final notice = controller.notice.value;
            final terminating = controller.terminating.toSet();
            final loading = controller.loading.value;
            final updated = controller.updatedAt.value;
            return Column(
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        AppTranslations.error(error),
                        key: const ValueKey('process-manager-message'),
                        style: _secondaryStyle.copyWith(
                          color: StatusColors.failed,
                        ),
                      ),
                    ),
                  ),
                if (actionError != null || notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            actionError == null
                                ? notice!.tr
                                : AppTranslations.error(actionError),
                            style: _secondaryStyle.copyWith(
                              color: actionError == null
                                  ? AppTheme.serverStatusCpuColor
                                  : StatusColors.failed,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
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
                  ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              (updated == null && loading
                                      ? '正在获取进程列表…'
                                      : controller.query.value.trim().isNotEmpty
                                      ? '没有匹配的进程'
                                      : '暂无进程数据')
                                  .tr,
                              style: _secondaryStyle,
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('process-manager-list'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                          itemCount: entries.length,
                          itemBuilder: (_, index) => _processCard(
                            controller,
                            entries[index],
                            index + 1,
                            terminating.contains(
                              entries[index].process.identity,
                            ),
                          ),
                        ),
                ),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _sortSelector(ProcessManagerController controller) => Semantics(
    label: '进程排序'.tr,
    child: shadcn.RadioGroup<ProcessSort>(
      key: const ValueKey('process-manager-sort'),
      value: controller.sort.value,
      onChanged: (value) => controller.sort.value = value,
      child: Row(
        children: [
          for (final value in ProcessSort.values) ...[
            if (value != ProcessSort.values.first) const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                label: (value == ProcessSort.cpu ? 'CPU 降序' : '内存降序').tr,
                checked: controller.sort.value == value,
                inMutuallyExclusiveGroup: true,
                child: shadcn.RadioCard<ProcessSort>(
                  key: ValueKey('process-sort-${value.name}'),
                  value: value,
                  theme: const shadcn.RadioCardTheme(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          value == ProcessSort.cpu ? 'CPU' : '内存'.tr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 3),
                      const AppIcon(AppIcons.arrowDown, size: 12),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _processCard(
    ProcessManagerController controller,
    ProcessUsage usage,
    int rank,
    bool busy,
  ) {
    final process = usage.process;
    final name = _processName(process);
    return Padding(
      key: ValueKey('process-card-${process.pid}'),
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
                  '#$rank',
                  style: _secondaryStyle.copyWith(
                    color: AppTheme.serverStatusCpuColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: shadcn.Tooltip(
                    tooltip: (_) =>
                        shadcn.TooltipContainer(child: Text(process.name)),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox.square(
                  dimension: 22,
                  child: AppIconButton(
                    key: ValueKey('process-details-${process.pid}'),
                    semanticLabel: '进程详情'.tr,
                    tooltip: '进程详情'.tr,
                    density: shadcn.ButtonDensity.compact,
                    icon: const AppIcon(AppIcons.info, size: 14),
                    onPressed: () =>
                        unawaited(_requestDetails(controller, process)),
                  ),
                ),
                const SizedBox(width: 2),
                SizedBox.square(
                  dimension: 22,
                  child: AppIconButton(
                    key: ValueKey('process-terminate-${process.pid}'),
                    semanticLabel: (busy ? '结束中…' : '结束进程').tr,
                    tooltip: (busy ? '结束中…' : '结束进程').tr,
                    density: shadcn.ButtonDensity.compact,
                    onPressed:
                        !process.canTerminate ||
                            busy ||
                            _confirming.contains(process.identity)
                        ? null
                        : () => unawaited(
                            _requestTermination(controller, process),
                          ),
                    icon: AppIcon(
                      busy ? AppIcons.hourglass : AppIcons.square,
                      size: 13,
                      color:
                          process.canTerminate &&
                              !busy &&
                              !_confirming.contains(process.identity)
                          ? StatusColors.failed
                          : AppTheme.terminalMutedForeground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Flexible(
                  child: Text(
                    'PID ${process.pid} · ${process.user}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _secondaryStyle,
                  ),
                ),
                const SizedBox(width: 3),
                SizedBox.square(
                  dimension: 22,
                  child: AppCopyButton(
                    key: ValueKey('process-copy-pid-${process.pid}'),
                    text: '${process.pid}',
                    size: 12,
                    semanticLabel: '复制进程 ID'.tr,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              key: ValueKey('process-metrics-${process.pid}'),
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: _metric(
                    'CPU',
                    usage.cpuPercent,
                    AppIcons.cpu,
                    AppTheme.serverStatusCpuColor,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: _metric(
                    '内存'.tr,
                    usage.memoryPercent,
                    AppIcons.memoryStick,
                    AppTheme.serverStatusMemoryColor,
                    detail: _bytes(process.memoryBytes),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(
    String label,
    double percent,
    AppIcons icon,
    Color color, {
    String? detail,
  }) => shadcn.Tooltip(
    tooltip: (_) => shadcn.TooltipContainer(
      child: Text(
        '$label ${percent.toStringAsFixed(1)}%${detail == null ? '' : ' / $detail'}',
      ),
    ),
    child: Semantics(
      label:
          '$label ${percent.toStringAsFixed(1)}%${detail == null ? '' : ' / $detail'}',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              '${percent.toStringAsFixed(1)}%',
              style: _secondaryStyle.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (detail != null) Text(' / $detail', style: _secondaryStyle),
          ],
        ),
      ),
    ),
  );

  Future<void> _requestDetails(
    ProcessManagerController controller,
    RemoteProcess process,
  ) async {
    if (_showingDetails || !widget.active) return;
    _showingDetails = true;
    try {
      await AppNavigation.dialog<void>(
        ProcessDetailsDialog(
          key: const ValueKey('process-details-dialog'),
          process: process,
          readDetails: controller.readDetails,
        ),
      );
    } finally {
      _showingDetails = false;
    }
  }

  Future<void> _requestTermination(
    ProcessManagerController controller,
    RemoteProcess process,
  ) async {
    if (!_confirming.add(process.identity)) return;
    setState(() {});
    try {
      final confirmed = await AppNavigation.dialog<bool>(
        ProcessTerminationDialog(
          key: const ValueKey('process-terminate-confirmation'),
          process: process,
          name: _processName(process),
        ),
      );
      if (confirmed == true &&
          mounted &&
          widget.active &&
          identical(controller, _controller)) {
        await controller.terminate(process);
      }
    } finally {
      if (mounted) setState(() => _confirming.remove(process.identity));
    }
  }

  static const _secondaryStyle = TextStyle(
    fontSize: 11,
    color: AppTheme.terminalMutedForeground,
  );

  static String _processName(RemoteProcess process) {
    final name = process.name.split('/').last;
    return name.isEmpty ? process.name : name;
  }

  static String _bytes(int value) {
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
