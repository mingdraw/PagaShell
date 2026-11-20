import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../theme/app_theme.dart';

class RdpFullscreenToolbar extends StatefulWidget {
  const RdpFullscreenToolbar({
    required this.controls,
    required this.holdOpen,
    required this.onRefocus,
    super.key,
  });

  final List<Widget> controls;
  final bool holdOpen;
  final VoidCallback onRefocus;

  @override
  State<RdpFullscreenToolbar> createState() => _RdpFullscreenToolbarState();
}

class _RdpFullscreenToolbarState extends State<RdpFullscreenToolbar> {
  Timer? _hideTimer;
  bool _visible = true;
  bool _hovered = false;
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(RdpFullscreenToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.holdOpen != oldWidget.holdOpen) {
      if (widget.holdOpen) _visible = true;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_visible || _hovered || _pinned || widget.holdOpen) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) {
      _hovered = true;
      if (!_visible) setState(() => _visible = true);
      _scheduleHide();
    },
    onExit: (_) {
      _hovered = false;
      _scheduleHide();
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      child: !_visible
          ? Semantics(
              label: '显示全屏工具栏'.tr,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _visible = true);
                  _scheduleHide();
                },
                child: SizedBox(
                  key: const ValueKey('rdp-fullscreen-reveal'),
                  width: 140,
                  height: 16,
                  child: Center(
                    child: Container(
                      width: 100,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.surface(context).withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : Container(
              key: const ValueKey('rdp-fullscreen-toolbar'),
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
              decoration: BoxDecoration(
                color: AppTheme.surface(context).withValues(alpha: 0.97),
                border: Border.all(color: AppTheme.border(context)),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                boxShadow: const [
                  BoxShadow(color: Color(0x40000000), blurRadius: 12),
                ],
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  AppIconButton(
                    key: const ValueKey('rdp-fullscreen-pin'),
                    semanticLabel: (_pinned ? '取消固定工具栏' : '固定工具栏').tr,
                    tooltip: (_pinned ? '取消固定工具栏' : '固定工具栏').tr,
                    icon: AppIcon(
                      _pinned ? AppIcons.pinOff : AppIcons.pin,
                      size: 15,
                    ),
                    onPressed: () {
                      setState(() => _pinned = !_pinned);
                      _scheduleHide();
                      widget.onRefocus();
                    },
                  ),
                  ...widget.controls,
                ],
              ),
            ),
    ),
  );
}
