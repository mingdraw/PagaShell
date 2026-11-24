import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/settings/settings_controller.dart';
import '../../domain/terminal/quick_command.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'terminal_search_field.dart';

const _commandMonoStyle = TextStyle(
  fontFamily: 'FiraCode Nerd Font Mono',
  fontFamilyFallback: ['Menlo', 'PingFang SC', 'Microsoft YaHei', 'monospace'],
  fontSize: 12,
  height: 1.25,
);

/// 终端底部常用运维指令面板：左侧分类 Tab，右侧 Badge 列表与悬停功能说明。
class QuickCommandsPanel extends StatefulWidget {
  const QuickCommandsPanel({
    required this.onSelectCommand,
    required this.onClose,
    this.targetLabel,
    super.key,
  });

  final ValueChanged<QuickCommand> onSelectCommand;
  final VoidCallback onClose;
  final String? targetLabel;

  @override
  State<QuickCommandsPanel> createState() => _QuickCommandsPanelState();
}

class _QuickCommandsPanelState extends State<QuickCommandsPanel> {
  final _search = TextEditingController();
  final _tabsScroll = ScrollController();
  final _commandsScroll = ScrollController();
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    _tabsScroll.dispose();
    _commandsScroll.dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  void _selectCategory(List<QuickCommandCategory> categories, int index) {
    if (index < 0 || index >= categories.length) return;
    if (_search.text.isNotEmpty) {
      _search.clear();
    }
    setState(() => _selectedCategoryId = categories[index].id);
    if (_commandsScroll.hasClients) {
      _commandsScroll.jumpTo(0);
    }
  }

  static AppIcons _iconFor(QuickCommandCategory category) =>
      switch (category.builtInId) {
        QuickCommandCategoryId.system => AppIcons.statusServer,
        QuickCommandCategoryId.files => AppIcons.fileText,
        QuickCommandCategoryId.process => AppIcons.processes,
        QuickCommandCategoryId.network => AppIcons.networkPorts,
        QuickCommandCategoryId.docker => AppIcons.container,
        QuickCommandCategoryId.kubernetes => AppIcons.kubernetes,
        QuickCommandCategoryId.database => AppIcons.database,
        QuickCommandCategoryId.nginx => AppIcons.proxy,
        QuickCommandCategoryId.packages => AppIcons.packageBox,
        QuickCommandCategoryId.git => AppIcons.code,
        null => AppIcons.folder,
      };

  static String _categoryLabel(QuickCommandCategory category) =>
      category.isBuiltIn ? category.title.tr : category.title;

  @override
  Widget build(BuildContext context) {
    if (Get.isRegistered<SettingsController>()) {
      final settings = Get.find<SettingsController>();
      return Obx(
        () => _buildContent(
          settings.customQuickCommandGroups.toList(growable: false),
        ),
      );
    }
    return _buildContent(const []);
  }

  Widget _buildContent(List<QuickCommandCategory> customGroups) {
    final categories = QuickCommandCatalog.combined(customGroups);
    final selectedIndex = math.max(
      0,
      categories.indexWhere((item) => item.id == _selectedCategoryId),
    );
    final selectedCategory = categories[selectedIndex];
    final query = _search.text.trim();
    final searching = query.isNotEmpty;
    final searchMatches = searching
        ? QuickCommandCatalog.search(
            query,
            translate: (key) => key.tr,
            sourceCategories: categories,
          )
        : const <QuickCommandMatch>[];

    return ColoredBox(
      key: const ValueKey('quick-commands-panel'),
      color: AppTheme.terminalBackground,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final tabRailWidth = width < 360 ? 100.0 : 136.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(width),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _tabRail(
                      categories: categories,
                      customCount: customGroups.length,
                      selectedIndex: selectedIndex,
                      width: tabRailWidth,
                      searching: searching,
                    ),
                    Expanded(
                      child: _commandsArea(
                        selectedCategory: selectedCategory,
                        searching: searching,
                        searchMatches: searchMatches,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(double width) {
    final targetLabel = widget.targetLabel;
    return Container(
      key: const ValueKey('quick-commands-header'),
      height: 40,
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      decoration: const BoxDecoration(
        color: AppTheme.terminalBackground,
        border: Border(bottom: BorderSide(color: AppTheme.terminalBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppIcon(
            AppIcons.quickCommands,
            size: 14,
            color: AppTheme.serverStatusCpuColor,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '常用指令'.tr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.terminalForeground,
                    ),
                  ),
                ),
                if (targetLabel != null && width >= 440) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '· $targetLabel',
                      key: const ValueKey('quick-commands-target'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.terminalMutedForeground,
                      ),
                    ),
                  ),
                ] else if (width >= 520) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '点击填入聚焦终端，悬停查看说明'.tr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.terminalMutedForeground,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (width >= 300) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: math.min(200, width * 0.34),
              child: TerminalSearchField(
                fieldKey: const ValueKey('quick-commands-search'),
                clearKey: const ValueKey('quick-commands-search-clear'),
                controller: _search,
                semanticLabel: '搜索常用指令'.tr,
                hintText: '搜索指令或用途'.tr,
              ),
            ),
          ],
          if (Get.isRegistered<SettingsController>()) ...[
            const SizedBox(width: 4),
            AppIconButton(
              key: const ValueKey('quick-commands-manage'),
              semanticLabel: '管理常用指令'.tr,
              tooltip: '管理常用指令'.tr,
              density: shadcn.ButtonDensity.compact,
              onPressed: () =>
                  unawaited(showSettingsDialog(quickCommands: true)),
              icon: const AppIcon(AppIcons.settings, size: 14),
            ),
          ],
          const SizedBox(width: 2),
          AppIconButton(
            key: const ValueKey('quick-commands-close'),
            semanticLabel: '收起常用指令'.tr,
            tooltip: '收起常用指令'.tr,
            density: shadcn.ButtonDensity.compact,
            onPressed: widget.onClose,
            icon: const AppIcon(AppIcons.x, size: 14),
          ),
        ],
      ),
    );
  }

  Widget _tabRail({
    required List<QuickCommandCategory> categories,
    required int customCount,
    required int selectedIndex,
    required double width,
    required bool searching,
  }) => Container(
    key: const ValueKey('quick-commands-tabs'),
    width: width,
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: AppTheme.terminalBorder)),
    ),
    child: SingleChildScrollView(
      controller: _tabsScroll,
      padding: const EdgeInsets.all(6),
      child: shadcn.TabContainer(
        selected: searching ? -1 : selectedIndex,
        onSelect: (index) => _selectCategory(categories, index),
        builder: (context, children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (customCount > 0 && i == customCount)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: SizedBox(
                    height: 1,
                    child: ColoredBox(color: AppTheme.terminalBorder),
                  ),
                ),
              children[i],
            ],
          ],
        ),
        childBuilder: (context, data, child) {
          final category = categories[data.index];
          final label = _categoryLabel(category);
          final active = !searching && data.index == data.selected;
          return ExcludeFocus(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Semantics(
                button: true,
                selected: active,
                label: label,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: ValueKey('quick-commands-tab-${category.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => data.onSelect?.call(data.index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 90),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? AppTheme.terminalControlBackground
                            : null,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 2.5,
                            height: 12,
                            decoration: BoxDecoration(
                              color: active
                                  ? AppTheme.serverStatusCpuColor
                                  : const Color(0x00000000),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          AppIcon(
                            _iconFor(category),
                            size: 13,
                            color: active
                                ? AppTheme.terminalForeground
                                : AppTheme.terminalMutedForeground,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DefaultTextStyle.merge(
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: active
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: active
                                    ? AppTheme.terminalForeground
                                    : AppTheme.terminalMutedForeground,
                              ),
                              child: child,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        children: [
          for (final category in categories)
            shadcn.TabItem(
              child: Text(
                _categoryLabel(category),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _commandsArea({
    required QuickCommandCategory selectedCategory,
    required bool searching,
    required List<QuickCommandMatch> searchMatches,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final maxTextWidth = math.max(0.0, constraints.maxWidth - 46);
      if (searching && searchMatches.isEmpty) {
        return Center(
          child: Text(
            '没有匹配的常用指令'.tr,
            key: const ValueKey('quick-commands-empty'),
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.terminalMutedForeground,
            ),
          ),
        );
      }
      if (!searching && selectedCategory.commands.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前分组暂无指令'.tr,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.terminalMutedForeground,
                ),
              ),
              if (Get.isRegistered<SettingsController>()) ...[
                const SizedBox(height: 8),
                shadcn.OutlineButton(
                  size: shadcn.ButtonSize.small,
                  onPressed: () =>
                      unawaited(showSettingsDialog(quickCommands: true)),
                  child: Text('前往管理添加'.tr),
                ),
              ],
            ],
          ),
        );
      }
      final items = searching
          ? searchMatches
          : [
              for (final command in selectedCategory.commands)
                QuickCommandMatch(category: selectedCategory, command: command),
            ];
      return SingleChildScrollView(
        key: const ValueKey('quick-commands-list'),
        controller: _commandsScroll,
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.topLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final match in items)
                _QuickCommandBadge(
                  command: match.command,
                  categoryTitle: searching
                      ? _categoryLabel(match.category)
                      : null,
                  maxTextWidth: maxTextWidth,
                  onPressed: () => widget.onSelectCommand(match.command),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _QuickCommandBadge extends StatelessWidget {
  const _QuickCommandBadge({
    required this.command,
    required this.maxTextWidth,
    required this.onPressed,
    this.categoryTitle,
  });

  final QuickCommand command;
  final String? categoryTitle;
  final double maxTextWidth;
  final VoidCallback onPressed;

  static final shadcn.AbstractButtonStyle _badgeStyle =
      const shadcn.ButtonStyle.outline(
        size: shadcn.ButtonSize.small,
        density: shadcn.ButtonDensity.dense,
        shape: shadcn.ButtonShape.rectangle,
      ).copyWith(
        padding: (context, states, value) =>
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: (context, states, value) {
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          return BoxDecoration(
            color: pressed
                ? const Color(0xFF272E39)
                : hovered
                ? const Color(0xFF1F242D)
                : AppTheme.terminalControlBackground,
            border: Border.all(
              color: hovered || pressed
                  ? AppTheme.terminalSelectedBorder
                  : AppTheme.terminalBorder,
            ),
            borderRadius: BorderRadius.circular(6),
          );
        },
        textStyle: (context, states, value) =>
            _commandMonoStyle.copyWith(color: AppTheme.terminalForeground),
      );

  @override
  Widget build(BuildContext context) {
    final summary = command.isBuiltIn ? command.summary.tr : command.summary;
    final category = categoryTitle;
    final semanticSummary = summary.isEmpty ? '' : ' · $summary';
    return shadcn.Tooltip(
      alignment: Alignment.bottomCenter,
      anchorAlignment: Alignment.topCenter,
      waitDuration: const Duration(milliseconds: 220),
      tooltip: (context) => shadcn.TooltipContainer(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Builder(
            builder: (context) {
              final baseColor = DefaultTextStyle.of(context).style.color;
              final mutedColor = baseColor?.withValues(alpha: 0.72);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (summary.isNotEmpty) ...[
                    Text(
                      category == null ? summary : '[$category] $summary',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ] else if (category != null) ...[
                    Text(
                      category,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    command.displayCommand,
                    style: _commandMonoStyle.copyWith(
                      fontSize: 11,
                      color: summary.isNotEmpty ? mutedColor : baseColor,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      child: Semantics(
        button: true,
        label: '${command.displayCommand}$semanticSummary',
        child: shadcn.OutlineBadge(
          key: ValueKey('quick-command-${command.id}'),
          style: _badgeStyle,
          onPressed: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth),
            child: Text(
              command.displayCommand,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }
}
