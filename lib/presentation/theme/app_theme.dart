import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

/// 应用外壳使用 shadcn Zinc 主题；终端配色独立。
abstract final class AppTheme {
  static const Color terminalBackground = Color(0xFF09090B);

  static Color background(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.background;

  static Color surface(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFF18181B)
      : const Color(0xFFF4F4F5);

  static Color sidebar(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFF111113)
      : const Color(0xFFFAFAFA);

  static Color border(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.border;

  static Color fileSelectionBackground(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFF1E3A5F)
      : const Color(0xFFDBEAFE);

  static Color fileSelectionForeground(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFFEFF6FF)
      : const Color(0xFF1E3A8A);

  static Color menuDanger(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFFF87171)
      : const Color(0xFFB91C1C);

  static Color agentMentionForeground(BuildContext context) =>
      shadcn.Theme.of(context).colorScheme.brightness == Brightness.dark
      ? const Color(0xFF93C5FD)
      : const Color(0xFF1D4ED8);

  static const double sessionPaneTopMargin = 4;
  static const double sessionTabMinWidth = 150;
  static const Duration sessionTabScrollDuration = Duration(milliseconds: 180);
  static const double macSessionPaneRadius = 16;

  static BorderRadius sessionPaneRadius(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    // 内容四角统一；macOS 使用贴近窗口轮廓的尺寸，其余平台沿用主题。
    return theme.platform == TargetPlatform.macOS
        ? BorderRadius.circular(macSessionPaneRadius)
        : theme.borderRadiusLg;
  }

  // 原生按钮中心与顶部留白之后的默认 32px 标签栏中心对齐。
  static double windowHeaderControlSize(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    return theme.density.baseContainerPadding * theme.scaling * 2;
  }

  static const double windowHeaderHeight = 32 + sessionPaneTopMargin * 2;
  static const double macWindowControlsWidth = 76;
  static const double windowButtonWidth = 44;
  static const double windowDragWidth = 64;
  static const double statusBarHeight = 28;
  static const double statusBarIconSize = 14;
  static const double terminalSelectionEdgeExtent = 24;
  static const Duration terminalSelectionScrollInterval = Duration(
    milliseconds: 40,
  );
  static const double serverStatusCoreLabelWidth = 48;
  static const double serverStatusCoreValueWidth = 44;
  static const double fileSizeColumnWidth = 64;
  static const double fileModifiedColumnWidth = 140;
  static const double sidebarWidth = 264;
  static const double sidebarFooterHeight = 40;
  static const double settingsDialogMaxWidth = 600;
  static const double agentMinWidth = 300;
  static const double agentMaxWidth = 640;
  static const double agentMinWorkspaceWidth = 540;
  static const double agentResizeWidth = 5;
  static const Duration sidebarTransitionDuration = Duration(milliseconds: 220);
  static const double sidebarItemHeight = 34;
  static const double sidebarIconSize = 16;
  static const double sidebarSearchFontSize = 12;
  static const double sidebarSearchIconSize = 13;
  static const BorderRadius sidebarSearchRadius = BorderRadius.all(
    Radius.circular(20),
  );
  static const EdgeInsets sidebarSearchPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 5,
  );
  static const double dialogMaxWidth = 480;
  static const double configurationDialogMaxWidth = 480;
  static const double dialogFocusInset = 6;
  static const double dialogScrollbarGutter = 12;

  static EdgeInsetsDirectional dialogScrollPadding(BuildContext context) =>
      EdgeInsetsDirectional.fromSTEB(
        dialogFocusInset,
        dialogFocusInset,
        dialogFocusInset +
            dialogScrollbarGutter * shadcn.Theme.of(context).scaling,
        dialogFocusInset,
      );

  static const double batchCommandDialogMaxWidth = 760;
  static const double batchCommandSessionListHeight = 270;
  static const double batchCommandSessionItemHeight = 32;
  static const double batchCommandSessionItemGap = 2;
  static const double batchCommandSessionColumnGap = 8;
  static const EdgeInsets batchCommandSessionItemPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 5,
  );
  static const double fileConflictDialogMaxWidth = 400;
  static const double folderDialogMaxWidth = 320;
  static const double inputIconSize = 16;
  static const double inputFontSize = 13;
  static const double inputMinHeight = 34;
  static const double treeDropGuideHeight = 2;
  static const double treeFolderDropEdgeFraction = 0.25;
  static const double treeDragFeedbackOpacity = 0.8;
  static const EdgeInsets menuItemPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 6,
  );
  static const double menuItemRadius = 4;
  static const double commandPaletteSectionGap = 12;
  static const double commandPaletteItemGap = 8;
  static const double commandPaletteItemRadius = 8;
  static const EdgeInsets commandPaletteItemPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  );

  static const shadcn.ThemeData shadcnDark = shadcn.ThemeData(
    colorScheme: shadcn.ColorSchemes.darkZinc,
    radius: 0.5,
    typography: shadcn.Typography.geist(
      // 使用完整字体名，避免 package 属性给系统中文回退字体也加上包名前缀。
      sans: TextStyle(fontFamily: 'packages/shadcn_flutter/GeistSans'),
      mono: TextStyle(fontFamily: 'packages/shadcn_flutter/GeistMono'),
      base: TextStyle(
        fontSize: 14,
        fontFamilyFallback: ['PingFang SC', 'Microsoft YaHei'],
      ),
    ),
  );

  static final shadcn.ThemeData shadcnLight = shadcnDark.copyWith(
    colorScheme: () => shadcn.ColorSchemes.lightZinc,
  );
}

abstract final class StatusColors {
  static const Color connecting = Color(0xFFE8B93E);
  static const Color ready = Color(0xFF34D399);
  static const Color failed = Color(0xFFE5534B);
  static const Color closed = Color(0xFF8B949E);
}
