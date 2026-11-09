import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../../application/session/session.dart';
import '../../../application/session/session_controller.dart';
import '../../../application/session/session_layout.dart';
import '../../../domain/repositories/local_file_repository.dart';
import '../../components/app_icon.dart';
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
import '../command_palette.dart';
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

class _WorkspaceState extends State<Workspace> {
  // Move the same content subtree out of TabPane in full screen. Native
  // sessions, frame subscriptions and decoded surfaces keep their lifetime.
  final _contentKey = GlobalKey();

  // 按会话缓存视图实例。外层 Obx 订阅整个会话列表，任一标签变化都会重跑；
  // 会话快照与激活状态都没变时返回同一个 widget 实例，Flutter 会跳过该子树，
  // 避免后台终端、SFTP 目录与代理面板随别的标签一起重建。
  final Map<String, ({Session session, bool visible, bool active, Widget view})>
  _views = {};
  final _paneKeys = <String, GlobalKey>{};
  final _tabViews =
      <
        String,
        ({SessionTab tab, List<Session> sessions, bool active, Widget view})
      >{};

  Widget _viewFor(
    Session session, {
    required bool visible,
    required bool active,
  }) {
    final cached = _views[session.id];
    if (cached != null &&
        identical(cached.session, session) &&
        cached.visible == visible &&
        cached.active == active) {
      return cached.view;
    }
    final view = TickerMode(
      key: _paneKeys.putIfAbsent(session.id, GlobalKey.new),
      // 当前标签内所有可见窗格都要同步 PTY 尺寸，仅选中窗格接收输入。
      enabled: visible,
      child: ExcludeFocus(
        excluding: !active,
        child: _SessionView(session: session, active: active),
      ),
    );
    _views[session.id] = (
      session: session,
      visible: visible,
      active: active,
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
            paneBuilder: (session, selected) =>
                _viewFor(session, visible: active, active: active && selected),
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

  @override
  Widget build(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    final colors = theme.colorScheme;
    final hintStyle = TextStyle(fontSize: 13, color: colors.mutedForeground);
    final modifier = theme.platform == TargetPlatform.macOS ? '⌘' : 'Ctrl + ';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
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
                    leading: const AppIcon(
                      AppIcons.arrowUpRight,
                      size: 16,
                    ),
                    child: Text('快速连接'.tr),
                  ),
                  shadcn.GhostButton(
                    onPressed: () => showHostEditDialog(context),
                    leading: const AppIcon(AppIcons.plus, size: 16),
                    child: Text('新建服务'.tr),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              shadcn.Card(
                theme: const shadcn.CardTheme(padding: EdgeInsets.all(20)),
                child: Column(
                  children: [
                    _ShortcutHint(
                      keys: '${modifier}K',
                      label: '快速连接'.tr,
                      style: hintStyle,
                    ),
                    const SizedBox(height: 14),
                    _ShortcutHint(
                      keys: '${modifier}N',
                      label: '新建服务'.tr,
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
  const _SessionView({required this.session, required this.active});

  final Session session;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fullscreen = RdpFullscreenScope.maybeOf(context);
    if (session.kind == SessionKind.portForward) {
      return ForwardSessionPanel(session: session);
    }
    if (session.kind == SessionKind.dynamicProxy) {
      return DynamicProxyPanel(session: session);
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
          dynamicResolution: !session.host.isVnc,
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
      SessionPhase.ready
          when session.kind == SessionKind.fileTransfer &&
              session.engineSession != null =>
        SftpPanel(
          key: ValueKey('sftp-${session.id}'),
          session: session,
          active: active,
          localFiles: Get.find<LocalFileRepository>(),
        ),
      SessionPhase.ready || SessionPhase.closed when session.terminal != null =>
        _TerminalHost(session: session, active: active),
      _ => const Center(child: shadcn.CircularProgressIndicator()),
    };
  }
}

/// 终端宿主：常驻于工作区中，成为激活标签时把焦点交还终端。
class _TerminalHost extends StatefulWidget {
  const _TerminalHost({required this.session, required this.active});

  final Session session;
  final bool active;

  @override
  State<_TerminalHost> createState() => _TerminalHostState();
}

class _TerminalHostState extends State<_TerminalHost> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusWhenActive();
  }

  @override
  void didUpdateWidget(_TerminalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
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
  Widget build(BuildContext context) => AppTerminalView(
    widget.session.terminal!,
    focusNode: _focusNode,
    active: widget.active,
  );
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.session});

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
            const AppIcon(
              AppIcons.unplug,
              size: 44,
              color: StatusColors.failed,
            ),
            const SizedBox(height: 16),
            Text(
              session.kind == SessionKind.containerTerminal
                  ? '无法打开容器 @name 的终端'.trParams({'name': session.title})
                  : '无法连接到 @address'.trParams({'address': session.address}),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              AppTranslations.error(session.error ?? '未知错误'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
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
                if (session.hostKeyFailure?.hasChanged == true)
                  shadcn.OutlineButton(
                    key: const ValueKey('clear-host-key-and-retry'),
                    onPressed: () =>
                        controller.clearHostKeyAndRetry(session.id),
                    leading: const AppIcon(AppIcons.trash2, size: 16),
                    child: Text('清除指纹并重试'.tr),
                  ),
                shadcn.PrimaryButton(
                  onPressed: () => controller.retry(session.id),
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
