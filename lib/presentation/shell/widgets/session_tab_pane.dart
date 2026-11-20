import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/ai/ai_settings_controller.dart';
import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../application/session/session_layout.dart';
import '../../../application/settings/settings_controller.dart';
import '../../ai/agent_workspace.dart';
import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_menu.dart';
import '../../hosts/host_edit_dialog.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import '../connect_flow.dart';
import '../session_close_confirmation.dart';
import 'settings_menu_button.dart';
import 'window_controls.dart';
import 'workspace_header_actions.dart';

/// 会话标签与内容容器；内容的生命周期由工作区管理。
class SessionTabPane extends StatefulWidget {
  const SessionTabPane({
    required this.sessions,
    required this.tabs,
    required this.activeId,
    required this.child,
    this.fullscreen = false,
    super.key,
  });

  final List<Session> sessions;
  final List<SessionTab> tabs;
  final String? activeId;
  final Widget child;
  final bool fullscreen;

  @override
  State<SessionTabPane> createState() => _SessionTabPaneState();
}

class _SessionTabPaneState extends State<SessionTabPane> {
  final _tabKeys = <String, GlobalKey>{};
  // TabPane 按对象身份识别拖动项，切换标签和刷新连接状态时保持包装对象稳定。
  final _tabItems = <String, shadcn.TabPaneData<String>>{};
  bool _revealScheduled = false;
  bool _ignoreSortFocus = false;
  double? _paneWidth;
  EdgeInsets? _headerInsets;
  bool? _sidebarVisible;

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(SessionTabPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.tabs.map((tab) => tab.id).toList();
    _tabKeys.removeWhere((id, _) => !ids.contains(id));
    _tabItems.removeWhere((id, _) => !ids.contains(id));
    if (oldWidget.activeId != widget.activeId ||
        oldWidget.fullscreen != widget.fullscreen ||
        !listEquals(oldWidget.tabs.map((tab) => tab.id).toList(), ids)) {
      _scheduleReveal();
    }
  }

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted) _revealActiveTab();
    });
  }

  void _revealActiveTab() {
    final activeIndex = widget.tabs.indexWhere(
      (tab) => tab.id == widget.activeId,
    );
    if (activeIndex < 0) return;

    BuildContext? tabContext;
    var nearestIndex = -1;
    for (var index = 0; index < widget.tabs.length; index++) {
      final context = _tabKeys[widget.tabs[index].id]?.currentContext;
      if (context != null &&
          (nearestIndex < 0 ||
              (index - activeIndex).abs() <
                  (nearestIndex - activeIndex).abs())) {
        tabContext = context;
        nearestIndex = index;
      }
    }
    if (tabContext == null) return;
    final tab = tabContext.findRenderObject();
    final position = Scrollable.maybeOf(
      tabContext,
      axis: Axis.horizontal,
    )?.position;
    if (tab is! RenderBox ||
        !tab.hasSize ||
        position == null ||
        !position.hasContentDimensions) {
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(tab);
    if (viewport == null) return;

    final start = viewport.getOffsetToReveal(tab, 0).offset;
    if (nearestIndex != activeIndex) {
      // TabPane 懒加载远处的标签，先根据已布局标签靠近，再精确定位。
      final theme = shadcn.Theme.of(context);
      final extent = tab.size.width + theme.density.baseGap * theme.scaling;
      final target = (start + (activeIndex - nearestIndex) * extent).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() > 0.5) {
        position.jumpTo(target);
        _scheduleReveal();
      }
      return;
    }

    // 包含官方标签两侧伸出的圆角，已经完整可见时保持当前滚动位置。
    final radius = AppTheme.sessionPaneRadius(context);
    final leading = start - radius.bottomLeft.x;
    final trailing =
        viewport.getOffsetToReveal(tab, 1).offset + radius.bottomRight.x;
    final target =
        (trailing <= leading
                ? position.pixels.clamp(trailing, leading)
                : leading)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() > 0.5) {
      unawaited(
        position.animateTo(
          target,
          duration: AppTheme.sessionTabScrollDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final headerInsets = WorkspaceHeaderInsets.maybeOf(context);
    if (headerInsets != null) return _layoutPane(headerInsets: headerInsets);
    final settings = Get.find<SettingsController>();
    return Obx(
      () => _layoutPane(sidebarVisible: settings.sidebarVisible.value),
    );
  }

  Widget _layoutPane({EdgeInsets? headerInsets, bool sidebarVisible = false}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          if (_paneWidth != constraints.maxWidth ||
              _headerInsets != headerInsets ||
              _sidebarVisible != sidebarVisible) {
            _paneWidth = constraints.maxWidth;
            _headerInsets = headerInsets;
            _sidebarVisible = sidebarVisible;
            _scheduleReveal();
          }
          return _buildPane(context, sidebarVisible, headerInsets);
        },
      );

  Widget _buildPane(
    BuildContext context,
    bool sidebarVisible,
    EdgeInsets? headerInsets,
  ) {
    if (widget.fullscreen) return widget.child;
    final tabs = widget.tabs;
    final allSessionsById = {
      for (final session in widget.sessions) session.id: session,
    };
    final sessionsById = {
      for (final tab in tabs) tab.id: allSessionsById[tab.selectedSessionId]!,
    };
    final activeId = widget.activeId;
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final headerControlSize = AppTheme.windowHeaderControlSize(context);
    final paneRadius = AppTheme.sessionPaneRadius(context);
    final controller = Get.find<SessionController>();
    final activeIndex = tabs.indexWhere((tab) => tab.id == activeId);
    return ColoredBox(
      color: AppTheme.sidebar(context),
      child: WindowDragRegion(
        height: AppTheme.sessionPaneTopMargin + headerControlSize,
        child: Padding(
          padding: const EdgeInsets.only(top: AppTheme.sessionPaneTopMargin),
          child: shadcn.TabPane<String>(
            borderRadius: paneRadius,
            items: [
              for (final tab in tabs)
                _tabItems.putIfAbsent(tab.id, () => shadcn.TabPaneData(tab.id)),
            ],
            focused: activeIndex < 0 ? 0 : activeIndex,
            onFocused: (index) {
              if (_ignoreSortFocus) return;
              if (index >= 0 && index < tabs.length) {
                controller.activateTab(tabs[index].id);
                _scheduleReveal();
              }
            },
            onSort: (items) {
              // TabPane 排序后会回传旧位置索引；保留拖动开始时按 ID 激活的标签。
              _ignoreSortFocus = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _ignoreSortFocus = false;
              });
              controller.reorder(items.map((item) => item.data));
              _scheduleReveal();
            },
            backgroundColor: AppTheme.background(context),
            leading: [
              if (headerInsets != null)
                SizedBox(
                  width: math.max(
                    0,
                    headerInsets.left - paneRadius.bottomLeft.x,
                  ),
                )
              else ...[
                if (isMac && !sidebarVisible)
                  const SizedBox(
                    width: AppTheme.macWindowControlsWidth,
                    child: WindowDragArea(),
                  ),
                if (!sidebarVisible)
                  const WindowHeaderButton(child: SidebarToggleButton()),
                const WorkspaceHeaderActions(),
              ],
              if (tabs.isNotEmpty)
                WindowDragBlocker(
                  child: AppMenuButton<String>(
                    icon: const AppIcon(AppIcons.chevronDown, size: 16),
                    semanticLabel: '会话列表'.tr,
                    selectedValue: activeId,
                    items: [
                      for (final tab in tabs)
                        (
                          tab.id,
                          '${sessionsById[tab.id]!.title} · ${switch (sessionsById[tab.id]!.kind) {
                            SessionKind.terminal => '终端'.tr,
                            SessionKind.containerTerminal => '容器终端'.tr,
                            SessionKind.fileTransfer => '文件传输'.tr,
                            SessionKind.portForward => '端口转发'.tr,
                            SessionKind.dynamicProxy => '动态代理'.tr,
                            SessionKind.remoteDesktop => '远程桌面'.tr,
                          }}',
                        ),
                    ],
                    onSelected: (value) {
                      controller.activateTab(value);
                      _scheduleReveal();
                    },
                  ),
                ),
            ],
            trailing: [
              Padding(
                padding: EdgeInsets.only(
                  right: math.max(
                    0,
                    (headerInsets?.right ?? 0) - paneRadius.bottomRight.x,
                  ),
                ),
                child: const SizedBox(
                  width: AppTheme.windowDragWidth,
                  child: WindowDragArea(),
                ),
              ),
              if (headerInsets == null) ...[
                if (Get.isRegistered<AiSettingsController>())
                  const WindowHeaderButton(child: AgentToggleButton()),
                const WindowHeaderButton(child: SettingsMenuButton()),
                if (!isMac) const WindowDragBlocker(child: WindowButtons()),
              ],
            ],
            itemBuilder: (context, item, index) {
              final session = sessionsById[item.data]!;
              final tab = tabs.firstWhere((tab) => tab.id == item.data);
              final tabSessions = [
                for (final id in tab.sessionIds) ?allSessionsById[id],
              ];
              final canDuplicate =
                  session.kind == SessionKind.terminal ||
                  session.kind == SessionKind.remoteDesktop;
              final canTransfer = controller.canOpenFileTransfer(session.id);
              final canReconnect = controller.canReconnect(session.id);
              final hosts = savedHostControllerForSession(session);
              final hasRightTabs = index < tabs.length - 1;
              final sessionActions = <(String, String)>[
                if (canDuplicate) ('new-session', '新建会话'.tr),
                if (canTransfer) ('open-transfer', '文件传输'.tr),
                if (canReconnect) ('reconnect', '重新连接'.tr),
                if (session.address.isNotEmpty) ('copy-address', '复制地址'.tr),
              ];
              final closeActions = <(String, String)>[
                ('close-current', '关闭当前标签'.tr),
                ('close-right', '关闭右侧标签'.tr),
                ('close-others', '关闭其他标签'.tr),
                ('close-all', '关闭全部标签'.tr),
              ];
              const tabMenuIcons = <String, AppIcons>{
                'reconnect': AppIcons.rotateCw,
                'copy-address': AppIcons.copy,
              };
              void onTabAction(String action) {
                switch (action) {
                  case 'new-session':
                    unawaited(duplicateSessionConnection(context, session));
                  case 'open-transfer':
                    unawaited(controller.openFileTransfer(session.id));
                  case 'reconnect':
                    unawaited(
                      session.phase == SessionPhase.failed
                          ? retryFailedSession(context, session)
                          : controller.reconnect(session.id),
                    );
                  case 'copy-address':
                    unawaited(
                      Clipboard.setData(ClipboardData(text: session.address)),
                    );
                    AppNotice.success('已复制'.tr);
                  case 'edit':
                    unawaited(showSessionHostEditDialog(context, session));
                  case 'close-current':
                    unawaited(requestSessionTabClose(controller, [tab.id]));
                  case 'close-right':
                    final currentTabs = controller.tabs;
                    final currentIndex = currentTabs.indexWhere(
                      (item) => item.id == tab.id,
                    );
                    if (currentIndex >= 0 &&
                        currentIndex < currentTabs.length - 1) {
                      unawaited(
                        requestSessionTabClose(
                          controller,
                          currentTabs
                              .sublist(currentIndex + 1)
                              .map((other) => other.id),
                        ),
                      );
                    }
                  case 'close-others':
                    unawaited(
                      requestSessionTabClose(
                        controller,
                        controller.tabs
                            .where((other) => other.id != tab.id)
                            .map((other) => other.id),
                        keepSessionId: tab.id,
                      ),
                    );
                  case 'close-all':
                    unawaited(
                      requestSessionTabClose(
                        controller,
                        controller.tabs.map((tab) => tab.id),
                      ),
                    );
                }
              }

              final tabItem = shadcn.KeyedTabItem<String>(
                key: tab.id,
                child: _SessionTab(
                  session: session,
                  tab: tab,
                  tabSessions: tabSessions,
                  active: index == activeIndex,
                ),
              );
              Widget menu({required bool canEdit}) {
                final actions = [
                  ...sessionActions,
                  if (canEdit)
                    (
                      'edit',
                      (session.kind.usesGatewayEndpoint ? '编辑网关' : '编辑服务').tr,
                    ),
                ];
                return shadcn.ContextMenu(
                  items: [
                    if (actions.isNotEmpty) ...[
                      ...appMenuItems<String>(
                        actions,
                        onTabAction,
                        icons: tabMenuIcons,
                      ),
                      const shadcn.MenuDivider(),
                    ],
                    ...appMenuItems<String>(
                      closeActions,
                      onTabAction,
                      disabledValues: {
                        if (!hasRightTabs) 'close-right',
                        if (tabs.length < 2) 'close-others',
                      },
                    ),
                  ],
                  child: tabItem,
                );
              }

              return shadcn.TabChildWidget(
                indexed: true,
                child: WindowDragBlocker(
                  child: Builder(
                    builder: (context) => KeyedSubtree(
                      // 拖动副本在滚动列表之外，不能复用定位标签所用的 GlobalKey。
                      key:
                          Scrollable.maybeOf(context, axis: Axis.horizontal) ==
                              null
                          ? null
                          : _tabKeys.putIfAbsent(tab.id, GlobalKey.new),
                      child: hosts == null
                          ? menu(canEdit: false)
                          : Obx(
                              () => menu(
                                canEdit: hosts.hosts.any(
                                  (h) => h.id == session.host.id,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              );
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _SessionTab extends StatefulWidget {
  const _SessionTab({
    required this.session,
    required this.tab,
    required this.tabSessions,
    required this.active,
  });

  final Session session;
  final SessionTab tab;
  final List<Session> tabSessions;
  final bool active;

  @override
  State<_SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends State<_SessionTab> {
  final _layerLink = LayerLink();
  OverlayEntry? _tooltipEntry;
  Timer? _tooltipTimer;
  bool _hovered = false;
  int? _middlePointer;

  @override
  void didUpdateWidget(covariant _SessionTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tooltip = _tooltipEntry;
    if (tooltip != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_tooltipEntry, tooltip)) {
          tooltip.markNeedsBuild();
        }
      });
    }
  }

  @override
  void dispose() {
    _hideTooltip();
    super.dispose();
  }

  String _tooltipText() {
    final session = widget.session;
    final title =
        '${session.title} · ${session.address} · '
        '${'@kind（@phase）'.trParams({'kind': _kindLabel, 'phase': _phaseLabel(session.kind, _groupPhase)})}';
    if (widget.tabSessions.length < 2) return title;
    return [
      title,
      for (final pane in widget.tabSessions)
        '${pane.title} · ${pane.address} · ${_phaseLabel(pane.kind, pane.phase)}',
    ].join('\n');
  }

  void _showTooltipLater() {
    _tooltipTimer?.cancel();
    _tooltipTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _tooltipEntry != null) return;
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      final screenWidth = MediaQuery.sizeOf(context).width;
      final render = context.findRenderObject();
      final alignRight =
          render is RenderBox &&
          render.hasSize &&
          render.localToGlobal(Offset.zero).dx + 260 > screenWidth - 8;
      final entry = OverlayEntry(
        builder: (_) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: alignRight
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            followerAnchor: alignRight ? Alignment.topRight : Alignment.topLeft,
            offset: const Offset(0, 6),
            child: IgnorePointer(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(120, screenWidth - 16),
                ),
                child: shadcn.TooltipContainer(child: Text(_tooltipText())),
              ),
            ),
          ),
        ),
      );
      _tooltipEntry = entry;
      overlay.insert(entry);
    });
  }

  void _hideTooltip() {
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
    _tooltipEntry?.remove();
    _tooltipEntry?.dispose();
    _tooltipEntry = null;
  }

  SessionPhase get _groupPhase {
    final group = widget.tabSessions.isEmpty
        ? [widget.session]
        : widget.tabSessions;
    if (group.any((item) => item.phase == SessionPhase.failed)) {
      return SessionPhase.failed;
    }
    return group.firstWhereOrNull((item) => item.phase.isBusy)?.phase ??
        group
            .firstWhereOrNull((item) => item.phase == SessionPhase.ready)
            ?.phase ??
        SessionPhase.closed;
  }

  Color get _statusColor => switch (_groupPhase) {
    SessionPhase.failed => StatusColors.failed,
    SessionPhase.ready => StatusColors.ready,
    SessionPhase.closed => StatusColors.closed,
    _ => StatusColors.connecting,
  };

  String get _kindLabel => switch (widget.session.kind) {
    SessionKind.terminal => '终端'.tr,
    SessionKind.containerTerminal => '容器终端'.tr,
    SessionKind.fileTransfer => '文件传输'.tr,
    SessionKind.portForward => '端口转发'.tr,
    SessionKind.dynamicProxy => '动态代理'.tr,
    SessionKind.remoteDesktop => '远程桌面'.tr,
  };

  String _phaseLabel(SessionKind kind, SessionPhase phase) => switch (phase) {
    SessionPhase.ready => '已连接'.tr,
    SessionPhase.failed => '失败'.tr,
    SessionPhase.closed => (kind.usesGatewayEndpoint ? '未启用' : '已断开').tr,
    SessionPhase.stopping => '正在停止'.tr,
    SessionPhase.hostKeyPending => '等待确认主机指纹'.tr,
    SessionPhase.authenticating => '正在认证'.tr,
    SessionPhase.credentialsPending => '等待输入密码'.tr,
    SessionPhase.reconnecting => '正在重新连接'.tr,
    _ => '正在连接'.tr,
  };

  bool _insideTab(Offset position) =>
      (Offset.zero & context.size!).contains(position);

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dx != 0) {
      return;
    }
    final position = Scrollable.maybeOf(
      context,
      axis: Axis.horizontal,
    )?.position;
    if (position == null ||
        !position.hasContentDimensions ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }
    final delta = position.axisDirection == AxisDirection.left
        ? -event.scrollDelta.dy
        : event.scrollDelta.dy;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => position.pointerScroll(delta),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final session = widget.session;
    final tab = widget.tab;
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        _hideTooltip();
        if (_hovered) setState(() => _hovered = false);
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _wheel,
        onPointerDown: (event) {
          _hideTooltip();
          if (event.buttons == kMiddleMouseButton) {
            _middlePointer = event.pointer;
          }
        },
        onPointerMove: (event) {
          if (event.pointer == _middlePointer &&
              !_insideTab(event.localPosition)) {
            _middlePointer = null;
          }
        },
        onPointerUp: (event) {
          if (event.pointer == _middlePointer) {
            _middlePointer = null;
            if (!_insideTab(event.localPosition)) return;
            unawaited(
              requestSessionTabClose(Get.find<SessionController>(), [tab.id]),
            );
          }
        },
        onPointerCancel: (event) {
          if (event.pointer == _middlePointer) _middlePointer = null;
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AppTheme.sessionTabMinWidth,
          ),
          child: shadcn.Label(
            leading: AppIcon(
              switch (session.kind) {
                SessionKind.fileTransfer => AppIcons.folderOpen,
                SessionKind.portForward => AppIcons.arrowLeftRight,
                SessionKind.dynamicProxy => AppIcons.proxy,
                SessionKind.terminal => AppIcons.terminal,
                SessionKind.containerTerminal => AppIcons.container,
                SessionKind.remoteDesktop => AppIcons.forServiceType(
                  session.host.serviceType,
                ),
              },
              size: 14,
              color: _statusColor,
            ),
            trailing: Opacity(
              opacity: widget.active || _hovered ? 1.0 : 0.0,
              child: AppIconButton(
                key: ValueKey('session-tab-close-${tab.id}'),
                semanticLabel: '关闭标签'.tr,
                density: shadcn.ButtonDensity.compact,
                onPressed: () => requestSessionTabClose(
                  Get.find<SessionController>(),
                  [tab.id],
                ),
                icon: const AppIcon(AppIcons.x, size: 12),
              ),
            ),
            child: MouseRegion(
              onEnter: (_) => _showTooltipLater(),
              onExit: (_) => _hideTooltip(),
              child: CompositedTransformTarget(
                link: _layerLink,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    tab.sessionIds.length > 1
                        ? '${session.title} · ${tab.sessionIds.length}'
                        : session.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.active
                          ? colors.foreground
                          : colors.mutedForeground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
