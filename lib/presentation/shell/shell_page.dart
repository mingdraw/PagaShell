import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../application/mcp/mcp_server_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../../application/tray/system_tray_controller.dart';
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

enum _ExitCleanup { agent, mcp, tray }

typedef _ExitIssue = ({String? reason, String consequence});

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
  static const _exitCleanupTimeout = Duration(seconds: 5);

  String? _fullscreenId;
  bool _fullscreenBusy = false;
  Completer<void>? _nativeTransition;
  bool? _nativeTarget;
  late final Worker _sessionChanges;
  late final AppLifecycleListener _lifecycle;
  final _monitoringVisible = ValueNotifier(true);
  bool _windowMinimized = false;
  bool _hiddenInTray = false;
  bool _hidingToTray = false;
  AppLifecycleState? _lifecycleState;
  final _exitCleanups = <_ExitCleanup, Future<void>>{};
  bool _allowExit = false;
  bool _destroying = false;
  bool _trayDisposing = false;
  SystemTrayController? _tray;
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
          if (_hiddenInTray) await _showFromTray();
          _openSettings();
        case 'showQuickConnect':
          if (_hiddenInTray) await _showFromTray();
          _openQuickConnect();
        case 'newService':
          if (_hiddenInTray) await _showFromTray();
          _newService();
        case 'closeActiveTab':
          _closeActiveTab();
        case 'windowReopened':
          _onWindowReopenedFromNative();
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
      onExitRequested: () async {
        if (_allowExit || await _exitApplication(fromSystem: true)) {
          return AppExitResponse.exit;
        }
        return AppExitResponse.cancel;
      },
    );
    _sessionChanges = everAll([_sessions.sessions, _sessions.activeSessionId], (
      _,
    ) {
      final id = _fullscreenId;
      if (id != null && !_isDesktopReady(id)) unawaited(_exitFullscreen());
    });
    if (Get.isRegistered<SystemTrayController>()) {
      final tray = _tray = Get.find<SystemTrayController>();
      tray.onShowWindow = _showFromTray;
      tray.onHideWindow = _hideToTray;
      tray.onOpenQuickConnect = _openQuickConnectFromTray;
      tray.onOpenSettings = _openSettingsFromTray;
      tray.onFocusSession = _focusSessionFromTray;
      tray.onQuitRequested = _exitApplication;
      tray.onNoticeSuccess = AppNotice.success;
      tray.onNoticeError = AppNotice.error;
      tray.setWindowHiddenInTray(false);
    }
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
        (_hiddenInTray || Get.isDialogOpen == true || _fullscreenId != null)) {
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
    if (_destroying) return;
    if (_shouldMinimizeToTrayOnClose()) {
      unawaited(_hideToTray());
    } else {
      unawaited(_exitApplication());
    }
  }

  bool _shouldMinimizeToTrayOnClose() =>
      !_trayDisposing &&
      Get.isRegistered<SettingsController>() &&
      Get.find<SettingsController>().minimizeToTrayOnClose.value;

  Future<void> _hideToTray() async {
    if (_destroying || _trayDisposing || _hiddenInTray || _hidingToTray) return;
    _hidingToTray = true;
    try {
      if (_fullscreenId != null) {
        await _exitFullscreen();
      } else if (await _window.isFullScreen()) {
        await _setNativeFullscreen(false);
      }
      if (!mounted || _destroying) return;
      _shortcutKeys.clear();
      _hiddenInTray = true;
      _updateMonitoringVisibility();
      _tray?.setWindowHiddenInTray(true);
      await _window.hide();
    } on Object {
      if (mounted && !_destroying) {
        _hiddenInTray = false;
        _updateMonitoringVisibility();
        _tray?.setWindowHiddenInTray(false);
      }
    } finally {
      _hidingToTray = false;
    }
  }

  Future<void> _showFromTray() async {
    if (_destroying) return;
    _hiddenInTray = false;
    _windowMinimized = false;
    _updateMonitoringVisibility();
    _tray?.setWindowHiddenInTray(false);
    await _window.show();
  }

  void _onWindowReopenedFromNative() {
    if (_destroying) return;
    _hiddenInTray = false;
    _windowMinimized = false;
    _updateMonitoringVisibility();
    _tray?.setWindowHiddenInTray(false);
  }

  Future<void> _focusSessionFromTray(String sessionId) async {
    await _showFromTray();
    if (!mounted || _destroying) return;
    if (_fullscreenId != null && _fullscreenId != sessionId) {
      await _exitFullscreen();
    }
    if (!mounted || _destroying) return;
    _sessions.activate(sessionId);
  }

  Future<void> _openQuickConnectFromTray() async {
    await _showFromTray();
    if (!mounted || _destroying) return;
    _openQuickConnect();
  }

  Future<void> _openSettingsFromTray({bool ai = false}) async {
    await _showFromTray();
    if (!mounted || _destroying) return;
    if (_canRunWorkspaceCommand) {
      unawaited(showSettingsDialog(ai: ai));
    }
  }

  Future<bool> _exitApplication({
    Future<void> Function()? beforeDestroy,
    bool fromSystem = false,
  }) async {
    if (_destroying) return false;
    _destroying = true;
    try {
      if (!await _prepareExit()) return false;
      await beforeDestroy?.call();
      _allowExit = true;
      if (fromSystem) return true;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        // window_manager.destroy() posts WM_QUIT on Windows. The runner must
        // destroy the view/plugins before its message loop and COM shut down.
        await _windowChannel.invokeMethod<void>('destroy');
      } else {
        await _window.destroy();
      }
      return true;
    } on Object {
      _allowExit = false;
      rethrow;
    } finally {
      if (!_allowExit) _destroying = false;
    }
  }

  Future<bool> _prepareExit() async {
    if (Get.isRegistered<AgentController>() &&
        !Get.isPrepared<AgentController>()) {
      final agent = Get.find<AgentController>();
      final failure = await _runExitCleanup(_ExitCleanup.agent, () async {
        if (!await agent.prepareForExit()) {
          throw StateError('Agent save failed');
        }
      });
      if (failure != null &&
          !await _confirmExit([
            (
              reason: null,
              consequence: failure is TimeoutException
                  ? '等待保存 Agent 数据超时。继续退出可能丢失尚未保存的记录和偏好设置。'.tr
                  : '本地保存失败，可取消退出后重试。仍然退出将丢失尚未保存的记录和偏好设置。'.tr,
            ),
          ], agentSave: true)) {
        return false;
      }
    }

    if (Get.isRegistered<McpServerController>()) {
      final failure = await _runExitCleanup(
        _ExitCleanup.mcp,
        Get.find<McpServerController>().stopForExit,
      );
      if (failure != null &&
          !await _confirmExit([
            _cleanupIssue('停止本地 MCP 服务', '正在通过 MCP 执行的请求可能被中断。', failure),
          ])) {
        return false;
      }
    }

    // Take a fresh snapshot after a canceled exit; individual session closes
    // are shared by the controller if their earlier cleanup is still running.
    final failure = await _waitForExitCleanup(
      Future<void>.sync(_sessions.closeForExit),
    );
    if (failure != null && !await _confirmExit(_sessionExitIssues(failure))) {
      return false;
    }

    if (_tray case final tray?) {
      _trayDisposing = true;
      final failure = await _runExitCleanup(
        _ExitCleanup.tray,
        tray.disposeTray,
      );
      if (failure != null &&
          !await _confirmExit([
            _cleanupIssue('清理系统托盘', '系统托盘可能暂时保留一个无效的 PagaShell 图标。', failure),
          ])) {
        return false;
      }
    }
    return true;
  }

  Future<Object?> _runExitCleanup(
    _ExitCleanup step,
    Future<void> Function() cleanup,
  ) => _waitForExitCleanup(
    _exitCleanups[step] ??= Future<void>.sync(cleanup).whenComplete(() {
      _exitCleanups.remove(step);
    }),
  );

  Future<Object?> _waitForExitCleanup(Future<void> cleanup) async {
    try {
      await cleanup.timeout(_exitCleanupTimeout);
      return null;
    } on Object catch (failure) {
      return failure;
    }
  }

  String _cleanupReason(String step, Object failure) =>
      (failure is TimeoutException ? '@step：等待超时' : '@step：失败').trParams({
        'step': step.tr,
      });

  _ExitIssue _cleanupIssue(String step, String consequence, Object failure) =>
      (reason: _cleanupReason(step, failure), consequence: consequence.tr);

  List<_ExitIssue> _sessionExitIssues(Object failure) {
    final steps = _sessions.pendingCloseSteps;
    final proxyError = failure is SystemProxyException
        ? failure.message
        : _sessions.systemProxyRestoreError;
    if (proxyError != null) steps.add(SessionCloseStep.systemProxy);
    if (steps.isEmpty) steps.add(SessionCloseStep.connection);
    return [
      for (final step in SessionCloseStep.values.where(steps.contains))
        switch (step) {
          SessionCloseStep.systemProxy => (
            reason: proxyError?.tr ?? _cleanupReason('恢复系统代理', failure),
            consequence:
                '系统代理可能仍指向已停止的 PagaShell，导致浏览器等应用无法联网。可在系统设置中移除 PagaShell 的代理。'
                    .tr,
          ),
          SessionCloseStep.dynamicProxy => _cleanupIssue(
            '停止动态代理',
            '仍在使用动态代理的连接会中断。',
            failure,
          ),
          SessionCloseStep.portForward => _cleanupIssue(
            '停止端口转发',
            '通过端口转发的连接会中断。',
            failure,
          ),
          SessionCloseStep.fileTransfer => _cleanupIssue(
            '停止文件传输',
            '传输会中断，目标端可能留下未传完的文件。',
            failure,
          ),
          SessionCloseStep.connection => _cleanupIssue(
            '关闭会话',
            '远程会话会中断，未完成的任务或传输可能受影响。',
            failure,
          ),
        },
    ];
  }

  Future<bool> _confirmExit(
    List<_ExitIssue> issues, {
    bool agentSave = false,
  }) async {
    if (!mounted) return false;
    if (_hiddenInTray || _windowMinimized) await _revealForExitPrompt();
    if (!mounted) return false;
    return await AppNavigation.dialog<bool>(
          AppDialog(
            title: Text((agentSave ? 'Agent 数据尚未保存' : '退出前有步骤未完成').tr),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                for (final issue in issues) ...[
                  if (issue.reason case final reason?) Text(reason),
                  Text(issue.consequence),
                ],
              ],
            ),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: ValueKey(
                  agentSave
                      ? 'agent-exit-without-saving'
                      : 'exit-with-incomplete-cleanup',
                ),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('仍然退出'.tr),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _revealForExitPrompt() async {
    _hiddenInTray = false;
    _windowMinimized = false;
    _updateMonitoringVisibility();
    _tray?.setWindowHiddenInTray(false);
    await _window.show();
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
    if (_tray case final tray?) {
      if (tray.onShowWindow == _showFromTray) tray.onShowWindow = null;
      if (tray.onHideWindow == _hideToTray) tray.onHideWindow = null;
      if (tray.onOpenQuickConnect == _openQuickConnectFromTray) {
        tray.onOpenQuickConnect = null;
      }
      if (tray.onOpenSettings == _openSettingsFromTray) {
        tray.onOpenSettings = null;
      }
      if (tray.onFocusSession == _focusSessionFromTray) {
        tray.onFocusSession = null;
      }
      if (tray.onQuitRequested == _exitApplication) tray.onQuitRequested = null;
      if (tray.onNoticeSuccess == AppNotice.success) {
        tray.onNoticeSuccess = null;
      }
      if (tray.onNoticeError == AppNotice.error) tray.onNoticeError = null;
    }
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
    if (_hiddenInTray) {
      _hiddenInTray = false;
      _tray?.setWindowHiddenInTray(false);
    }
    _updateMonitoringVisibility();
  }

  void _updateMonitoringVisibility() {
    _monitoringVisible.value =
        !_hiddenInTray &&
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
