import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/ai_settings_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../components/app_icon_button.dart';
import '../navigation/app_notice.dart';
import '../rdp/rdp_fullscreen_scope.dart';
import '../shell/agent_sidebar_scope.dart';
import '../shell/widgets/window_controls.dart';
import '../theme/app_theme.dart';
import 'agent_panel.dart';

class AgentToggleButton extends StatelessWidget {
  const AgentToggleButton({this.expanded = false, super.key});
  final bool expanded;

  @override
  Widget build(BuildContext context) => AppIconButton(
    key: const ValueKey('agent-toggle'),
    semanticLabel: (expanded ? '收起 Agent' : 'AI Agent').tr,
    tooltip: (expanded ? '收起 Agent' : '展开 Agent').tr,
    icon: Icon(
      expanded ? shadcn.LucideIcons.panelRightClose : shadcn.LucideIcons.bot,
      size: 16,
    ),
    onPressed: () => toggleAgentPanel(),
  );
}

void toggleAgentPanel() {
  final settings = Get.find<AiSettingsController>();
  unawaited(
    settings.setPanel(visible: !settings.state.value.panelVisible).catchError((
      Object _,
    ) {
      AppNotice.error('AI 设置保存失败，请重试');
    }),
  );
}

/// 在主工作区外侧提供独立右栏，收放方式与左侧服务栏一致。
/// 窄窗口暂时收起左栏，保留中间工作区与独立右栏，收放后恢复左栏。
class AgentWorkspace extends StatefulWidget {
  const AgentWorkspace({required this.sidebar, required this.child, super.key});
  final Widget sidebar;
  final Widget child;
  @override
  State<AgentWorkspace> createState() => _AgentWorkspaceState();
}

class _AgentWorkspaceState extends State<AgentWorkspace> {
  final _panelKey = GlobalKey();
  final _workspaceKey = GlobalKey();
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final fullscreen = RdpFullscreenScope.maybeOf(context)?.fullscreen ?? false;
    if (!Get.isRegistered<AiSettingsController>()) {
      return Row(
        children: [
          Offstage(offstage: fullscreen, child: widget.sidebar),
          Expanded(child: widget.child),
        ],
      );
    }
    final settings = Get.find<AiSettingsController>();
    final generalSettings = Get.find<SettingsController>();
    final theme = shadcn.Theme.of(context);
    final isMac = theme.platform == TargetPlatform.macOS;
    final headerControlSize = AppTheme.windowHeaderControlSize(context);
    final duration = fullscreen || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppTheme.sidebarTransitionDuration;
    return Obx(() {
      final state = settings.state.value;
      final sidebarVisible = generalSettings.sidebarState.value.visible;
      return LayoutBuilder(
        builder: (context, constraints) {
          final visible = state.panelVisible && !fullscreen;
          final sidebarWidth = sidebarVisible ? AppTheme.sidebarWidth : 0.0;
          final compact =
              constraints.maxWidth - sidebarWidth <
              AppTheme.agentMinWidth +
                  AppTheme.agentMinWorkspaceWidth +
                  AppTheme.agentResizeWidth;
          final maxWidth = math.max(
            0.0,
            math.min(
              AppTheme.agentMaxWidth,
              constraints.maxWidth -
                  (compact ? 0 : sidebarWidth) -
                  AppTheme.agentMinWorkspaceWidth -
                  AppTheme.agentResizeWidth,
            ),
          );
          final width = (_dragWidth ?? state.panelWidth).clamp(
            math.min(AppTheme.agentMinWidth, maxWidth),
            maxWidth,
          );
          final workspace = KeyedSubtree(
            key: _workspaceKey,
            child: widget.child,
          );
          final panel = TweenAnimationBuilder<double>(
            tween: Tween(begin: visible ? 1 : 0, end: visible ? 1 : 0),
            duration: duration,
            curve: Curves.easeInOutCubic,
            builder: (context, value, child) => IgnorePointer(
              ignoring: !visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: ExcludeFocus(
                  excluding: !visible,
                  child: ClipRect(
                    key: const ValueKey('agent-sidebar-viewport'),
                    child: Offstage(
                      offstage: value == 0,
                      child: Align(
                        alignment: Alignment.centerRight,
                        widthFactor: value,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: SizedBox(
              key: _panelKey,
              width: width + AppTheme.agentResizeWidth,
              height: constraints.maxHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      key: const ValueKey('agent-resize-handle'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) => setState(
                        () => _dragWidth = (width - details.delta.dx).clamp(
                          math.min(AppTheme.agentMinWidth, maxWidth),
                          maxWidth,
                        ),
                      ),
                      onHorizontalDragEnd: (_) {
                        final saved = _dragWidth;
                        _dragWidth = null;
                        unawaited(
                          settings.setPanel(width: saved).catchError((
                            Object _,
                          ) {
                            AppNotice.error('AI 设置保存失败，请重试');
                          }),
                        );
                      },
                      onHorizontalDragCancel: () =>
                          setState(() => _dragWidth = null),
                      child: SizedBox(
                        width: AppTheme.agentResizeWidth,
                        child: ColoredBox(color: AppTheme.sidebar(context)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: AppTheme.sidebar(context),
                      child: Column(
                        children: [
                          SizedBox(
                            height: AppTheme.windowHeaderHeight,
                            child: Row(
                              children: [
                                const WindowHeaderButton(
                                  child: AgentToggleButton(expanded: true),
                                ),
                                const Expanded(child: WindowDragArea()),
                                if (!isMac)
                                  const SizedBox(
                                    width: AppTheme.windowButtonWidth * 3,
                                  ),
                              ],
                            ),
                          ),
                          const Expanded(child: AgentPanel()),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          return AgentSidebarScope(
            visible: visible,
            sidebarHiddenForSpace: visible && compact && sidebarVisible,
            showSidebar: () async {
              await settings.setPanel(visible: false);
              await generalSettings.setSidebarVisible(true);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Offstage(offstage: fullscreen, child: widget.sidebar),
                    Expanded(child: workspace),
                    panel,
                  ],
                ),
                if (!fullscreen && (!sidebarVisible || (visible && compact)))
                  Positioned(
                    top: AppTheme.sessionPaneTopMargin,
                    left: isMac ? AppTheme.macWindowControlsWidth : 0,
                    height: headerControlSize,
                    child: const WindowHeaderButton(
                      child: SidebarToggleButton(),
                    ),
                  ),
                if (!fullscreen && !visible)
                  Positioned(
                    top: AppTheme.sessionPaneTopMargin,
                    right: isMac ? 0 : AppTheme.windowButtonWidth * 3,
                    height: headerControlSize,
                    child: const WindowHeaderButton(child: AgentToggleButton()),
                  ),
                if (!isMac && !fullscreen)
                  Positioned(
                    top: AppTheme.sessionPaneTopMargin,
                    right: 0,
                    height: headerControlSize,
                    child: const WindowDragBlocker(child: WindowButtons()),
                  ),
              ],
            ),
          );
        },
      );
    });
  }
}
