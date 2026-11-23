import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/hosts/host_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/session/session_layout.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/host_tree_item.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../shell/connect_flow.dart';
import '../shell/widgets/host_tree_drag.dart';
import '../theme/app_theme.dart';
import 'docker_manager_panel.dart';
import 'firewall_panel.dart';
import 'network_ports_panel.dart';
import 'process_manager_panel.dart';
import 'server_status_panel.dart';
import 'terminal_pane_zoom_intent.dart';
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
  final Widget Function(Session session, bool selected, bool zoomed)
  paneBuilder;

  @override
  State<TerminalTabWorkspace> createState() => _TerminalTabWorkspaceState();
}

class _TerminalTabWorkspaceState extends State<TerminalTabWorkspace> {
  final _splitKeys = <String, GlobalKey>{};
  String? _zoomed;

  @override
  void didUpdateWidget(TerminalTabWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_zoomed != null &&
        (widget.sessions.length < 2 ||
            widget.tab.selectedSessionId != _zoomed)) {
      _zoomed = null;
    }
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

  bool _toggleZoom(String id) {
    if (!widget.active || widget.sessions.length < 2) return false;
    final controller = Get.find<SessionController>();
    if (_zoomed != id) controller.stopInputSync(widget.tab.id);
    controller.activate(id);
    setState(() => _zoomed = _zoomed == id ? null : id);
    return true;
  }

  void _cyclePane(int direction) {
    final ids = widget.tab.sessionIds.toList();
    if (!widget.active || ids.length < 2) return;
    final index = ids.indexOf(widget.tab.selectedSessionId);
    Get.find<SessionController>().activate(
      ids[(index + direction) % ids.length],
    );
  }

  Widget _panes(Map<String, Session> sessions, bool synced) => Stack(
    fit: StackFit.expand,
    children: [
      Offstage(
        offstage: _zoomed != null,
        child: _layout(widget.tab.layout, sessions, synced),
      ),
      if (_zoomed case final id?)
        _pane(sessions[id]!, split: true, synced: synced),
    ],
  );

  Widget _layout(
    SessionLayout layout,
    Map<String, Session> sessions,
    bool synced,
  ) {
    if (layout is SessionSplit) {
      return _ResizableTerminalSplit(
        key: _splitKeys.putIfAbsent(layout.id, GlobalKey.new),
        axis: layout.axis,
        first: _layout(layout.first, sessions, synced),
        second: _layout(layout.second, sessions, synced),
      );
    }
    final id = (layout as SessionPane).sessionId;
    // Keep the resize controllers and hidden siblings mounted while the
    // selected terminal moves to the full-size layer using its existing key.
    if (id == _zoomed) return const SizedBox.expand();
    return ExcludeFocus(
      excluding: _zoomed != null,
      child: _pane(sessions[id]!, split: sessions.length > 1, synced: synced),
    );
  }

  Widget _pane(Session session, {required bool split, required bool synced}) {
    final id = session.id;
    final selected = widget.tab.selectedSessionId == id;
    final child = widget.paneBuilder(session, selected, _zoomed == id);
    if (!split) return _dropZones(session, child);
    return Listener(
      onPointerDown: (_) => Get.find<SessionController>().activate(id),
      child: _dropZones(
        session,
        Container(
          key: ValueKey('terminal-pane-$id'),
          decoration: BoxDecoration(
            border: Border.all(
              color: synced
                  ? StatusColors.connecting
                  : selected && widget.active
                  ? AppTheme.terminalSelectedBorder
                  : AppTheme.terminalBorder,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              Positioned(
                top: AppTheme.terminalPaneControlsInset,
                right: AppTheme.terminalPaneControlsInset,
                child: _paneControls(id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _paneControls(String id) {
    final controller = Get.find<SessionController>();
    final zoomed = _zoomed == id;
    Widget button(
      String action,
      String label,
      AppIcons icon,
      VoidCallback run,
    ) => SizedBox.square(
      dimension: AppTheme.terminalPaneControlSize,
      child: AppIconButton(
        key: ValueKey('terminal-pane-$action-$id'),
        semanticLabel: label.tr,
        tooltip: label.tr,
        density: shadcn.ButtonDensity.compact,
        onPressed: run,
        icon: AppIcon(icon, size: 14),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.terminalControlBackground.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            'detach',
            '移到新标签',
            AppIcons.externalLink,
            () => controller.movePaneToNewTab(id),
          ),
          button(
            'zoom',
            zoomed ? '还原分屏' : '最大化窗格',
            zoomed ? AppIcons.minimize : AppIcons.maximize,
            () => _toggleZoom(id),
          ),
          button(
            'close',
            '关闭窗格',
            AppIcons.x,
            () => unawaited(controller.close(id)),
          ),
        ],
      ),
    );
  }

  Widget _dropZones(Session session, Widget child) {
    final controller = Get.find<SessionController>();
    if (!widget.active ||
        session.kind != SessionKind.terminal ||
        !controller.canSplitTerminal(session.id)) {
      return child;
    }
    Host? sourceOf(HostTreeItem item) {
      if (item is! ServiceTerminalDrag || !Get.isRegistered<HostController>()) {
        return null;
      }
      return Get.find<HostController>().hosts.firstWhereOrNull(
        (host) => host.id == item.id,
      );
    }

    Widget zone(SessionSplitEdge edge) => DragTarget<HostTreeItem>(
      key: ValueKey('terminal-drop-${session.id}-${edge.name}'),
      onWillAcceptWithDetails: (details) {
        final host = sourceOf(details.data);
        return host != null && controller.canSplitToHost(session.id, host);
      },
      onAcceptWithDetails: (details) {
        final host = sourceOf(details.data);
        if (host == null) return;
        unawaited(
          connectToHost(
            context,
            host,
            splitTarget: (sessionId: session.id, edge: edge),
          ),
        );
      },
      builder: (context, candidate, _) => IgnorePointer(
        child: candidate.isEmpty
            ? const SizedBox.expand()
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: AppTheme.terminalSelectedBorder.withValues(alpha: .25),
                  border: Border.all(color: AppTheme.terminalSelectedBorder),
                ),
                child: const SizedBox.expand(),
              ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth * .24;
        final height = constraints.maxHeight * .23;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              left: 0,
              top: height,
              bottom: height,
              width: width,
              child: zone(SessionSplitEdge.left),
            ),
            Positioned(
              right: 0,
              top: height,
              bottom: height,
              width: width,
              child: zone(SessionSplitEdge.right),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: height,
              child: zone(SessionSplitEdge.top),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height,
              child: zone(SessionSplitEdge.bottom),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      TerminalPaneZoomIntent: CallbackAction<TerminalPaneZoomIntent>(
        onInvoke: (_) => _toggleZoom(widget.tab.selectedSessionId),
      ),
      TerminalPaneCycleIntent: CallbackAction<TerminalPaneCycleIntent>(
        onInvoke: (intent) => _cyclePane(intent.direction),
      ),
    },
    child: shadcn.Theme(
      data: AppTheme.terminalTheme(context),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: AppTheme.terminalForeground),
        child: IconTheme.merge(
          data: const IconThemeData(color: AppTheme.terminalForeground),
          child: ColoredBox(
            key: const ValueKey('terminal-surface'),
            color: AppTheme.terminalBackground,
            child: Builder(
              builder: (context) => Obx(() => _buildWorkspace(context)),
            ),
          ),
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
    final synced = controller.isInputSyncEnabled(widget.tab.id);
    if (selected.kind == SessionKind.containerTerminal) {
      return Column(
        children: [
          _toolbar(selected, _splitButtons(controller, selected, synced)),
          Expanded(child: _panes(sessions, synced)),
        ],
      );
    }
    final statusSource = controller.serverStatusSource(widget.tab.id);
    final processSource = controller.processManagerSource(widget.tab.id);
    final dockerSource = controller.dockerManagerSource(widget.tab.id);
    final portsSource = controller.networkPortsSource(widget.tab.id);
    final firewallSource = controller.firewallSource(widget.tab.id);
    return LayoutBuilder(
      builder: (context, constraints) => TerminalSidePanel(
        availableWidth: constraints.maxWidth,
        availableHeight: math.max(
          0,
          constraints.maxHeight - AppTheme.terminalToolbarHeight,
        ),
        panelBuilder: (context, panel, visible) =>
            _monitoringPanels(controller, selected, panel, visible),
        toolbarBuilder: (context, panel, canExpand, toggle) => _toolbar(
          selected,
          [
            ..._splitButtons(controller, selected, synced),
            _toolbarDivider(),
            _toolbarButton(
              name: 'open-sftp',
              label: '文件传输'.tr,
              onPressed: controller.canOpenFileTransfer(selected.id)
                  ? () => unawaited(controller.openFileTransfer(selected.id))
                  : null,
              icon: AppIcons.folderOpen,
            ),
            _toolbarDivider(),
            _toolbarButton(
              name: 'toolbar-docker',
              label:
                  (panel == TerminalSidePanelKind.docker
                          ? '折叠 Docker 管理'
                          : '展开 Docker 管理')
                      .tr,
              tooltip: 'Docker 管理'.tr,
              selected: panel == TerminalSidePanelKind.docker,
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
                  (panel == TerminalSidePanelKind.processes
                          ? '折叠进程管理'
                          : '展开进程管理')
                      .tr,
              tooltip: '进程管理'.tr,
              selected: panel == TerminalSidePanelKind.processes,
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
              name: 'toolbar-network-ports',
              label:
                  (panel == TerminalSidePanelKind.networkPorts
                          ? '折叠网络端口'
                          : '展开网络端口')
                      .tr,
              tooltip: '网络端口'.tr,
              selected: panel == TerminalSidePanelKind.networkPorts,
              onPressed:
                  canExpand &&
                      (portsSource != null ||
                          panel == TerminalSidePanelKind.networkPorts)
                  ? () => toggle(TerminalSidePanelKind.networkPorts)
                  : null,
              icon: AppIcons.networkPorts,
            ),
            const SizedBox(width: 4),
            _toolbarButton(
              name: 'toolbar-firewall',
              label:
                  (panel == TerminalSidePanelKind.firewall ? '折叠防火墙' : '展开防火墙')
                      .tr,
              tooltip: '防火墙'.tr,
              selected: panel == TerminalSidePanelKind.firewall,
              onPressed:
                  canExpand &&
                      (firewallSource != null ||
                          panel == TerminalSidePanelKind.firewall)
                  ? () => toggle(TerminalSidePanelKind.firewall)
                  : null,
              icon: AppIcons.firewall,
            ),
            const SizedBox(width: 4),
            _toolbarButton(
              name: 'toolbar-status',
              label:
                  (panel == TerminalSidePanelKind.status ? '折叠服务状态' : '展开服务状态')
                      .tr,
              tooltip: '服务状态'.tr,
              selected: panel == TerminalSidePanelKind.status,
              onPressed:
                  canExpand &&
                      (statusSource != null ||
                          panel == TerminalSidePanelKind.status)
                  ? () => toggle(TerminalSidePanelKind.status)
                  : null,
              icon: AppIcons.statusOverview,
            ),
          ],
        ),
        terminal: _panes(sessions, synced),
      ),
    );
  }

  Widget _monitoringPanels(
    SessionController controller,
    Session selected,
    TerminalSidePanelKind panel,
    bool visible,
  ) {
    final byHost = <String, Session>{
      for (final session in widget.sessions) session.host.id: session,
    }..[selected.host.id] = selected;
    return IndexedStack(
      index: byHost.keys.toList().indexOf(selected.host.id),
      sizing: StackFit.expand,
      children: [
        for (final host in byHost.values)
          _hostPanel(
            controller,
            host,
            panel,
            visible: visible && host.id == selected.id,
            showTarget: byHost.length > 1,
          ),
      ],
    );
  }

  Widget _hostPanel(
    SessionController controller,
    Session session,
    TerminalSidePanelKind panel, {
    required bool visible,
    required bool showTarget,
  }) {
    final tabId = widget.tab.id;
    final hostId = session.host.id;
    final active = widget.active && visible;
    return ExcludeFocus(
      key: ValueKey(hostId),
      excluding: !active,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTarget)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
              child: shadcn.Tooltip(
                tooltip: (_) =>
                    shadcn.TooltipContainer(child: Text(session.address)),
                child: Text(
                  '运维目标：@name'.trParams({'name': session.host.name}),
                  key: const ValueKey('terminal-monitoring-target'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.terminalMutedForeground,
                  ),
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: panel.index,
              sizing: StackFit.expand,
              children: [
                ServerStatusPanel(
                  source: controller.serverStatusSource(tabId, hostId: hostId),
                  sourceUnavailableMessage: session.phase == SessionPhase.ready
                      ? null
                      : (session.phase.isBusy ? '连接建立后将显示服务状态' : '连接未就绪，暂无服务状态')
                            .tr,
                  active: active && panel == TerminalSidePanelKind.status,
                ),
                ProcessManagerPanel(
                  source: controller.processManagerSource(
                    tabId,
                    hostId: hostId,
                  ),
                  active: active && panel == TerminalSidePanelKind.processes,
                ),
                DockerManagerPanel(
                  source: controller.dockerManagerSource(tabId, hostId: hostId),
                  onOpenTerminal:
                      active && controller.canOpenDockerTerminal(session.id)
                      ? (resource) async {
                          await controller.openDockerTerminal(
                            session.id,
                            resource,
                          );
                        }
                      : null,
                  active: active && panel == TerminalSidePanelKind.docker,
                ),
                NetworkPortsPanel(
                  source: controller.networkPortsSource(tabId, hostId: hostId),
                  hostname: session.host.hostname,
                  active: active && panel == TerminalSidePanelKind.networkPorts,
                ),
                FirewallPanel(
                  source: controller.firewallSource(tabId, hostId: hostId),
                  active: active && panel == TerminalSidePanelKind.firewall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(Session selected, List<Widget> actions) {
    final split = widget.sessions.length > 1;
    return Container(
      key: const ValueKey('terminal-toolbar'),
      height: AppTheme.terminalToolbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: AppTheme.terminalBackground,
        border: Border(bottom: BorderSide(color: AppTheme.terminalBorder)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final actionBar = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          );
          if (!split && constraints.maxWidth < 260) {
            return Align(alignment: Alignment.centerRight, child: actionBar);
          }
          final contextWidth = split
              ? math.min(200.0, constraints.maxWidth * .7)
              : 0.0;
          return Row(
            children: [
              Expanded(child: _toolbarContext(selected, split: split)),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth - contextWidth,
                ),
                child: actionBar,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbarContext(Session selected, {required bool split}) {
    final statusColor = switch (selected.phase) {
      SessionPhase.ready => StatusColors.ready,
      SessionPhase.failed => StatusColors.failed,
      SessionPhase.closed => StatusColors.closed,
      _ => StatusColors.connecting,
    };
    final otherServices = {
      for (final pane in widget.sessions)
        if (pane.host.id != selected.host.id) pane.host.id: pane.host.name,
    };
    final mixed = otherServices.isNotEmpty;
    final title = [selected.title, ...otherServices.values].join(' / ');
    final address = selected.address;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppTheme.terminalForeground,
      ),
    );
    const secondary = TextStyle(
      fontSize: 11,
      color: AppTheme.terminalMutedForeground,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < 72) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6, right: 8),
          child: Row(
            key: const ValueKey('terminal-toolbar-context'),
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: mixed
                    ? shadcn.Tooltip(
                        tooltip: (_) =>
                            shadcn.TooltipContainer(child: Text(title)),
                        child: titleText,
                      )
                    : titleText,
              ),
              if (split) ...[
                if (width >= 180) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: shadcn.Tooltip(
                      tooltip: (_) =>
                          shadcn.TooltipContainer(child: Text(address)),
                      child: Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                _panePicker(selected, compact: width < 140),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _panePicker(Session selected, {required bool compact}) {
    final panes = widget.sessions;
    final index = panes.indexWhere((pane) => pane.id == selected.id) + 1;
    final label = '窗格 @index/@total'.trParams({
      'index': '$index',
      'total': '${panes.length}',
    });
    final description = '${'切换窗格'.tr} · ${selected.address}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.terminalControlBackground,
        border: Border.all(color: AppTheme.terminalBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: AppMenuButton<String>(
        key: const ValueKey('terminal-pane-picker'),
        density: shadcn.ButtonDensity.compact,
        tooltip: description,
        semanticLabel: '$description · $label',
        selectedValue: selected.id,
        items: [
          for (final (i, pane) in panes.indexed)
            (pane.id, '${i + 1}. ${pane.title}'),
        ],
        onSelected: Get.find<SessionController>().activate,
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              compact ? '$index/${panes.length}' : label,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.terminalForeground,
              ),
            ),
            const SizedBox(width: 3),
            const AppIcon(AppIcons.chevronDown, size: 12),
          ],
        ),
      ),
    );
  }

  Widget _toolbarDivider() => Container(
    width: 1,
    height: 14,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: AppTheme.terminalBorder,
  );

  List<Widget> _splitButtons(
    SessionController controller,
    Session selected,
    bool synced,
  ) {
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
      if (widget.sessions.length > 1) ...[
        const SizedBox(width: 4),
        _toolbarButton(
          name: 'input-sync',
          label:
              (_zoomed != null
                      ? '还原分屏后可同步输入'
                      : synced
                      ? '同步输入中（点击关闭）'
                      : '同步输入到此页签的所有窗格')
                  .tr,
          onPressed:
              _zoomed == null &&
                  (synced || controller.canSyncInput(widget.tab.id))
              ? () => controller.toggleInputSync(widget.tab.id)
              : null,
          icon: AppIcons.arrowLeftRight,
          selected: synced,
          accent: synced ? StatusColors.connecting : null,
        ),
      ],
    ];
  }

  Widget _toolbarButton({
    required String name,
    required String label,
    required AppIcons icon,
    required VoidCallback? onPressed,
    String? tooltip,
    bool selected = false,
    Color? accent,
  }) => Container(
    width: AppTheme.terminalToolbarButtonSize,
    height: AppTheme.terminalToolbarButtonSize,
    decoration: selected
        ? BoxDecoration(
            color: AppTheme.terminalControlBackground,
            border: Border.all(
              color: accent ?? AppTheme.terminalSelectedBorder,
            ),
            borderRadius: BorderRadius.circular(6),
          )
        : null,
    child: AppIconButton(
      key: ValueKey('terminal-$name'),
      semanticLabel: label,
      tooltip: tooltip ?? label,
      onPressed: onPressed,
      icon: AppIcon(
        icon,
        size: 16,
        color: accent ?? (selected ? AppTheme.terminalForeground : null),
      ),
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
  double _firstShare = .5;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = widget.axis == SessionSplitAxis.horizontal;
      final extent = horizontal ? constraints.maxWidth : constraints.maxHeight;
      final scaling = shadcn.Theme.of(context).scaling;
      final divider = math.min(
        extent,
        AppTheme.terminalPaneDividerSize * scaling,
      );
      final available = extent - divider;
      final minimum = math.min(
        horizontal
            ? AppTheme.terminalPaneMinWidth
            : AppTheme.terminalPaneMinHeight,
        available / 2,
      );
      final maximum = available - minimum;
      double firstExtent() => (available * _firstShare).clamp(minimum, maximum);
      final first = firstExtent();
      final hitSize = math.min(
        extent,
        AppTheme.terminalPaneDividerHitSize * scaling,
      );
      final hitStart = (first + (divider - hitSize) / 2).clamp(
        0.0,
        extent - hitSize,
      );

      void resize(DragUpdateDetails details) {
        if (available <= 0) return;
        final next = (firstExtent() + details.primaryDelta!).clamp(
          minimum,
          maximum,
        );
        setState(() => _firstShare = next / available);
      }

      const theme = shadcn.ResizableDraggerTheme(
        color: AppTheme.terminalSelectedBorder,
        iconColor: AppTheme.terminalForeground,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          Flex(
            direction: horizontal ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: horizontal ? first : null,
                height: horizontal ? null : first,
                child: widget.first,
              ),
              SizedBox.square(
                dimension: divider,
                child: const ColoredBox(color: AppTheme.terminalBorder),
              ),
              Expanded(child: widget.second),
            ],
          ),
          // Share one hit target so a double-click does not cancel a separate
          // resize widget's drag before it has started.
          Positioned(
            left: horizontal ? hitStart : 0,
            width: horizontal ? hitSize : null,
            right: horizontal ? null : 0,
            top: horizontal ? 0 : hitStart,
            height: horizontal ? null : hitSize,
            bottom: horizontal ? 0 : null,
            child: MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragUpdate: horizontal ? resize : null,
                onVerticalDragUpdate: horizontal ? null : resize,
                onDoubleTap: () => setState(() => _firstShare = .5),
                child: horizontal
                    ? const shadcn.HorizontalResizableDragger(theme: theme)
                    : const shadcn.VerticalResizableDragger(theme: theme),
              ),
            ),
          ),
        ],
      );
    },
  );
}
