import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

enum _AppIconButtonVariant { ghost, iconGhost, text }

/// 图标操作提供无障碍名称，可按需加入 shadcn 标准鼠标悬浮提示。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    required this.icon,
    this.semanticLabel = '',
    this.onPressed,
    this.tooltip,
    this.density = shadcn.ButtonDensity.icon,
    super.key,
  }) : _variant = _AppIconButtonVariant.ghost;

  const AppIconButton.ghost({
    required this.icon,
    this.semanticLabel = '',
    this.onPressed,
    this.tooltip,
    this.density = shadcn.ButtonDensity.icon,
    super.key,
  }) : _variant = _AppIconButtonVariant.iconGhost;

  const AppIconButton.text({
    required this.icon,
    this.semanticLabel = '',
    this.onPressed,
    this.density = shadcn.ButtonDensity.icon,
    super.key,
  }) : tooltip = null,
       _variant = _AppIconButtonVariant.text;

  final Widget icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final String? tooltip;
  final shadcn.ButtonDensity density;
  final _AppIconButtonVariant _variant;

  @override
  Widget build(BuildContext context) {
    final button = Semantics(
      label: semanticLabel.isEmpty ? null : semanticLabel,
      button: true,
      enabled: onPressed != null,
      child: switch (_variant) {
        _AppIconButtonVariant.ghost => shadcn.GhostButton(
          onPressed: onPressed,
          size: shadcn.ButtonSize.small,
          density: density,
          child: icon,
        ),
        _AppIconButtonVariant.iconGhost => shadcn.IconButton.ghost(
          onPressed: onPressed,
          size: shadcn.ButtonSize.small,
          density: density,
          icon: icon,
        ),
        _AppIconButtonVariant.text => shadcn.IconButton.text(
          onPressed: onPressed,
          size: shadcn.ButtonSize.small,
          density: density,
          icon: icon,
        ),
      },
    );
    return tooltip == null
        ? button
        : shadcn.Tooltip(
            tooltip: (_) => shadcn.TooltipContainer(child: Text(tooltip!)),
            child: button,
          );
  }
}
