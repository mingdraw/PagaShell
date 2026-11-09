import 'package:flutter/widgets.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'app_icons.dart';

export 'app_icons.dart';

/// Iconify 图标沿用 shadcn 控件提供的尺寸、前景色和禁用透明度。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final AppIcons icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final dimension = size ?? theme.size ?? 24;
    final foreground =
        color ?? theme.color ?? shadcn.Theme.of(context).colorScheme.foreground;
    final opacity = theme.opacity ?? 1;
    final effectiveColor = opacity == 1
        ? foreground
        : foreground.withValues(alpha: foreground.a * opacity);
    final image = ExcludeSemantics(
      child: SizedBox.square(
        dimension: dimension,
        child: Center(
          child: Iconify(icon.svg, size: dimension, color: effectiveColor),
        ),
      ),
    );
    return semanticLabel == null
        ? image
        : Semantics(label: semanticLabel, image: true, child: image);
  }
}
