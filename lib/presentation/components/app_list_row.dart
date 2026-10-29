import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

/// shadcn 的可点击行，支持键盘焦点、悬停和嵌套操作按钮。
class AppSurfaceAction extends StatelessWidget {
  const AppSurfaceAction({
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.hoverColor,
    this.selectedColor,
    this.selected = false,
    this.borderRadius,
    this.disableTransition = false,
    super.key,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Color? hoverColor;
  final Color? selectedColor;
  final bool selected;
  final BorderRadius? borderRadius;
  final bool disableTransition;

  @override
  Widget build(BuildContext context) => shadcn.Clickable(
    disableTransition: disableTransition,
    onPressed: onTap,
    onDoubleTap: onDoubleTap,
    decoration: WidgetStateProperty.resolveWith(
      (states) => BoxDecoration(
        borderRadius: borderRadius,
        color: selected
            ? selectedColor ??
                  hoverColor ??
                  shadcn.Theme.of(context).colorScheme.accent
            : states.contains(WidgetState.hovered)
            ? hoverColor ?? shadcn.Theme.of(context).colorScheme.accent
            : const Color(0x00000000),
      ),
    ),
    child: child,
  );
}

class AppListRow extends StatelessWidget {
  const AppListRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.borderRadius,
    this.minHeight = 0,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 6,
    ),
    super.key,
  });
  final Widget title;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final BorderRadius? borderRadius;
  final double minHeight;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) => AppSurfaceAction(
    onTap: onTap,
    selected: selected,
    borderRadius: borderRadius,
    child: Padding(
      padding: contentPadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, ?subtitle],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    ),
  );
}
