import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/hosts/host_controller.dart';
import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../application/session/session_layout.dart';
import '../../../application/settings/settings_controller.dart';
import '../../../domain/entities/host.dart';
import '../../../domain/repositories/local_file_repository.dart';
import '../../components/app_copy_button.dart';
import '../../components/app_icon.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_list_row.dart';
import '../../forward/forward_session_panel.dart';
import '../../hosts/host_edit_dialog.dart';
import '../../localization/app_translations.dart';
import '../../proxy/dynamic_proxy_panel.dart';
import '../../rdp/rdp_certificate_prompt.dart';
import '../../rdp/rdp_desktop_panel.dart';
import '../../rdp/rdp_fullscreen_scope.dart';
import '../../sftp/sftp_panel.dart';
import '../../ssh/host_key_confirmation.dart';
import '../../terminal/app_terminal_view.dart';
import '../../terminal/terminal_tab_workspace.dart';
import '../../theme/app_theme.dart';
import '../agent_sidebar_scope.dart';
import '../command_palette.dart';
import '../connect_flow.dart';
import '../session_close_confirmation.dart';
import 'session_tab_pane.dart';

/// 主工作区：会话标签与内容。
///
/// 会话视图按 ID 常驻挂载，切换和排序均保留终端、目录与滚动状态。
class Workspace extends StatefulWidget {
  const Workspace({super.key});

  @override
  State<Workspace> createState() => _WorkspaceState();
}

typedef _TerminalPlacement = ({String tabId, bool split, bool zoomed});

class _WorkspaceState extends State<Workspace> {
  // Move the same content subtree out of TabPane in full screen. Native
  // sessions, frame subscriptions and decoded surfaces keep their lifetime.
  final _contentKey = GlobalKey();

  // 按会话缓存视图实例。外层 Obx 订阅整个会话列表，任一标签变化都会重跑；
  // 会话快照与激活状态都没变时返回同一个 widget 实例，Flutter 会跳过该子树，
  // 避免后台终端、SFTP 目录与代理面板随别的标签一起重建。
  final Map<
    String,
    ({
      Session session,
      bool visible,
      bool active,
      _TerminalPlacement? placement,
      Widget view,
    })
  >
  _views = {};
  final _paneKeys = <String, GlobalKey>{};
  final _terminalHostKeys = <String, GlobalKey<_TerminalHostState>>{};
  final _tabViews =
      <
        String,
        ({SessionTab tab, List<Session> sessions, bool active, Widget view})
      >{};

  void _focusTerminal(String sessionId) =>
      _terminalHostKeys[sessionId]?.currentState?.focusAndReveal();

  Widget _viewFor(
    Session session, {
    required bool visible,
    required bool active,
    _TerminalPlacement? placement,
  }) {
    final cached = _views[session.id];
    if (cached != null &&
        identical(cached.session, session) &&
        cached.visible == visible &&
        cached.active == active &&
        cached.placement == placement) {
      return cached.view;
    }
    final view = TickerMode(
      key: _paneKeys.putIfAbsent(session.id, GlobalKey.new),
      // 当前标签内所有可见窗格都要同步 PTY 尺寸，仅选中窗格接收输入。
      enabled: visible,
      child: ExcludeFocus(
        excluding: !active,
        child: _SessionView(
          session: session,
          active: active,
          placement: placement,
          terminalHostKey: _terminalHostKeys.putIfAbsent(
            session.id,
            GlobalKey<_TerminalHostState>.new,
          ),
        ),
      ),
    );
    _views[session.id] = (
      session: session,
      visible: visible,
      active: active,
      placement: placement,
      view: view,
    );
    return view;
  }

  Widget _tabView(SessionTab tab, List<Session> sessions, bool active) {
    final cached = _tabViews[tab.id];
    if (cached != null &&
        cached.active == active &&
        cached.tab.layout == tab.layout &&
        cached.tab.selectedSessionId == tab.selectedSessionId &&
        cached.sessions.length == sessions.length &&
        Iterable<int>.generate(sessions.length)
            .every((i) => identical(cached.sessions[i], sessions[i]))) {
      return cached.view;
    }
    final view = sessions.first.kind.isInteractiveTerminal
        ? TerminalTabWorkspace(
            tab: tab,
            sessions: sessions,
            active: active,
            onFocusSession: _focusTerminal,
            paneBuilder: (session, selected, zoomed) => _viewFor(
              session,
              visible: active,
              active: active && selected,
              placement: (
                tabId: tab.id,
                split: sessions.length > 1,
                zoomed: zoomed,
              ),
            ),
          )
        : _viewFor(sessions.single, visible: active, active: active);
    _tabViews[tab.id] = (
      tab: tab,
      sessions: sessions,
      active: active,
      view: view,
    );
    return view;
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SessionController>();
    final fullscreen = RdpFullscreenScope.maybeOf(context)?.fullscreen ?? false;
    return ColoredBox(
      color: AppTheme.background(context),
      child: Obx(() {
        final sessions = controller.sessions.toList();
        final tabs = controller.tabs;
        final activeId = controller.activeTabId;

        var index = tabs.indexWhere((tab) => tab.id == activeId);
        if (index < 0) index = 0;
        // 会话数量不变时也可能发生替换，始终按 ID 清理已关闭会话的缓存。
        final ids = {for (final s in sessions) s.id};
        _views.removeWhere((id, _) => !ids.contains(id));
        _paneKeys.removeWhere((id, _) => !ids.contains(id));
        _terminalHostKeys.removeWhere((id, _) => !ids.contains(id));
        final tabIds = tabs.map((tab) => tab.id).toSet();
        _tabViews.removeWhere((id, _) => !tabIds.contains(id));
        final sessionsById = {
          for (final session in sessions) session.id: session,
        };

        return RdpCertificatePrompts(
          sessions: sessions,
          controller: controller,
          child: SessionTabPane(
            sessions: sessions,
            tabs: tabs,
            activeId: activeId,
            fullscreen: fullscreen,
            child: KeyedSubtree(
              key: _contentKey,
              child: sessions.isEmpty
                  ? const _WelcomeView()
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        for (var i = 0; i < tabs.length; i++)
                          Offstage(
                            key: ValueKey(tabs[i].id),
                            offstage: i != index,
                            child: _tabView(tabs[i], [
                              for (final id in tabs[i].sessionIds)
                                sessionsById[id]!,
                            ], i == index),
                          ),
                      ],
                    ),
            ),
          ),
        );
      }),
    );
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView();

  List<Host> _recentHosts() {
    if (!Get.isRegistered<HostController>()) return const [];
    final byId = {
      for (final host in Get.find<HostController>().hosts) host.id: host,
    };
    if (byId.isEmpty) return const [];
    final recentIds = <String>[
      if (Get.isRegistered<SessionController>())
        ...Get.find<SessionController>().recentHostIds,
      if (Get.isRegistered<SettingsController>())
        ...Get.find<SettingsController>().sidebarState.value.recentHostIds,
    ];
    final result = <Host>[];
    final seen = <String>{};
    for (final id in recentIds) {
      final host = byId[id];
      if (host != null && seen.add(id)) {
        result.add(host);
        if (result.length >= 4) break;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    final colors = theme.colorScheme;
    final hintStyle = TextStyle(fontSize: 13, color: colors.mutedForeground);
    final isMac = theme.platform == TargetPlatform.macOS;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.surface(context),
                  border: Border.all(color: AppTheme.border(context)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const AppIcon(AppIcons.terminal, size: 26),
              ),
              const SizedBox(height: 24),
              shadcn.OutlineBadge(child: Text('本地工作区'.tr)),
              const SizedBox(height: 16),
              Text(
                '连接你的下一台服务器'.tr,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '从左侧选择服务，或创建一个新连接。凭据安全保存在本机，工作流始终由你掌控。'.tr,
                style: hintStyle.copyWith(height: 1.8),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  shadcn.PrimaryButton(
                    onPressed: () => showCommandPalette(context),
                    leading: const AppIcon(AppIcons.arrowUpRight, size: 16),
                    child: Text('快速连接'.tr),
                  ),
                  shadcn.GhostButton(
                    onPressed: () => showHostEditDialog(context),
                    leading: const AppIcon(AppIcons.plus, size: 16),
                    child: Text('新建服务'.tr),
                  ),
                ],
              ),
              if (Get.isRegistered<HostController>())
                Obx(() {
                  final hosts = _recentHosts();
                  if (hosts.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    key: const ValueKey('welcome-recent-hosts'),
                    padding: const EdgeInsets.only(top: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '最近连接'.tr,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colors.mutedForeground,
                                ),
                              ),
                            ),
                            shadcn.GhostButton(
                              size: shadcn.ButtonSize.small,
                              onPressed: () => showCommandPalette(context),
                              child: Text(
                                '查看全部'.tr,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.mutedForeground,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            const spacing = 10.0;
                            final columns = constraints.maxWidth >= 420 ? 2 : 1;
                            final cardWidth =
                                (constraints.maxWidth -
                                    spacing * (columns - 1)) /
                                columns;
                            return Wrap(
                              spacing: spacing,
                              runSpacing: spacing,
                              children: [
                                for (final host in hosts)
                                  SizedBox(
                                    width: cardWidth,
                                    child: _WelcomeHostCard(host: host),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }),
              const SizedBox(height: 24),
              shadcn.Card(
                theme: const shadcn.CardTheme(padding: EdgeInsets.all(20)),
                child: Column(
                  children: [
                    _ShortcutHint(
                      keys: isMac ? '⌘K' : 'Ctrl + Shift + K',
                      label: '快速连接'.tr,
                      style: hintStyle,
                    ),
                    const SizedBox(height: 14),
                    _ShortcutHint(
                      keys: isMac ? '⌘N' : 'Ctrl + Shift + N',
                      label: '新建服务'.tr,
                      style: hintStyle,
                    ),
                    const SizedBox(height: 14),
                    _ShortcutHint(
                      keys: isMac ? '⌘,' : 'Ctrl + ,',
                      label: '打开设置'.tr,
                      style: hintStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  AppIcon(
                    AppIcons.shieldCheck,
                    size: 14,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '数据保存在本机 · AI 按需连接外部 API'.tr,
                      style: hintStyle.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeHostCard extends StatelessWidget {
  const _WelcomeHostCard({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: AppSurfaceAction(
        key: ValueKey('welcome-host-${host.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => unawaited(connectToHost(context, host)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              AppIcon(
                AppIcons.forServiceType(host.serviceType),
                size: 18,
                color: host.colorValue != null
                    ? Color(host.colorValue!)
                    : colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AppIcon(
                AppIcons.arrowRight,
                size: 14,
                color: colors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutHint extends StatelessWidget {
  const _ShortcutHint({
    required this.keys,
    required this.label,
    required this.style,
  });

  final String keys;
  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: style)),
        shadcn.OutlineBadge(
          child: Text(keys, style: style.copyWith(fontSize: 11)),
        ),
      ],
    );
  }
}

class _SessionView extends StatelessWidget {
  const _SessionView({
    required this.session,
    required this.active,
    required this.placement,
    this.terminalHostKey,
  });

  final Session session;
  final bool active;
  final _TerminalPlacement? placement;
  final GlobalKey<_TerminalHostState>? terminalHostKey;

  @override
  Widget build(BuildContext context) {
    final fullscreen = RdpFullscreenScope.maybeOf(context);
    if (session.kind == SessionKind.portForward) {
      return ForwardSessionPanel(session: session);
    }
    if (session.kind == SessionKind.dynamicProxy) {
      return DynamicProxyPanel(session: session, active: active);
    }
    if (session.kind == SessionKind.fileTransfer &&
        session.engineSession != null) {
      // 认证期间保留两侧浏览器；指纹确认仍覆盖在原面板之上。
      return Stack(
        fit: StackFit.expand,
        children: [
          SftpPanel(
            key: ValueKey('sftp-${session.id}'),
            session: session,
            active: active && !session.phase.isBusy,
            localFiles: Get.find<LocalFileRepository>(),
            onReconnect: () =>
                Get.find<SessionController>().reconnectFileTransfer(session.id),
          ),
          if (session.phase == SessionPhase.hostKeyPending &&
              session.hostKeyReview != null)
            ColoredBox(
              color: AppTheme.background(context),
              child: HostKeyConfirmation(
                review: session.hostKeyReview!,
                onDecision: (trust) => Get.find<SessionController>()
                    .confirmHostKey(session.id, trust: trust),
              ),
            ),
          if (session.phase == SessionPhase.failed &&
              session.hostKeyFailure != null)
            ColoredBox(
              color: AppTheme.background(context),
              child: _FailedView(session: session),
            ),
        ],
      );
    }
    return switch (session.phase) {
      SessionPhase.failed => _FailedView(session: session),
      SessionPhase.hostKeyPending when session.hostKeyReview != null =>
        HostKeyConfirmation(
          review: session.hostKeyReview!,
          onDecision: (trust) => Get.find<SessionController>().confirmHostKey(
            session.id,
            trust: trust,
          ),
        ),
      SessionPhase.ready
          when session.kind == SessionKind.remoteDesktop &&
              session.desktopSession != null =>
        RdpDesktopPanel(
          key: ValueKey('rdp-${session.id}'),
          session: session.desktopSession!,
          protocolLabel: session.host.serviceType.label,
          active: active,
          fullscreen: fullscreen?.sessionId == session.id,
          fullscreenBusy: fullscreen?.busy ?? false,
          onToggleFullscreen: fullscreen == null
              ? null
              : () => unawaited(
                  fullscreen.fullscreen
                      ? fullscreen.exit()
                      : fullscreen.enter(session.id),
                ),
          onError: (message) =>
              Get.find<SessionController>().desktopFailed(session.id, message),
        ),
      SessionPhase.ready ||
      SessionPhase.closed when session.terminal != null => _TerminalHost(
        key: terminalHostKey,
        session: session,
        active: active,
        placement: placement,
      ),
      _ => _ConnectingView(session: session),
    };
  }
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SessionController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const shadcn.CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在连接到 @address…'.trParams({'address': session.address}),
              key: const ValueKey('connecting-status-text'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.mutedForeground),
            ),
            const SizedBox(height: 16),
            shadcn.OutlineButton(
              key: const ValueKey('connecting-cancel'),
              onPressed: () => session.kind.isInteractiveTerminal
                  ? controller.close(session.id)
                  : requestSessionTabClose(controller, [session.id]),
              child: Text('取消连接'.tr),
            ),
          ],
        ),
      ),
    );
  }
}

/// 终端宿主：常驻于工作区中，成为激活标签时把焦点交还终端。
class _TerminalHost extends StatefulWidget {
  const _TerminalHost({
    required this.session,
    required this.active,
    required this.placement,
    super.key,
  });

  final Session session;
  final bool active;
  final _TerminalPlacement? placement;

  @override
  State<_TerminalHost> createState() => _TerminalHostState();
}

class _TerminalHostState extends State<_TerminalHost> {
  final _focusNode = FocusNode();
  final _terminalViewKey = GlobalKey<AppTerminalViewState>();

  void focusAndReveal() {
    if (!mounted || !widget.active) return;
    _terminalViewKey.currentState?.scrollToBottom();
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _focusWhenActive();
  }

  @override
  void didUpdateWidget(_TerminalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        (!oldWidget.active ||
            widget.placement?.zoomed != oldWidget.placement?.zoomed ||
            widget.placement?.tabId != oldWidget.placement?.tabId)) {
      _focusWhenActive();
    }
  }

  void _focusWhenActive() {
    // autofocus 不会替换搜索框等控件已有的焦点。等终端挂载后明确接管，
    // 同时让 xterm 建立文本输入连接，保留 Windows 输入法支持。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SessionController>();
    final session = widget.session;
    final canSplit = controller.canSplitTerminal(session.id);
    final canTransfer = controller.canOpenFileTransfer(session.id);
    final canReconnect = controller.canReconnect(session.id);
    final zoomed = widget.placement?.zoomed == true;
    final terminalView = AppTerminalView(
      session.terminal!,
      key: _terminalViewKey,
      focusNode: _focusNode,
      active: widget.active,
      canInput: session.phase == SessionPhase.ready,
      hasPaneControls: widget.placement?.split == true,
      onUserInput: zoomed
          ? null
          : (send) => controller.syncUserInput(session.id, send),
      inputSyncPanes: zoomed
          ? null
          : () => controller.inputSyncPaneNames(session.id),
      onSplitHorizontal: canSplit
          ? () => unawaited(
              controller.splitTerminal(session.id, SessionSplitAxis.horizontal),
            )
          : null,
      onSplitVertical: canSplit
          ? () => unawaited(
              controller.splitTerminal(session.id, SessionSplitAxis.vertical),
            )
          : null,
      onOpenFileTransfer: canTransfer
          ? () => unawaited(controller.openFileTransfer(session.id))
          : null,
      onReconnect: canReconnect
          ? () => unawaited(controller.reconnect(session.id))
          : null,
      onQuoteSelection: AgentSidebarScope.maybeOf(context)
          ?.onQuoteTerminalSelection,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        terminalView,
        if (session.phase == SessionPhase.closed)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: Container(
                  key: const ValueKey('terminal-disconnected-banner'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.terminalControlBackground.withValues(
                      alpha: 0.96,
                    ),
                    border: Border.all(color: AppTheme.terminalSelectedBorder),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(color: Color(0x50000000), blurRadius: 12),
                    ],
                  ),
                  child: _DisconnectedTerminalActions(
                    onClose: () => unawaited(controller.close(session.id)),
                    onReconnect: canReconnect
                        ? () => unawaited(controller.retry(session.id))
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _DisconnectedTerminalActions extends StatelessWidget {
  const _DisconnectedTerminalActions({required this.onClose, this.onReconnect});

  final VoidCallback onClose;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxWidth < AppTheme.terminalDisconnectCompactWidth;
      const closeKey = ValueKey('terminal-disconnected-close');
      const reconnectKey = ValueKey('terminal-disconnected-reconnect');
      return Row(
        children: [
          if (!compact) ...[
            const AppIcon(
              AppIcons.unplug,
              size: 15,
              color: StatusColors.closed,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              (compact ? '连接已断开' : '连接已断开，已保留历史输出').tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.terminalForeground,
              ),
            ),
          ),
          if (compact) ...[
            AppIconButton(
              key: closeKey,
              semanticLabel: '关闭'.tr,
              tooltip: '关闭'.tr,
              onPressed: onClose,
              icon: const AppIcon(
                AppIcons.x,
                size: 13,
                color: AppTheme.terminalForeground,
              ),
            ),
            if (onReconnect != null)
              AppIconButton(
                key: reconnectKey,
                semanticLabel: '重新连接'.tr,
                tooltip: '重新连接'.tr,
                onPressed: onReconnect,
                icon: const AppIcon(
                  AppIcons.rotateCw,
                  size: 13,
                  color: AppTheme.terminalForeground,
                ),
              ),
          ] else ...[
            const SizedBox(width: 8),
            shadcn.OutlineButton(
              key: closeKey,
              size: shadcn.ButtonSize.small,
              onPressed: onClose,
              child: Text('关闭'.tr),
            ),
            if (onReconnect != null) ...[
              const SizedBox(width: 8),
              shadcn.PrimaryButton(
                key: reconnectKey,
                size: shadcn.ButtonSize.small,
                onPressed: onReconnect,
                leading: const AppIcon(AppIcons.rotateCw, size: 13),
                child: Text('重新连接'.tr),
              ),
            ],
          ],
        ],
      );
    },
  );
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SessionController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    final errorMessage = AppTranslations.error(session.error ?? '未知错误');
    final hosts = savedHostControllerForSession(session);
    final container = session.dockerTarget;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIcon(
              AppIcons.unplug,
              size: 44,
              color: StatusColors.failed,
            ),
            const SizedBox(height: 16),
            Text(
              container == null
                  ? '无法连接到 @address'.trParams({'address': session.address})
                  : '无法打开容器 @name 的终端'.trParams({'name': container.name}),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    errorMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                AppCopyButton(
                  key: const ValueKey('failed-copy-error'),
                  text: errorMessage,
                  size: 13,
                  semanticLabel: '复制错误信息'.tr,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                shadcn.OutlineButton(
                  onPressed: () => session.kind.isInteractiveTerminal
                      ? controller.close(session.id)
                      : requestSessionTabClose(controller, [session.id]),
                  child: Text('关闭'.tr),
                ),
                if (hosts != null)
                  Obx(
                    () => hosts.hosts.any((h) => h.id == session.host.id)
                        ? shadcn.OutlineButton(
                            key: const ValueKey('failed-edit-host'),
                            onPressed: () => showSessionHostEditDialog(
                              context,
                              session,
                              retryOnSave: true,
                            ),
                            leading: const AppIcon(AppIcons.pencil, size: 15),
                            child: Text('编辑服务'.tr),
                          )
                        : const SizedBox.shrink(),
                  ),
                if (session.hostKeyFailure?.hasChanged == true)
                  shadcn.OutlineButton(
                    key: const ValueKey('clear-host-key-and-retry'),
                    onPressed: () =>
                        controller.clearHostKeyAndRetry(session.id),
                    leading: const AppIcon(AppIcons.trash2, size: 16),
                    child: Text('清除指纹并重试'.tr),
                  ),
                shadcn.PrimaryButton(
                  onPressed: () => retryFailedSession(context, session),
                  leading: const AppIcon(AppIcons.rotateCw, size: 16),
                  child: Text('重试'.tr),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
