import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';
import 'app_icon_button.dart';

List<shadcn.MenuItem> appMenuItems<T>(
  List<(T, String)> items,
  ValueChanged<T> onSelected, {
  T? selectedValue,
}) => [
  for (var index = 0; index < items.length; index++) ...[
    if (index > 0 && items[index].$1 == 'delete') const shadcn.MenuDivider(),
    _AppMenuItem(
      label: items[index].$2,
      icon: items[index].$1 == selectedValue
          ? shadcn.LucideIcons.check
          : _menuIcon(items[index].$1),
      destructive: items[index].$1 == 'delete',
      onPressed: () => onSelected(items[index].$1),
    ),
  ],
];

IconData? _menuIcon(Object? action) => switch (action) {
  'new-session' => shadcn.LucideIcons.terminal,
  'batch-command' => shadcn.LucideIcons.send,
  'open-transfer' => shadcn.LucideIcons.folderOpen,
  'new-host' => shadcn.LucideIcons.fileTerminal,
  'new-gateway' => shadcn.LucideIcons.network,
  'port-forward' ||
  'new-forward' ||
  'start' => shadcn.LucideIcons.arrowLeftRight,
  'stop' => shadcn.LucideIcons.square,
  'new-folder' || 'new-subfolder' => shadcn.LucideIcons.folderPlus,
  'new-identity' => shadcn.LucideIcons.fileKey,
  'edit' || 'rename' => shadcn.LucideIcons.pencil,
  'copy' => shadcn.LucideIcons.copy,
  'delete' => shadcn.LucideIcons.trash2,
  'download' => shadcn.LucideIcons.download,
  'upload' => shadcn.LucideIcons.upload,
  'open' => shadcn.LucideIcons.folderOpen,
  _ => null,
};

/// 保留 shadcn 的菜单键盘导航；样式只跟随当前项的悬停或焦点。
class _AppMenuItem extends StatelessWidget implements shadcn.MenuItem {
  const _AppMenuItem({
    required this.label,
    required this.icon,
    required this.destructive,
    required this.onPressed,
  });

  final String label;
  final IconData? icon;
  final bool destructive;
  final VoidCallback onPressed;

  @override
  bool get hasLeading => icon != null;

  @override
  shadcn.OverlayController? get overlayController => null;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final foreground = destructive
        ? AppTheme.menuDanger(context)
        : colors.foreground;
    return shadcn.WidgetStatesProvider.boundary(
      child: shadcn.ButtonStyleOverride(
        padding: (_, _, _) => AppTheme.menuItemPadding,
        margin: (_, _, _) => const EdgeInsets.symmetric(vertical: 1),
        textStyle: (_, _, style) => style.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: foreground,
        ),
        iconTheme: (_, _, style) => style.copyWith(size: 15, color: foreground),
        decoration: (context, states, _) {
          final focus = context
              .findAncestorStateOfType<State<shadcn.SubFocus>>();
          final active = focus is shadcn.SubFocusState
              ? (focus as shadcn.SubFocusState).isFocused
              : states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed);
          return BoxDecoration(
            color: active
                ? destructive
                      ? foreground.withValues(alpha: 0.12)
                      : colors.accent
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(AppTheme.menuItemRadius),
          );
        },
        child: shadcn.MenuButton(
          leading: icon == null ? null : Icon(icon),
          onPressed: (_) => onPressed(),
          child: Text(label),
        ),
      ),
    );
  }
}

class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    required this.items,
    required this.onSelected,
    this.actions = const [],
    this.semanticLabel = '',
    this.selectedValue,
    this.icon = const Icon(shadcn.LucideIcons.ellipsis, size: 16),
    super.key,
  });
  final List<(T, String)> items;
  final List<(T, String)> actions;
  final ValueChanged<T> onSelected;
  final T? selectedValue;
  final String semanticLabel;
  final Widget icon;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchorContext) => AppIconButton(
      icon: icon,
      semanticLabel: semanticLabel,
      onPressed: () => shadcn.showDropdown<void>(
        context: anchorContext,
        builder: (_) => shadcn.DropdownMenu(
          children: [
            ...appMenuItems(items, onSelected, selectedValue: selectedValue),
            if (actions.isNotEmpty) ...[
              const shadcn.MenuDivider(),
              ...appMenuItems(actions, onSelected),
            ],
          ],
        ),
      ),
    ),
  );
}
