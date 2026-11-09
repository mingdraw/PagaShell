import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/session/session_layout.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../theme/app_theme.dart';
import 'docker_manager_panel.dart';
import 'process_manager_panel.dart';
import 'server_status_panel.dart';
import 'terminal_side_panel.dart';

/// 一个 SSH 标签内的工具栏、窗格树与页签独立的监控面板。
class TerminalTabWorkspace extends StatefulWidget {
  const TerminalTabWorkspace({
    required this.tab,
    required this.sessions,
    required this.active,
    required this.paneBuilder,
    super.key,
  });

  final SessionTab tab;
  final List<Session> sessions;
  final bool active;
  final Widget Function(Session session, bool selected) paneBuilder;

  @override
  State<TerminalTabWorkspace> createState() => _TerminalTabWorkspaceState();
}

class _TerminalTabWorkspaceState extends State<TerminalTabWorkspace> {
  final _splitKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(TerminalTabWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final live = <String>{};
    void visit(SessionLayout layout) {
      if (layout is SessionSplit) {
        live.add(layout.id);
        visit(layout.first);
        visit(layout.second);
      }
    }

    visit(widget.tab.layout);
    _splitKeys.removeWhere((id, _) => !live.contains(id));
  }

  Widget _layout(SessionLayout layout, Map<String, Session> sessions) {
    if (layout is SessionSplit) {
      return _ResizableTerminalSplit(
        key: _splitKeys.putIfAbsent(layout.id, GlobalKey.new),
        axis: layout.axis,
        first: _layout(layout.first, sessions),
        second: _layout(layout.second, sessions),
      );
    }
    final id = (layout as SessionPane).sessionId;
    final session = sessions[id]!;
    final selected = widget.tab.selectedSessionId == id;
    final child = widget.paneBuilder(session, selected);
    if (sessions.length == 1) return child;
    return Listener(
      onPointerDown: (_) => Get.find<SessionController>().activate(id),
      child: Container(
        key: ValueKey('terminal-pane-$id'),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected && widget.active
                ? AppTheme.terminalSelectedBorder
                : AppTheme.terminalBorder,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.terminalBackground.withValues(alpha: .9),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: SizedBox.square(
                  dimension: AppTheme.terminalPaneCloseSize,
                  child: AppIconButton(
                    key: ValueKey('terminal-pane-close-$id'),
                    semanticLabel: '关闭窗格'.tr,
                    tooltip: '关闭窗格'.tr,
                    density: shadcn.ButtonDensity.compact,
                    onPressed: () =>
                        unawaited(Get.find<SessionController>().close(id)),
                    icon: const AppIcon(AppIcons.x, size: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => shadcn.Theme(
    data: AppTheme.terminalTheme(context),
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: AppTheme.terminalForeground),
      child: IconTheme.merge(
        data: const IconThemeData(color: AppTheme.terminalForeground),
        child: ColoredBox(
          key: const ValueKey('terminal-surface'),
          color: AppTheme.terminalBackground,
          child: Builder(builder: _buildWorkspace),
        ),
      ),
    ),
  );

  Widget _buildWorkspace(BuildContext context) {
    final sessions = {
      for (final session in widget.sessions) session.id: session,
    };
    final selected = sessions[widget.tab.selectedSessionId]!;
    final controller = Get.find<SessionController>();
    if (selected.kind == SessionKind.containerTerminal) {
      return Column(
        children: [
          _toolbar(_splitButtons(controller, selected)),
          Expanded(child: _layout(widget.tab.layout, sessions)),
        ],
      );
    }
    final statusSource = controller.serverStatusSource(widget.tab.id);
    final processSource = controller.processManagerSource(widget.tab.id);
    final dockerSource = controller.dockerManagerSource(widget.tab.id);
    return LayoutBuilder(
      builder: (context, constraints) => TerminalSidePanel(
        availableWidth: constraints.maxWidth,
        availableHeight: math.max(
          0,
          constraints.maxHeight - AppTheme.terminalToolbarHeight,
        ),
        panelBuilder: (context, panel, visible) => IndexedStack(
          index: panel.index,
          sizing: StackFit.expand,
          children: [
            ServerStatusPanel(
              source: statusSource,
              sourceUnavailableMessage: selected.phase == SessionPhase.ready
                  ? null
                  : (selected.phase.isBusy ? '连接建立后将显示服务状态' : '连接未就绪，暂无服务状态')
                        .tr,
              active:
                  widget.active &&
                  visible &&
                  panel == TerminalSidePanelKind.status,
            ),
            ProcessManagerPanel(
              source: processSource,
              active:
                  widget.active &&
                  visible &&
                  panel == TerminalSidePanelKind.processes,
            ),
            DockerManagerPanel(
              source: dockerSource,
              onOpenTerminal: controller.canOpenDockerTerminal(selected.id)
                  ? (resource) async {
                      await controller.openDockerTerminal(
                        selected.id,
                        resource,
                      );
                    }
                  : null,
              active:
                  widget.active &&
                  visible &&
                  panel == TerminalSidePanelKind.docker,
            ),
          ],
        ),
        toolbarBuilder: (context, panel, canExpand, toggle) => _toolbar([
          ..._splitButtons(controller, selected),
          const SizedBox(width: 4),
          _toolbarButton(
            name: 'open-sftp',
            label: '文件传输'.tr,
            onPressed: controller.canOpenFileTransfer(selected.id)
                ? () => unawaited(controller.openFileTransfer(selected.id))
                : null,
            icon: AppIcons.folderOpen,
          ),
          const SizedBox(width: 4),
          _toolbarButton(
            name: 'toolbar-docker',
            label:
                (panel == TerminalSidePanelKind.docker
                        ? '折叠 Docker 管理'
                        : '展开 Docker 管理')
                    .tr,
            tooltip: 'Docker 管理'.tr,
            onPressed:
                canExpand &&
                    (dockerSource != null ||
                        panel == TerminalSidePanelKind.docker)
                ? () => toggle(TerminalSidePanelKind.docker)
                : null,
            icon: AppIcons.container,
          ),
          const SizedBox(width: 4),
          _toolbarButton(
            name: 'toolbar-processes',
            label:
                (panel == TerminalSidePanelKind.processes ? '折叠进程管理' : '展开进程管理')
                    .tr,
            tooltip: '进程管理'.tr,
            onPressed:
                canExpand &&
                    (processSource != null ||
                        panel == TerminalSidePanelKind.processes)
                ? () => toggle(TerminalSidePanelKind.processes)
                : null,
            icon: AppIcons.processes,
          ),
          const SizedBox(width: 4),
          _toolbarButton(
            name: 'toolbar-status',
            label: (panel == TerminalSidePanelKind.status ? '折叠服务状态' : '展开服务状态')
                .tr,
            tooltip: '服务状态'.tr,
            onPressed:
                canExpand &&
                    (statusSource != null ||
                        panel == TerminalSidePanelKind.status)
                ? () => toggle(TerminalSidePanelKind.status)
                : null,
            icon: AppIcons.statusOverview,
          ),
        ]),
        terminal: _layout(widget.tab.layout, sessions),
      ),
    );
  }

  Widget _toolbar(List<Widget> children) => Container(
    key: const ValueKey('terminal-toolbar'),
    height: AppTheme.terminalToolbarHeight,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: const BoxDecoration(
      color: AppTheme.terminalBackground,
      border: Border(bottom: BorderSide(color: AppTheme.terminalBorder)),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: children),
  );

  List<Widget> _splitButtons(SessionController controller, Session selected) {
    final canSplit = controller.canSplitTerminal(selected.id);
    return [
      _toolbarButton(
        name: 'split-horizontal',
        label: '左右分屏'.tr,
        onPressed: canSplit
            ? () => unawaited(
                controller.splitTerminal(
                  selected.id,
                  SessionSplitAxis.horizontal,
                ),
              )
            : null,
        icon: AppIcons.columns2,
      ),
      const SizedBox(width: 4),
      _toolbarButton(
        name: 'split-vertical',
        label: '上下分屏'.tr,
        onPressed: canSplit
            ? () => unawaited(
                controller.splitTerminal(
                  selected.id,
                  SessionSplitAxis.vertical,
                ),
              )
            : null,
        icon: AppIcons.rows2,
      ),
    ];
  }

  Widget _toolbarButton({
    required String name,
    required String label,
    required AppIcons icon,
    required VoidCallback? onPressed,
    String? tooltip,
  }) => SizedBox.square(
    dimension: AppTheme.terminalToolbarButtonSize,
    child: AppIconButton(
      key: ValueKey('terminal-$name'),
      semanticLabel: label,
      tooltip: tooltip ?? label,
      onPressed: onPressed,
      icon: AppIcon(icon, size: 16),
    ),
  );
}

class _ResizableTerminalSplit extends StatefulWidget {
  const _ResizableTerminalSplit({
    required this.axis,
    required this.first,
    required this.second,
    super.key,
  });
  final SessionSplitAxis axis;
  final Widget first;
  final Widget second;

  @override
  State<_ResizableTerminalSplit> createState() =>
      _ResizableTerminalSplitState();
}

class _ResizableTerminalSplitState extends State<_ResizableTerminalSplit> {
  final _first = shadcn.FlexibleResizablePaneController(1);
  final _second = shadcn.FlexibleResizablePaneController(1);

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = widget.axis == SessionSplitAxis.horizontal;
      final extent = horizontal ? constraints.maxWidth : constraints.maxHeight;
      final minimum = math.min(
        horizontal
            ? AppTheme.terminalPaneMinWidth
            : AppTheme.terminalPaneMinHeight,
        math.max(0.0, (extent - 8) / 2),
      );
      return shadcn.ResizablePanel(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        draggerBuilder: (context) {
          const theme = shadcn.ResizableDraggerTheme(
            color: AppTheme.terminalSelectedBorder,
            iconColor: AppTheme.terminalForeground,
          );
          return horizontal
              ? const shadcn.HorizontalResizableDragger(theme: theme)
              : const shadcn.VerticalResizableDragger(theme: theme);
        },
        children: [
          shadcn.ResizablePane.controlled(
            controller: _first,
            minSize: minimum,
            child: widget.first,
          ),
          shadcn.ResizablePane.controlled(
            controller: _second,
            minSize: minimum,
            child: widget.second,
          ),
        ],
      );
    },
  );
}
