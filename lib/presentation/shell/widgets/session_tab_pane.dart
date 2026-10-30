import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/ai/ai_settings_controller.dart';
import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../application/settings/settings_controller.dart';
import '../../ai/agent_workspace.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_menu.dart';
import '../../navigation/app_navigation.dart';
import '../../navigation/app_notice.dart';
import '../../terminal/batch_command_dialog.dart';
import '../../theme/app_theme.dart';
import '../agent_sidebar_scope.dart';
import '../session_close_confirmation.dart';
import 'window_controls.dart';

/// 会话标签与内容容器；内容的生命周期由工作区管理。
class SessionTabPane extends StatefulWidget {
  const SessionTabPane({
    required this.sessions,
    required this.activeId,
    required this.child,
    this.fullscreen = false,
    super.key,
  });

  final List<Session> sessions;
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
  bool? _sidebarVisible;

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(SessionTabPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.sessions.map((session) => session.id).toList();
    _tabKeys.removeWhere((id, _) => !ids.contains(id));
    _tabItems.removeWhere((id, _) => !ids.contains(id));
    if (oldWidget.activeId != widget.activeId ||
        oldWidget.fullscreen != widget.fullscreen ||
        !listEquals(
          oldWidget.sessions.map((session) => session.id).toList(),
          ids,
        )) {
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
    final activeIndex = widget.sessions.indexWhere(
      (session) => session.id == widget.activeId,
    );
    if (activeIndex < 0) return;

    BuildContext? tabContext;
    var nearestIndex = -1;
    for (var index = 0; index < widget.sessions.length; index++) {
      final context = _tabKeys[widget.sessions[index].id]?.currentContext;
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
    final settings = Get.find<SettingsController>();
    return Obx(() {
      final sidebarVisible =
          settings.sidebarState.value.visible &&
          !(AgentSidebarScope.maybeOf(context)?.sidebarHiddenForSpace ?? false);
      return LayoutBuilder(
        builder: (context, constraints) {
          if (_paneWidth != constraints.maxWidth ||
              _sidebarVisible != sidebarVisible) {
            _paneWidth = constraints.maxWidth;
            _sidebarVisible = sidebarVisible;
            _scheduleReveal();
          }
          return _buildPane(context, sidebarVisible);
        },
      );
    });
  }

  Widget _buildPane(BuildContext context, bool sidebarVisible) {
    if (widget.fullscreen) return widget.child;
    final sessions = widget.sessions;
    final sessionsById = {for (final session in sessions) session.id: session};
    final activeId = widget.activeId;
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final agentSidebar = AgentSidebarScope.maybeOf(context);
    final headerControlSize = AppTheme.windowHeaderControlSize(context);
    final paneRadius = AppTheme.sessionPaneRadius(context);
    final controller = Get.find<SessionController>();
    final activeIndex = sessions.indexWhere(
      (session) => session.id == activeId,
    );
    return ColoredBox(
      color: AppTheme.sidebar(context),
      child: WindowDragRegion(
        height: AppTheme.sessionPaneTopMargin + headerControlSize,
        child: Padding(
          padding: const EdgeInsets.only(top: AppTheme.sessionPaneTopMargin),
          child: shadcn.TabPane<String>(
            borderRadius: AppTheme.sessionPaneRadius(context),
            items: [
              for (final session in sessions)
                _tabItems.putIfAbsent(
                  session.id,
                  () => shadcn.TabPaneData(session.id),
                ),
            ],
            focused: activeIndex < 0 ? 0 : activeIndex,
            onFocused: (index) {
              if (_ignoreSortFocus) return;
              if (index >= 0 && index < sessions.length) {
                controller.activate(sessions[index].id);
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
              if (agentSidebar != null && !sidebarVisible)
                SizedBox(
                  width: math.max(
                    0,
                    (isMac ? AppTheme.macWindowControlsWidth : 0) +
                        headerControlSize -
                        paneRadius.bottomLeft.x,
                  ),
                ),
              if (agentSidebar == null && isMac && !sidebarVisible)
                const SizedBox(
                  width: AppTheme.macWindowControlsWidth,
                  child: WindowDragArea(),
                ),
              if (agentSidebar == null && !sidebarVisible)
                const WindowDragBlocker(child: SidebarToggleButton()),
              if (sessions.isNotEmpty)
                WindowDragBlocker(
                  child: AppMenuButton<String>(
                    icon: const Icon(shadcn.LucideIcons.chevronDown, size: 16),
                    semanticLabel: '会话列表'.tr,
                    selectedValue: activeId,
                    items: [
                      for (final session in sessions)
                        (
                          session.id,
                          '${session.title} · ${switch (session.kind) {
                            SessionKind.terminal => '终端'.tr,
                            SessionKind.fileTransfer => '文件传输'.tr,
                            SessionKind.portForward => '端口转发'.tr,
                            SessionKind.dynamicProxy => '动态代理'.tr,
                            SessionKind.remoteDesktop => '远程桌面'.tr,
                          }}',
                        ),
                    ],
                    actions: [('batch-command', '批量执行命令'.tr)],
                    onSelected: (value) async {
                      if (value != 'batch-command') {
                        controller.activate(value);
                        _scheduleReveal();
                        return;
                      }
                      final result =
                          await AppNavigation.dialog<BatchCommandResult>(
                            BatchCommandDialog(controller: controller),
                          );
                      if (result == null) return;
                      if (result.skipped > 0 || result.failed > 0) {
                        AppNotice.error(
                          '已发送至 @sent 个终端，@skipped 个已断开，@failed 个发送失败'.trParams(
                            {
                              'sent': '${result.sent}',
                              'skipped': '${result.skipped}',
                              'failed': '${result.failed}',
                            },
                          ),
                        );
                      } else {
                        AppNotice.success(
                          '命令已发送至 @count 个终端'.trParams({
                            'count': '${result.sent}',
                          }),
                        );
                      }
                    },
                  ),
                ),
            ],
            trailing: [
              const SizedBox(
                width: AppTheme.windowDragWidth,
                child: WindowDragArea(),
              ),
              if (agentSidebar == null &&
                  Get.isRegistered<AiSettingsController>())
                const WindowHeaderButton(child: AgentToggleButton()),
              if (!isMac && agentSidebar == null)
                const WindowDragBlocker(child: WindowButtons()),
              if (agentSidebar?.visible == false)
                SizedBox(
                  width: math.max(
                    0,
                    (isMac ? 0 : AppTheme.windowButtonWidth * 3) +
                        headerControlSize -
                        paneRadius.bottomRight.x,
                  ),
                ),
            ],
            itemBuilder: (context, item, index) {
              final session = sessionsById[item.data]!;
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
                          : _tabKeys.putIfAbsent(session.id, GlobalKey.new),
                      child: shadcn.ContextMenu(
                        items: appMenuItems<String>(
                          [
                            ('close-current', '关闭当前标签'.tr),
                            ('close-others', '关闭其他标签'.tr),
                            ('close-all', '关闭全部标签'.tr),
                          ],
                          (action) => unawaited(switch (action) {
                            'close-current' => requestSessionTabClose(
                              controller,
                              [session.id],
                            ),
                            'close-others' => requestSessionTabClose(
                              controller,
                              controller.sessions
                                  .where((s) => s.id != session.id)
                                  .map((s) => s.id),
                              keepSessionId: session.id,
                            ),
                            'close-all' => requestSessionTabClose(
                              controller,
                              controller.sessions.map((s) => s.id),
                            ),
                            _ => Future<void>.value(),
                          }),
                        ),
                        child: shadcn.KeyedTabItem<String>(
                          key: session.id,
                          child: _SessionTab(
                            session: session,
                            active: index == activeIndex,
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

class _SessionTab extends StatelessWidget {
  const _SessionTab({required this.session, required this.active});

  final Session session;
  final bool active;

  Color get _statusColor => switch (session.phase) {
    SessionPhase.ready => StatusColors.ready,
    SessionPhase.failed => StatusColors.failed,
    SessionPhase.closed => StatusColors.closed,
    _ => StatusColors.connecting,
  };

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: AppTheme.sessionTabMinWidth),
      child: shadcn.Label(
        leading: Icon(
          switch (session.kind) {
            SessionKind.fileTransfer => shadcn.LucideIcons.folderOpen,
            SessionKind.portForward => shadcn.LucideIcons.arrowLeftRight,
            SessionKind.dynamicProxy => shadcn.LucideIcons.network,
            SessionKind.terminal => shadcn.LucideIcons.terminal,
            SessionKind.remoteDesktop => shadcn.LucideIcons.monitor,
          },
          size: 14,
          color: _statusColor,
        ),
        trailing: AppIconButton(
          key: ValueKey('session-tab-close-${session.id}'),
          semanticLabel: '关闭标签'.tr,
          density: shadcn.ButtonDensity.compact,
          onPressed: () => requestSessionTabClose(
            Get.find<SessionController>(),
            [session.id],
          ),
          icon: const Icon(shadcn.LucideIcons.x, size: 12),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(
            session.title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? colors.foreground : colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}
