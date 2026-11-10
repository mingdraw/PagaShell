import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

/// 应用外壳使用 shadcn Neutral 主题；终端配色独立。
abstract final class AppTheme {
  static const Color terminalBackground = Color(0xFF09090B);
  static const Color terminalForeground = Color(0xFFCDD2DA);
  static const Color terminalMutedForeground = Color(0xFF8B939F);
  static const Color terminalBorder = Color(0xFF24282F);
  static const Color terminalSelectedBorder = Color(0xFF536A80);
  static const Color terminalControlBackground = Color(0xFF181C22);
  static const Color serverStatusCpuColor = Color(0xFF69CBA5);
  static const Color serverStatusLoadColor = Color(0xFFE2A66D);
  static const Color serverStatusMemoryColor = Color(0xFF83A9ED);
  static const Color serverStatusDiskColor = Color(0xFFB59BE3);
  static const Color serverStatusWarningColor = Color(0xFFE3B76A);

  static final shadcn.ColorScheme terminalColors = shadcn.ColorSchemes.darkZinc
      .copyWith(
        background: () => terminalBackground,
        foreground: () => terminalForeground,
        card: () => terminalBackground,
        cardForeground: () => terminalForeground,
        popover: () => terminalControlBackground,
        popoverForeground: () => terminalForeground,
        primary: () => terminalForeground,
        primaryForeground: () => terminalBackground,
        secondary: () => terminalControlBackground,
        secondaryForeground: () => terminalForeground,
        muted: () => terminalControlBackground,
        mutedForeground: () => terminalMutedForeground,
        accent: () => terminalControlBackground,
        accentForeground: () => terminalForeground,
        border: () => terminalBorder,
        destructive: () => StatusColors.failed,
      );

  /// 终端工作区只继承平台、字体与缩放，配色固定为终端深色。
  static shadcn.ThemeData terminalTheme(BuildContext context) =>
      shadcn.Theme.of(context).copyWith(colorScheme: () => terminalColors);

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
  static const double toolbarIconSize = 15;
  static const double terminalToolbarHeight = 36;
  static const double terminalToolbarButtonSize = 28;
  static const double terminalPaneCloseSize = 24;
  static const double terminalPaneMinWidth = 160;
  static const double terminalPaneMinHeight = 100;
  static const double terminalSelectionEdgeExtent = 24;
  static const Duration terminalSelectionScrollInterval = Duration(
    milliseconds: 40,
  );
  static const double serverStatusCoreLabelWidth = 48;
  static const double serverStatusCoreValueWidth = 44;
  static const double serverStatusDefaultWidth = 320;
  static const double serverStatusMinWidth = 220;
  static const double serverStatusMaxWidth = 520;
  static const double fileSizeColumnWidth = 64;
  static const double fileModifiedColumnWidth = 140;
  static const double fileBrowserMinHeight = 180;
  static const double fileSelectionGutter = 8;
  static const double fileSelectionDragThreshold = 4;
  static const double fileSelectionEdgeExtent = 24;
  static const Duration fileSelectionScrollInterval = Duration(
    milliseconds: 40,
  );
  static const double transferProgressCollapsedHeight = 36;
  static const double transferProgressDefaultHeight = 240;
  static const double transferProgressMinHeight = 96;
  static const double transferProgressRowHeight = 50;
  static const double sidebarWidth = 264;
  static const double sidebarFooterHeight = 40;
  static const double settingsDialogMaxWidth = 600;
  static const double proxyModeCardWidth = 320;
  static const double clashScriptDialogMaxWidth = 840;
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
  static const double processDetailsDialogMaxWidth = 560;
  static const double inputIconSize = 16;
  static const double inputFontSize = 13;
  static const double inputMinHeight = 34;
  static const double inputCompactMinHeight = 28;
  static const double inputCompactFontSize = 11;
  static const EdgeInsets inputCompactPadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 4,
  );
  static const EdgeInsets typeRadioCardPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 6,
  );
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

  static final shadcn.ThemeData shadcnDark = shadcn.ThemeData(
    colorScheme: shadcn.ColorSchemes.darkNeutral.neutral,
    radius: 0.5,
    typography: const shadcn.Typography.geist(
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
    colorScheme: () => shadcn.ColorSchemes.lightNeutral.neutral,
  );
}

abstract final class StatusColors {
  static const Color connecting = Color(0xFFE8B93E);
  static const Color ready = Color(0xFF34D399);
  static const Color failed = Color(0xFFE5534B);
  static const Color closed = Color(0xFF8B949E);
}
