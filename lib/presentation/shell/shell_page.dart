import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../../application/updates/app_update_controller.dart';
import '../../domain/proxy/system_proxy.dart';
import '../../domain/window/app_window.dart';
import '../ai/agent_workspace.dart';
import '../components/app_dialog.dart';
import '../hosts/host_edit_dialog.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../rdp/rdp_fullscreen_scope.dart';
import '../settings/app_update_section.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'agent_sidebar_scope.dart';
import 'command_palette.dart';
import 'session_close_confirmation.dart';
import 'widgets/sidebar.dart';
import 'widgets/window_controls.dart';
import 'widgets/workspace.dart';
import 'workspace_visibility.dart';

/// 应用主框架：左侧服务栏、中间会话工作区和独立 Agent 右栏。
///
/// 全局快捷键：
/// - ⌘K / Ctrl+Shift+K 命令面板（快速连接）
/// - ⌘N / Ctrl+Shift+N 新建服务
/// - ⌘, / Ctrl+, 打开设置
///
/// Windows/Linux 下 K/N 需配合 Shift，避免劫持 bash/vim 常用的 Ctrl+K / Ctrl+N；
/// 远程桌面（RDP/VNC）全屏时放行所有全局快捷键给远端桌面。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with AppWindowListener {
  static const _windowChannel = MethodChannel('pagashell/window');

  String? _fullscreenId;
  bool _fullscreenBusy = false;
  Completer<void>? _nativeTransition;
  bool? _nativeTarget;
  late final Worker _sessionChanges;
  late final AppLifecycleListener _lifecycle;
  final _monitoringVisible = ValueNotifier(true);
  bool _windowMinimized = false;
  AppLifecycleState? _lifecycleState;
  Future<bool>? _exitPending;
  bool _allowExit = false;
  bool _destroying = false;
  AppUpdateController? _updates;
  late final Future<bool> Function(Future<void> Function()) _updateExit;
  final _shortcutKeys = <PhysicalKeyboardKey>{};
  final _sidebar = GlobalKey<SidebarStateView>();
  SessionController get _sessions => Get.find<SessionController>();
  late final AppWindow _window = Get.find<AppWindow>();

  @override
  void initState() {
    super.initState();
    _windowChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'showSettings':
          _openSettings();
        case 'showQuickConnect':
          _openQuickConnect();
        case 'newService':
          _newService();
        case 'closeActiveTab':
          _closeActiveTab();
        default:
          throw MissingPluginException();
      }
    });
    FocusManager.instance.addEarlyKeyEventHandler(_handleShortcut);
    _window.addListener(this);
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    _updateMonitoringVisibility();
    _lifecycle = AppLifecycleListener(
      onInactive: _shortcutKeys.clear,
      onStateChange: (state) {
        _lifecycleState = state;
        _updateMonitoringVisibility();
      },
      onExitRequested: () async =>
          await _prepareExit() ? AppExitResponse.exit : AppExitResponse.cancel,
    );
    _sessionChanges = everAll([_sessions.sessions, _sessions.activeSessionId], (
      _,
    ) {
      final id = _fullscreenId;
      if (id != null && !_isDesktopReady(id)) unawaited(_exitFullscreen());
    });
    if (Get.isRegistered<AppUpdateController>()) {
      final updates = _updates = Get.find<AppUpdateController>();
      _updateExit = (commit) => _exitApplication(beforeDestroy: commit);
      updates.exitForUpdate = _updateExit;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_checkForUpdates()),
      );
    }
  }

  Future<void> _checkForUpdates() async {
    final updates = _updates!;
    final release = await updates.checkOnStartup();
    if (release == null) return;
    // Delay the prompt until the current form or remote desktop is closed.
    while (mounted &&
        !_destroying &&
        (Get.isDialogOpen == true || _fullscreenId != null)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (mounted &&
        !_destroying &&
        Get.find<SettingsController>().automaticUpdates.value) {
      await showAppUpdateDialog(updates, release, automatic: true);
    }
  }

  bool _isDesktopReady(String id) =>
      _sessions.activeSessionId.value == id &&
      _sessions.sessions.any(
        (s) =>
            s.id == id &&
            s.kind == SessionKind.remoteDesktop &&
            s.phase == SessionPhase.ready,
      );

  Future<void> _setNativeFullscreen(bool fullscreen) async {
    // The method returns before AppKit/GTK finish their animation. Serialize
    // transitions using the native completion event, with a state fallback for
    // window managers that omit an event when already in the requested state.
    final transition = Completer<void>();
    _nativeTransition = transition;
    _nativeTarget = fullscreen;
    try {
      await _window.setFullScreen(fullscreen);
      if (!mounted) return;
      await transition.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () async {
          if (await _window.isFullScreen() != fullscreen) {
            throw StateError('Window full screen transition was not confirmed');
          }
        },
      );
    } finally {
      if (identical(_nativeTransition, transition)) {
        _nativeTransition = null;
        _nativeTarget = null;
      }
    }
  }

  Future<void> _enterFullscreen(String id) async {
    if (_fullscreenBusy || !_isDesktopReady(id)) return;
    setState(() {
      _fullscreenId = id;
      _fullscreenBusy = true;
    });
    try {
      await _setNativeFullscreen(true);
    } on Object {
      if (mounted && _fullscreenId == id) {
        setState(() => _fullscreenId = null);
        AppNotice.error('无法进入全屏，请重试'.tr);
      }
    } finally {
      if (mounted) {
        setState(() => _fullscreenBusy = false);
        if (_fullscreenId != null && !_isDesktopReady(_fullscreenId!)) {
          unawaited(_exitFullscreen());
        }
      }
    }
  }

  Future<void> _exitFullscreen() async {
    if (_fullscreenBusy || _fullscreenId == null) return;
    setState(() => _fullscreenBusy = true);
    try {
      await _setNativeFullscreen(false);
      if (mounted) setState(() => _fullscreenId = null);
    } on Object {
      if (mounted) AppNotice.error('无法退出全屏，请重试'.tr);
    } finally {
      if (mounted) setState(() => _fullscreenBusy = false);
    }
  }

  void _toggleFullscreen() {
    if (_fullscreenId != null) {
      unawaited(_exitFullscreen());
    } else {
      final id = _sessions.activeSessionId.value;
      if (id != null) unawaited(_enterFullscreen(id));
    }
  }

  @override
  void onWindowCloseRequested(AppWindowCloseRequest request) {
    request.cancel();
    unawaited(_exitApplication());
  }

  Future<bool> _exitApplication({
    Future<void> Function()? beforeDestroy,
  }) async {
    if (_destroying) return false;
    _destroying = true;
    try {
      if (!await _prepareExit()) {
        _destroying = false;
        return false;
      }
      await beforeDestroy?.call();
      if (defaultTargetPlatform == TargetPlatform.windows) {
        // window_manager.destroy() posts WM_QUIT on Windows. The runner must
        // destroy the view/plugins before its message loop and COM shut down.
        await _windowChannel.invokeMethod<void>('destroy');
      } else {
        await _window.destroy();
      }
      return true;
    } on Object {
      _destroying = false;
      _allowExit = false;
      rethrow;
    }
  }

  Future<bool> _prepareExit() {
    if (_allowExit) return Future.value(true);
    return _exitPending ??= (() async {
      var allow = true;
      if (Get.isRegistered<AgentController>() &&
          !Get.isPrepared<AgentController>()) {
        final agent = Get.find<AgentController>();
        allow = await agent.prepareForExit();
        if (!allow && mounted) {
          allow =
              await AppNavigation.dialog<bool>(
                AppDialog(
                  title: Text('Agent 数据尚未保存'.tr),
                  content: Text('本地保存失败，可取消退出后重试。仍然退出将丢失尚未保存的记录和偏好设置。'.tr),
                  actions: [
                    shadcn.OutlineButton(
                      onPressed: () => AppNavigation.closeDialog(result: false),
                      child: Text('取消'.tr),
                    ),
                    shadcn.DestructiveButton(
                      key: const ValueKey('agent-exit-without-saving'),
                      onPressed: () => AppNavigation.closeDialog(result: true),
                      child: Text('仍然退出'.tr),
                    ),
                  ],
                ),
              ) ==
              true;
        }
      }
      if (allow) {
        try {
          await _sessions.closeAll();
        } on SystemProxyException catch (error) {
          allow = false;
          AppNotice.error(error.message);
        }
      }
      _allowExit = allow;
      _exitPending = null;
      return allow;
    })();
  }

  @override
  void onWindowEnterFullScreen() {
    if (_nativeTarget == true && !(_nativeTransition?.isCompleted ?? true)) {
      _nativeTransition!.complete();
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (_nativeTarget == false && !(_nativeTransition?.isCompleted ?? true)) {
      _nativeTransition!.complete();
    }
    if (mounted && _fullscreenId != null) setState(() => _fullscreenId = null);
  }

  @override
  void dispose() {
    if (_updates != null && identical(_updates!.exitForUpdate, _updateExit)) {
      _updates!.exitForUpdate = null;
    }
    _windowChannel.setMethodCallHandler(null);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleShortcut);
    _lifecycle.dispose();
    _monitoringVisible.dispose();
    _sessionChanges.dispose();
    _window.removeListener(this);
    if (!(_nativeTransition?.isCompleted ?? true)) {
      _nativeTransition!.complete();
    }
    super.dispose();
  }

  bool get _canRunWorkspaceCommand =>
      mounted &&
      _fullscreenId == null &&
      Get.isDialogOpen != true &&
      ModalRoute.of(context)?.isCurrent == true;

  void _openQuickConnect() {
    if (_canRunWorkspaceCommand) {
      unawaited(showCommandPalette(_sidebar.currentContext ?? context));
    }
  }

  void _newService() {
    if (_canRunWorkspaceCommand) unawaited(showHostEditDialog(context));
  }

  void _closeActiveTab() {
    final id = _sessions.activeSessionId.value;
    if (_canRunWorkspaceCommand && id != null) {
      unawaited(requestSessionTabClose(_sessions, [id]));
    }
  }

  void _openSettings() {
    if (_canRunWorkspaceCommand) unawaited(showSettingsDialog());
  }

  @override
  void onWindowBlur() => _shortcutKeys.clear();

  @override
  void onWindowMinimized() {
    _windowMinimized = true;
    _updateMonitoringVisibility();
  }

  @override
  void onWindowRestored() {
    _windowMinimized = false;
    _updateMonitoringVisibility();
  }

  void _updateMonitoringVisibility() {
    _monitoringVisible.value =
        !_windowMinimized &&
        _lifecycleState != AppLifecycleState.hidden &&
        _lifecycleState != AppLifecycleState.paused;
  }

  void _cycleTab(int step) {
    final tabs = _sessions.tabs;
    if (tabs.isEmpty) return;
    final current = tabs.indexWhere((tab) => tab.id == _sessions.activeTabId);
    final index = current < 0
        ? (step > 0 ? 0 : tabs.length - 1)
        : (current + step) % tabs.length;
    _sessions.activateTab(tabs[index].id);
  }

  void _selectTabAt(int index) {
    final tabs = _sessions.tabs;
    if (index < tabs.length) _sessions.activateTab(tabs[index].id);
  }

  Future<void> _focusSidebarSearch() async {
    final sidebarContext = _sidebar.currentContext;
    if (sidebarContext == null) return;
    final scope = AgentSidebarScope.maybeOf(sidebarContext);
    try {
      if (scope?.sidebarHiddenForSpace ?? false) {
        await scope!.showSidebar();
      } else {
        await Get.find<SettingsController>().setSidebarVisible(true);
      }
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_canRunWorkspaceCommand) _sidebar.currentState?.focusSearch();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } on Object {
      if (mounted) AppNotice.error('保存失败，请重试');
    }
  }

  KeyEventResult _handleShortcut(KeyEvent event) {
    // Consume the complete shortcut key sequence, including repeats and key-up,
    // so terminal/RDP input cannot intercept or forward it to the remote host.
    if (_fullscreenId != null) {
      _shortcutKeys.clear();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _shortcutKeys.remove(event.physicalKey);
    }
    if ((event is KeyRepeatEvent || event is KeyUpEvent) &&
        _shortcutKeys.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _shortcutKeys.remove(event.physicalKey);
      return KeyEventResult.handled;
    }
    if (!_canRunWorkspaceCommand || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    bool matches({
      bool control = false,
      bool meta = false,
      bool alt = false,
      bool shift = false,
    }) => SingleActivator(
      key,
      control: control,
      meta: meta,
      alt: alt,
      shift: shift,
      includeRepeats: false,
    ).accepts(event, keyboard);

    const numberKeys = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final number = isMac ? numberKeys.indexOf(key) : -1;
    if (key == LogicalKeyboardKey.tab &&
        matches(control: true, shift: keyboard.isShiftPressed)) {
      _shortcutKeys.add(event.physicalKey);
      _cycleTab(keyboard.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (number >= 0 && matches(meta: true)) {
      _shortcutKeys.add(event.physicalKey);
      _selectTabAt(number);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF &&
        matches(meta: isMac, shift: isMac, control: !isMac, alt: !isMac)) {
      _shortcutKeys.add(event.physicalKey);
      unawaited(_focusSidebarSearch());
      return KeyEventResult.handled;
    }
    final bindings = <LogicalKeyboardKey, ({VoidCallback run, bool shift})>{
      LogicalKeyboardKey.keyK: (run: _openQuickConnect, shift: !isMac),
      LogicalKeyboardKey.keyN: (run: _newService, shift: !isMac),
      LogicalKeyboardKey.comma: (run: _openSettings, shift: false),
    };
    final command = bindings[event.logicalKey];
    if (command != null &&
        SingleActivator(
          event.logicalKey,
          meta: isMac,
          control: !isMac,
          shift: command.shift,
          includeRepeats: false,
        ).accepts(event, HardwareKeyboard.instance)) {
      _shortcutKeys.add(event.physicalKey);
      command.run();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.enter,
          control: true,
          alt: true,
          includeRepeats: false,
        ): _toggleFullscreen,
        const SingleActivator(
          LogicalKeyboardKey.numpadEnter,
          control: true,
          alt: true,
          includeRepeats: false,
        ): _toggleFullscreen,
      },
      child: Focus(
        autofocus: true,
        child: RdpFullscreenScope(
          sessionId: _fullscreenId,
          busy: _fullscreenBusy,
          enter: _enterFullscreen,
          exit: _exitFullscreen,
          child: shadcn.Scaffold(
            child: AgentWorkspace(
              sidebar: _AnimatedSidebar(sidebarKey: _sidebar),
              child: WorkspaceVisibility(
                notifier: _monitoringVisible,
                child: const Workspace(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 保持树的挂载和原宽度，只动画可见区域，避免文本在收起过程中反复换行。
class _AnimatedSidebar extends StatelessWidget {
  const _AnimatedSidebar({required this.sidebarKey});
  final GlobalKey<SidebarStateView> sidebarKey;

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final hiddenForSpace =
        AgentSidebarScope.maybeOf(context)?.sidebarHiddenForSpace ?? false;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppTheme.sidebarTransitionDuration;
    return Obx(() {
      final visible = settings.sidebarVisible.value && !hiddenForSpace;
      return TweenAnimationBuilder<double>(
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
                key: const ValueKey('sidebar-viewport'),
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: value,
                  child: child,
                ),
              ),
            ),
          ),
        ),
        child: _SidebarPanel(sidebarKey: sidebarKey),
      );
    });
  }
}

class _SidebarPanel extends StatefulWidget {
  const _SidebarPanel({required this.sidebarKey});
  final GlobalKey<SidebarStateView> sidebarKey;

  @override
  State<_SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<_SidebarPanel> {
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final settings = Get.find<SettingsController>();
    return Obx(() {
      final width = (_dragWidth ?? settings.sidebarWidth.value).clamp(
        AppTheme.sidebarMinWidth,
        AppTheme.sidebarMaxWidth,
      );
      return SizedBox(
        width: width,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: AppTheme.sidebar(context),
              child: Column(
                children: [
                  SizedBox(
                    height: AppTheme.windowHeaderHeight,
                    child: Row(
                      children: [
                        if (isMac)
                          const SizedBox(
                            width: AppTheme.macWindowControlsWidth,
                          ),
                        const Expanded(child: WindowDragArea()),
                      ],
                    ),
                  ),
                  Expanded(child: Sidebar(key: widget.sidebarKey)),
                ],
              ),
            ),
            Positioned(
              top: AppTheme.windowHeaderHeight,
              right: 0,
              bottom: 0,
              width: AppTheme.sidebarResizeWidth,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: const ValueKey('sidebar-resize-handle'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    final next = (width + details.delta.dx).clamp(
                      AppTheme.sidebarMinWidth,
                      AppTheme.sidebarMaxWidth,
                    );
                    setState(() => _dragWidth = next);
                    settings.sidebarWidth.value = next;
                  },
                  onHorizontalDragEnd: (_) {
                    final saved = _dragWidth;
                    setState(() => _dragWidth = null);
                    if (saved != null) {
                      unawaited(
                        settings.setSidebarWidth(saved).catchError((Object _) {
                          if (context.mounted) {
                            AppNotice.error('保存失败，请重试'.tr);
                          }
                        }),
                      );
                    }
                  },
                  onHorizontalDragCancel: () => setState(() {
                    _dragWidth = null;
                    settings.sidebarWidth.value =
                        settings.sidebarState.value.width;
                  }),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
