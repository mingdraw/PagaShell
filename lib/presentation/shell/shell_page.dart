import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

import '../../application/ai/agent_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../ai/agent_workspace.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../configuration/configuration_transfer_dialog.dart';
import '../hosts/host_edit_dialog.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../rdp/rdp_fullscreen_scope.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'agent_sidebar_scope.dart';
import 'command_palette.dart';
import 'widgets/settings_menu_button.dart';
import 'widgets/sidebar.dart';
import 'widgets/window_controls.dart';
import 'widgets/workspace.dart';

/// 应用主框架：左侧服务栏、中间会话工作区和独立 Agent 右栏。
///
/// 全局快捷键：
/// - ⌘/Ctrl+K 命令面板（快速连接）
/// - ⌘/Ctrl+N 新建服务
/// - ⌘/Ctrl+, 打开设置
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with WindowListener {
  static const _windowChannel = MethodChannel('pagashell/window');

  String? _fullscreenId;
  bool _fullscreenBusy = false;
  Completer<void>? _nativeTransition;
  bool? _nativeTarget;
  late final Worker _sessionChanges;
  late final AppLifecycleListener _lifecycle;
  Future<bool>? _exitPending;
  bool _allowExit = false;
  bool _destroying = false;
  final _shortcutKeys = <PhysicalKeyboardKey>{};
  SessionController get _sessions => Get.find<SessionController>();

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
    windowManager.addListener(this);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async =>
          await _prepareExit() ? AppExitResponse.exit : AppExitResponse.cancel,
    );
    _sessionChanges = everAll([_sessions.sessions, _sessions.activeSessionId], (
      _,
    ) {
      final id = _fullscreenId;
      if (id != null && !_isDesktopReady(id)) unawaited(_exitFullscreen());
    });
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
      await windowManager.setFullScreen(fullscreen);
      if (!mounted) return;
      await transition.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () async {
          if (await windowManager.isFullScreen() != fullscreen) {
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
  void onWindowClose() async {
    if (_destroying || !await _prepareExit()) return;
    _destroying = true;
    await windowManager.destroy();
  }

  Future<bool> _prepareExit() {
    if (_allowExit) return Future.value(true);
    return _exitPending ??= (() async {
      var allow = true;
      if (Get.isRegistered<AgentController>()) {
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
    _windowChannel.setMethodCallHandler(null);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleShortcut);
    _lifecycle.dispose();
    _sessionChanges.dispose();
    windowManager.removeListener(this);
    if (!(_nativeTransition?.isCompleted ?? true)) {
      _nativeTransition!.complete();
    }
    super.dispose();
  }

  bool get _canRunWorkspaceCommand =>
      mounted &&
      Get.isDialogOpen != true &&
      ModalRoute.of(context)?.isCurrent == true;

  void _openQuickConnect() {
    if (_canRunWorkspaceCommand) unawaited(showCommandPalette(context));
  }

  void _newService() {
    if (_canRunWorkspaceCommand) unawaited(showHostEditDialog(context));
  }

  void _closeActiveTab() {
    if (_canRunWorkspaceCommand) unawaited(_sessions.closeActive());
  }

  void _openSettings() {
    if (_canRunWorkspaceCommand) unawaited(showSettingsDialog());
  }

  KeyEventResult _handleShortcut(KeyEvent event) {
    // Consume the complete shortcut key sequence, including repeats and key-up,
    // so terminal/RDP input cannot intercept or forward it to the remote host.
    if (_shortcutKeys.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _shortcutKeys.remove(event.physicalKey);
      return KeyEventResult.handled;
    }
    if (!_canRunWorkspaceCommand || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final bindings = <LogicalKeyboardKey, VoidCallback>{
      LogicalKeyboardKey.keyK: _openQuickConnect,
      LogicalKeyboardKey.keyN: _newService,
      LogicalKeyboardKey.comma: _openSettings,
    };
    final command = bindings[event.logicalKey];
    if (command == null ||
        !SingleActivator(
          event.logicalKey,
          meta: isMac,
          control: !isMac,
          includeRepeats: false,
        ).accepts(event, HardwareKeyboard.instance)) {
      return KeyEventResult.ignored;
    }
    _shortcutKeys.add(event.physicalKey);
    command();
    return KeyEventResult.handled;
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
      },
      child: Focus(
        autofocus: true,
        child: RdpFullscreenScope(
          sessionId: _fullscreenId,
          busy: _fullscreenBusy,
          enter: _enterFullscreen,
          exit: _exitFullscreen,
          child: shadcn.Scaffold(
            child: Stack(
              children: [
                const AgentWorkspace(
                  sidebar: _AnimatedSidebar(),
                  child: Workspace(),
                ),
                if (_fullscreenId != null)
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _fullscreenToolbar(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fullscreenToolbar(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 440),
    child: Container(
      key: const ValueKey('rdp-fullscreen-toolbar'),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppTheme.surface(context).withValues(alpha: 0.96),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 6),
          const Icon(shadcn.LucideIcons.monitor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sessions.sessions
                      .firstWhereOrNull((s) => s.id == _fullscreenId)
                      ?.title ??
                  '远程桌面'.tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          shadcn.OutlineButton(
            key: const ValueKey('rdp-exit-fullscreen'),
            onPressed: _fullscreenBusy
                ? null
                : () => unawaited(_exitFullscreen()),
            leading: const Icon(shadcn.LucideIcons.minimize, size: 16),
            child: Text('退出全屏'.tr),
          ),
        ],
      ),
    ),
  );
}

/// 保持树的挂载和原宽度，只动画可见区域，避免文本在收起过程中反复换行。
class _AnimatedSidebar extends StatelessWidget {
  const _AnimatedSidebar();

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final hiddenForSpace =
        AgentSidebarScope.maybeOf(context)?.sidebarHiddenForSpace ?? false;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppTheme.sidebarTransitionDuration;
    return Obx(() {
      final visible = settings.sidebarState.value.visible && !hiddenForSpace;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: visible ? 1 : 0, end: visible ? 1 : 0),
        duration: duration,
        curve: Curves.easeInOutCubic,
        builder: (context, value, child) => IgnorePointer(
          ignoring: !visible,
          child: ExcludeSemantics(
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
        child: const _SidebarPanel(),
      );
    });
  }
}

class _SidebarPanel extends StatelessWidget {
  const _SidebarPanel();

  @override
  Widget build(BuildContext context) {
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final settings = Get.find<SettingsController>();
    final hiddenForSpace =
        AgentSidebarScope.maybeOf(context)?.sidebarHiddenForSpace ?? false;
    return SizedBox(
      width: AppTheme.sidebarWidth,
      child: ColoredBox(
        color: AppTheme.sidebar(context),
        child: Column(
          children: [
            SizedBox(
              height: AppTheme.windowHeaderHeight,
              child: Row(
                children: [
                  if (isMac)
                    const SizedBox(width: AppTheme.macWindowControlsWidth),
                  const Expanded(child: WindowDragArea()),
                  Obx(
                    () => Offstage(
                      offstage:
                          !settings.sidebarState.value.visible ||
                          hiddenForSpace,
                      child: const WindowHeaderButton(
                        child: SidebarToggleButton(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            const Expanded(child: Sidebar()),
            SizedBox(
              height: AppTheme.sidebarFooterHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Obx(
                    () => Offstage(
                      offstage:
                          !settings.sidebarState.value.visible ||
                          hiddenForSpace,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SettingsMenuButton(),
                          const SizedBox(width: 12),
                          AppIconButton.ghost(
                            key: const ValueKey('import-configuration'),
                            semanticLabel: '导入配置'.tr,
                            tooltip: '导入配置'.tr,
                            icon: const Icon(
                              shadcn.LucideIcons.download,
                              size: AppTheme.statusBarIconSize,
                            ),
                            density: shadcn.ButtonDensity.compact,
                            onPressed: () =>
                                unawaited(showConfigurationImportDialog()),
                          ),
                          const SizedBox(width: 12),
                          AppIconButton.ghost(
                            key: const ValueKey('export-configuration'),
                            semanticLabel: '导出配置'.tr,
                            tooltip: '导出配置'.tr,
                            icon: const Icon(
                              shadcn.LucideIcons.upload,
                              size: AppTheme.statusBarIconSize,
                            ),
                            density: shadcn.ButtonDensity.compact,
                            onPressed: () =>
                                unawaited(showConfigurationExportDialog()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
