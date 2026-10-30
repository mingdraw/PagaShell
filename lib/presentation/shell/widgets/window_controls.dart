import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

import '../../../application/settings/settings_controller.dart';
import '../../components/app_icon_button.dart';
import '../../components/app_list_row.dart';
import '../../navigation/app_notice.dart';
import '../../theme/app_theme.dart';
import '../agent_sidebar_scope.dart';

class SidebarToggleButton extends StatelessWidget {
  const SidebarToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final agentSidebar = AgentSidebarScope.maybeOf(context);
    return Obx(() {
      final visible =
          settings.sidebarState.value.visible &&
          !(agentSidebar?.sidebarHiddenForSpace ?? false);
      return AppIconButton(
        key: const ValueKey('sidebar-toggle'),
        semanticLabel: (visible ? '隐藏侧边栏' : '显示侧边栏').tr,
        tooltip: (visible ? '隐藏侧边栏' : '显示侧边栏').tr,
        icon: Icon(
          visible
              ? shadcn.LucideIcons.panelLeftClose
              : shadcn.LucideIcons.panelLeftOpen,
          size: 16,
        ),
        onPressed: () async {
          try {
            if (agentSidebar?.sidebarHiddenForSpace ?? false) {
              await agentSidebar!.showSidebar();
            } else {
              await settings.setSidebarVisible(!visible);
            }
          } on Object {
            AppNotice.error('保存失败，请重试'.tr);
          }
        },
      );
    });
  }
}

/// 顶部图标使用统一的点击尺寸，与平台窗口按钮垂直对齐。
class WindowHeaderButton extends StatelessWidget {
  const WindowHeaderButton({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = AppTheme.windowHeaderControlSize(context);
    return SizedBox.square(
      dimension: size,
      child: WindowDragBlocker(child: child),
    );
  }
}

/// 只覆盖空白区域，避免窗口拖拽抢占标签、关闭按钮或侧栏开关的手势。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key});

  @override
  Widget build(BuildContext context) {
    if (shadcn.Theme.of(context).platform != TargetPlatform.macOS) {
      return const DragToMoveArea(child: SizedBox.expand());
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(_startWindowDrag(context)),
      onDoubleTap: _toggleWindowMaximize,
      child: const SizedBox.expand(),
    );
  }
}

/// Tab Pane 的空白区域支持拖窗与 macOS 双击缩放，交互控件在手势竞争前被排除。
class WindowDragRegion extends StatelessWidget {
  const WindowDragRegion({
    required this.height,
    required this.child,
    super.key,
  });

  final double height;
  final Widget child;

  bool _acceptsPointer(BuildContext context, PointerDownEvent event) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return false;
    final local = box.globalToLocal(event.position);
    if (local.dy < 0 || local.dy >= height) return false;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    return !result.path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          (entry.target as RenderMetaData).metaData ==
              _WindowDragHitTest.blocked,
    );
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    gestures: {
      _WindowPanGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<_WindowPanGestureRecognizer>(
            () => _WindowPanGestureRecognizer(debugOwner: this),
            (recognizer) {
              recognizer.acceptsPointer = (event) =>
                  _acceptsPointer(context, event);
              recognizer.onStart = (_) => unawaited(_startWindowDrag(context));
            },
          ),
      if (shadcn.Theme.of(context).platform == TargetPlatform.macOS)
        _WindowDoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _WindowDoubleTapGestureRecognizer
            >(() => _WindowDoubleTapGestureRecognizer(debugOwner: this), (
              recognizer,
            ) {
              recognizer.acceptsPointer = (event) =>
                  _acceptsPointer(context, event);
              recognizer.onDoubleTap = _toggleWindowMaximize;
            }),
    },
    child: child,
  );
}

enum _WindowDragHitTest { blocked }

class WindowDragBlocker extends StatelessWidget {
  const WindowDragBlocker({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: _WindowDragHitTest.blocked,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

class _WindowPanGestureRecognizer extends PanGestureRecognizer {
  _WindowPanGestureRecognizer({super.debugOwner});

  late bool Function(PointerDownEvent) acceptsPointer;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      acceptsPointer(event) &&
      super.isPointerAllowed(event);
}

class _WindowDoubleTapGestureRecognizer extends DoubleTapGestureRecognizer {
  _WindowDoubleTapGestureRecognizer({super.debugOwner});

  late bool Function(PointerDownEvent) acceptsPointer;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent &&
      acceptsPointer(event) &&
      super.isPointerAllowed(event);
}

Future<void> _startWindowDrag(BuildContext context) async {
  if (shadcn.Theme.of(context).platform == TargetPlatform.macOS) {
    await const MethodChannel('pagashell/window')
        .invokeMethod<void>('startWindowDrag');
  } else {
    await windowManager.startDragging();
  }
}

Future<void> _toggleWindowMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _CaptionButton(
        icon: shadcn.LucideIcons.minus,
        semanticLabel: '最小化'.tr,
        onPressed: windowManager.minimize,
      ),
      _CaptionButton(
        icon: shadcn.LucideIcons.square,
        semanticLabel: '最大化 / 还原'.tr,
        onPressed: () async {
          if (await windowManager.isMaximized()) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
        },
      ),
      _CaptionButton(
        icon: shadcn.LucideIcons.x,
        semanticLabel: '关闭'.tr,
        hoverColor: const Color(0xFFE81123),
        onPressed: windowManager.close,
      ),
    ],
  );
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.hoverColor,
  });

  final IconData icon;
  final String semanticLabel;
  final Future<void> Function() onPressed;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    button: true,
    child: AppSurfaceAction(
      hoverColor: hoverColor,
      onTap: onPressed,
      child: SizedBox(
        width: AppTheme.windowButtonWidth,
        height: double.infinity,
        child: Icon(icon, size: 15),
      ),
    ),
  );
}
