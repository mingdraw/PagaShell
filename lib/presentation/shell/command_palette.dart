import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/ai_settings_controller.dart';
import '../../application/hosts/host_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/session/session_layout.dart';
import '../../application/settings/settings_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/ssh/ssh_endpoint.dart';
import '../ai/agent_workspace.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_indexed_selection.dart';
import '../components/app_list_row.dart';
import '../hosts/host_edit_dialog.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'agent_sidebar_scope.dart';
import 'connect_flow.dart';

/// 命令面板（⌘K / Ctrl+Shift+K）：多词模糊搜服务、切换已打开标签、快捷执行工作区操作。
Future<void> showCommandPalette(BuildContext context) {
  final sidebar = AgentSidebarScope.maybeOf(context);
  return AppNavigation.dialog<void>(
    _CommandPalette(sidebar: sidebar),
    barrierColor: const Color(0x61000000),
  );
}

enum _PaletteSection { hosts, tabs, actions }

typedef _PaletteGroup = ({
  _PaletteSection section,
  int start,
  int end,
  double top,
  double headerHeight,
  double rowHeight,
});

sealed class _PaletteEntry {
  const _PaletteEntry();

  _PaletteSection get section;
}

final class _HostPaletteEntry extends _PaletteEntry {
  const _HostPaletteEntry({
    required this.host,
    required this.isRecent,
    required this.isConnected,
  });

  final Host host;
  final bool isRecent;
  final bool isConnected;

  @override
  _PaletteSection get section => _PaletteSection.hosts;
}

final class _TabPaletteEntry extends _PaletteEntry {
  const _TabPaletteEntry({required this.tab, required this.session});

  final SessionTab tab;
  final Session session;
  bool get isSplit => tab.layout is SessionSplit;
  String get paneLabel => '窗格 @index/@total'.trParams({
    'index': '${tab.sessionIds.toList().indexOf(session.id) + 1}',
    'total': '${tab.sessionIds.length}',
  });

  @override
  _PaletteSection get section => _PaletteSection.tabs;

  String get kindLabel => switch (session.kind) {
    SessionKind.terminal => '终端'.tr,
    SessionKind.containerTerminal => '容器终端'.tr,
    SessionKind.fileTransfer => '文件传输'.tr,
    SessionKind.portForward => '端口转发'.tr,
    SessionKind.dynamicProxy => '动态代理'.tr,
    SessionKind.remoteDesktop => '远程桌面'.tr,
  };
}

final class _ActionPaletteEntry extends _PaletteEntry {
  const _ActionPaletteEntry({
    required this.id,
    required this.icon,
    required this.title,
    required this.keywords,
    required this.onRun,
  });

  final String id;
  final AppIcons icon;
  final String title;
  final String keywords;
  final void Function(BuildContext workspaceContext) onRun;

  @override
  _PaletteSection get section => _PaletteSection.actions;
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({this.sidebar});

  final AgentSidebarScope? sidebar;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  String _query = '';
  final _selected = ValueNotifier(0);
  static final _space = RegExp(r'\s+');
  bool _confirming = false;
  ({PhysicalKeyboardKey key, bool transfer, bool newSession})? _pendingEnter;

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    _selected.dispose();
    super.dispose();
  }

  List<Host> _orderedHosts(
    List<Host> sorted,
    Set<String> recentIds,
    Set<String> connectedIds,
  ) {
    if (recentIds.isEmpty && connectedIds.isEmpty) return sorted;
    final byId = {for (final host in sorted) host.id: host};
    final result = <Host>[];
    final seen = <String>{};
    for (final id in recentIds) {
      final host = byId[id];
      if (host != null && seen.add(id)) {
        result.add(host);
      }
    }
    for (final host in sorted) {
      if (connectedIds.contains(host.id) && seen.add(host.id)) {
        result.add(host);
      }
    }
    for (final host in sorted) {
      if (seen.add(host.id)) {
        result.add(host);
      }
    }
    return result;
  }

  List<_PaletteEntry> _buildEntries(List<Host> allHosts) {
    final sessionController = Get.isRegistered<SessionController>()
        ? Get.find<SessionController>()
        : null;
    final settingsController = Get.isRegistered<SettingsController>()
        ? Get.find<SettingsController>()
        : null;
    final recentIds = <String>{
      if (sessionController != null) ...sessionController.recentHostIds,
      if (settingsController != null)
        ...settingsController.sidebarRecentHostIds,
    };
    final sessions = sessionController?.sessions.toList() ?? const [];
    final tabs = sessionController?.tabs ?? const [];
    final sessionsById = {for (final s in sessions) s.id: s};
    final connectedHostIds = {
      for (final s in sessions)
        if (s.phase == SessionPhase.ready &&
            s.kind != SessionKind.containerTerminal)
          s.host.id,
    };
    final tokens = _query
        .trim()
        .toLowerCase()
        .split(_space)
        .where((token) => token.isNotEmpty)
        .toList();
    bool matches(String haystack) =>
        tokens.isEmpty || tokens.every(haystack.contains);

    final ordered = _orderedHosts(allHosts, recentIds, connectedHostIds);
    final entries = <_PaletteEntry>[];

    for (final host in ordered) {
      final target =
          '${host.searchText} ${host.port} ${host.note} ${host.serviceType.label}'
              .toLowerCase();
      if (matches(target)) {
        entries.add(
          _HostPaletteEntry(
            host: host,
            isRecent: recentIds.contains(host.id),
            isConnected: connectedHostIds.contains(host.id),
          ),
        );
      }
    }

    for (final tab in tabs) {
      for (final id in [
        tab.selectedSessionId,
        ...tab.sessionIds.where((id) => id != tab.selectedSessionId),
      ]) {
        final session = sessionsById[id];
        if (session == null) continue;
        final tabEntry = _TabPaletteEntry(tab: tab, session: session);
        final searchTarget =
            '${session.title} ${session.address} '
            '${tabEntry.kindLabel} ${session.host.serviceType.label}';
        if (matches(searchTarget.toLowerCase())) {
          entries.add(tabEntry);
          if (tokens.isEmpty) break;
        }
      }
    }

    final includeActions =
        tokens.isNotEmpty || allHosts.isNotEmpty || tabs.isNotEmpty;
    if (includeActions) {
      final actions = <_ActionPaletteEntry>[
        if (settingsController != null)
          _ActionPaletteEntry(
            id: 'toggle-sidebar',
            icon: AppIcons.panelLeftOpen,
            title: '切换侧边栏'.tr,
            keywords: 'sidebar panel left 侧边栏 收起 展开',
            onRun: (_) => unawaited(_toggleSidebar(settingsController)),
          ),
        if (Get.isRegistered<AiSettingsController>())
          _ActionPaletteEntry(
            id: 'toggle-agent',
            icon: AppIcons.bot,
            title: '切换 AI Agent'.tr,
            keywords: 'ai agent assistant 助手 面板',
            onRun: (_) => toggleAgentPanel(),
          ),
        _ActionPaletteEntry(
          id: 'new-service',
          icon: AppIcons.plus,
          title: '新建服务'.tr,
          keywords: 'new service host server 新建 添加 服务 主机',
          onRun: (ctx) => unawaited(showHostEditDialog(ctx)),
        ),
        _ActionPaletteEntry(
          id: 'open-settings',
          icon: AppIcons.settings,
          title: '打开设置'.tr,
          keywords: 'settings preferences config 设置 偏好',
          onRun: (_) => unawaited(showSettingsDialog()),
        ),
      ];
      for (final action in actions) {
        final target = '${action.title} ${action.keywords}'.toLowerCase();
        if (matches(target)) {
          entries.add(action);
        }
      }
    }

    final endpoint = parseSshEndpoint(_query);
    if (sessionController != null && endpoint != null) {
      final username = endpoint.username ?? ServiceType.ssh.defaultUsername;
      final port = endpoint.port ?? ServiceType.ssh.defaultPort;
      final hostname = endpoint.hostname;
      final address = hostname.contains(':') ? '[$hostname]' : hostname;
      entries.add(
        _ActionPaletteEntry(
          id: 'temporary-ssh',
          icon: AppIcons.terminal,
          title: '临时连接 @address'.trParams({
            'address': '$username@$address:$port',
          }),
          keywords: '',
          onRun: (context) => unawaited(
            connectToHost(
              context,
              Host(
                id: 'temporary-${DateTime.now().microsecondsSinceEpoch}',
                name: hostname,
                hostname: hostname,
                username: username,
                port: port,
              ),
              temporary: true,
              forceNew: true,
            ),
          ),
        ),
      );
    }
    return entries;
  }

  Future<void> _toggleSidebar(SettingsController settings) async {
    try {
      if (widget.sidebar?.sidebarHiddenForSpace ?? false) {
        await widget.sidebar!.showSidebar();
      } else {
        await settings.setSidebarVisible(!settings.sidebarVisible.value);
      }
    } on Object {
      AppNotice.error('保存失败，请重试');
    }
  }

  void _confirm(
    List<_PaletteEntry> entries,
    List<Host> allHosts, {
    bool openTransfer = false,
    bool forceNew = false,
  }) {
    if (_confirming) return;
    if (entries.isEmpty) {
      if (allHosts.isEmpty && _query.trim().isEmpty) {
        _confirming = true;
        AppNavigation.closeDialog<void>();
        unawaited(showHostEditDialog(Get.context!));
      }
      return;
    }
    final workspaceContext = Get.context!;
    _confirming = true;
    AppNavigation.closeDialog<void>();
    final entry = entries[_selected.value.clamp(0, entries.length - 1)];
    switch (entry) {
      case _HostPaletteEntry(:final host):
        if (openTransfer && !host.isDesktop) {
          unawaited(
            connectToHost(
              workspaceContext,
              host,
              kind: SessionKind.fileTransfer,
            ),
          );
        } else {
          unawaited(connectToHost(workspaceContext, host, forceNew: forceNew));
        }
      case _TabPaletteEntry(:final session):
        if (Get.isRegistered<SessionController>()) {
          Get.find<SessionController>().activate(session.id);
        }
      case _ActionPaletteEntry(:final onRun):
        onRun(workspaceContext);
    }
  }

  KeyEventResult _onKey(
    KeyEvent event,
    List<_PaletteEntry> entries,
    List<Host> allHosts,
    List<_PaletteGroup> groups,
  ) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter && event is KeyUpEvent) {
      final pending = _pendingEnter;
      if (pending == null || event.physicalKey != pending.key) {
        return KeyEventResult.ignored;
      }
      _pendingEnter = null;
      if (!event.synthesized && _input.value.composing.isCollapsed) {
        _confirm(
          // Text input can change before the next frame rebuilds the rows.
          _buildEntries(allHosts),
          allHosts,
          openTransfer: pending.transfer,
          forceNew: pending.newSession,
        );
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (enter && event is KeyDownEvent) _pendingEnter = null;
    if (!_input.value.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowUp:
        if (entries.isEmpty) return KeyEventResult.handled;
        final current = _selected.value.clamp(0, entries.length - 1);
        final step = event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1;
        _selected.value = (current + step) % entries.length;
        _reveal(groups, _selected.value);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        final keyboard = HardwareKeyboard.instance;
        // Wait for release so repeats cannot reach the newly focused terminal.
        _pendingEnter = (
          key: event.physicalKey,
          transfer: keyboard.isMetaPressed || keyboard.isControlPressed,
          newSession: keyboard.isShiftPressed,
        );
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  String _sectionTitle(_PaletteSection section) => switch (section) {
    _PaletteSection.hosts => '最近与服务'.tr,
    _PaletteSection.tabs => '已打开标签'.tr,
    _PaletteSection.actions => '工作区操作'.tr,
  };

  String _shortcutHint(_PaletteEntry entry, bool isMac) => switch (entry) {
    _HostPaletteEntry(:final host) when host.isDesktop => '回车连接 · ⇧↵ 新建会话',
    _HostPaletteEntry() =>
      isMac ? '回车连接 · ⌘↵ 文件传输 · ⇧↵ 新建会话' : '回车连接 · Ctrl+↵ 文件传输 · ⇧↵ 新建会话',
    _TabPaletteEntry(:final isSplit) => isSplit ? '回车聚焦窗格' : '回车切换标签',
    _ActionPaletteEntry(id: 'temporary-ssh') => '回车连接',
    _ActionPaletteEntry() => '回车执行',
  };

  List<_PaletteGroup> _groups(
    BuildContext context,
    List<_PaletteEntry> entries,
  ) {
    final textScaler = MediaQuery.textScalerOf(context);
    final labelHeight = textScaler.scale(11) * 1.4 + 6;
    final titleHeight = textScaler.scale(13) * 1.4;
    final detailHeight = textScaler.scale(11) * 1.4 + 4;
    var top = AppTheme.commandPaletteSectionGap;
    final groups = <_PaletteGroup>[];
    for (var start = 0; start < entries.length;) {
      final section = entries[start].section;
      var end = start + 1;
      while (end < entries.length && entries[end].section == section) {
        end++;
      }
      final headerHeight = labelHeight + (start == 0 ? 0.0 : 8.0);
      final rowHeight =
          AppTheme.commandPaletteItemPadding.vertical +
          AppTheme.commandPaletteItemGap +
          (section == _PaletteSection.actions
              ? math.max(18.0, titleHeight)
              : math.max(26.0, titleHeight + detailHeight));
      groups.add((
        section: section,
        start: start,
        end: end,
        top: top,
        headerHeight: headerHeight,
        rowHeight: rowHeight,
      ));
      top += headerHeight + (end - start) * rowHeight;
      start = end;
    }
    return groups;
  }

  void _reveal(List<_PaletteGroup> groups, int index) {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final group = groups.firstWhere((group) => index < group.end);
    final position = _scroll.position;
    final top =
        group.top +
        group.headerHeight +
        (index - group.start) * group.rowHeight;
    final bottom = top + group.rowHeight;
    final target = index == 0 || top < position.pixels
        ? (index == 0 ? 0.0 : top)
        : math.max(position.pixels, bottom - position.viewportDimension);
    final offset = target.clamp(0.0, position.maxScrollExtent);
    if (offset != position.pixels) position.jumpTo(offset);
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<HostController>();
    final theme = shadcn.Theme.of(context);
    final colors = theme.colorScheme;
    final isMac = theme.platform == TargetPlatform.macOS;
    final listMaxHeight = math.min(
      360.0,
      math.max(180.0, MediaQuery.sizeOf(context).height - 240),
    );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: const Alignment(0, -0.6),
        child: shadcn.SurfaceCard(
          // 面板不受侧边栏搜索词影响，读取全量列表自行过滤。
          child: Obx(() {
            final allHosts = controller.sorted;
            final entries = _buildEntries(allHosts);
            final groups = _groups(context, entries);

            return SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    onKeyEvent: (node, event) =>
                        _onKey(event, entries, allHosts, groups),
                    child: shadcn.TextField(
                      key: const ValueKey('command-palette-input'),
                      controller: _input,
                      autofocus: true,
                      onChanged: (v) {
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                        setState(() {
                          _query = v;
                          _selected.value = 0;
                        });
                      },
                      hintText: '输入服务名称 / 地址，回车连接…'.tr,
                      placeholder: Text('输入服务名称 / 地址，回车连接…'.tr),
                      border: Border.all(color: shadcn.Colors.transparent),
                      padding: const EdgeInsets.all(16),
                      features: const [
                        shadcn.InputFeature.leading(
                          AppIcon(AppIcons.search, size: 16),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.commandPaletteSectionGap),
                  const shadcn.Divider(),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        allHosts.isEmpty && _query.trim().isEmpty
                            ? '还没有服务，回车直接新建'.tr
                            : '没有匹配的服务'.tr,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.mutedForeground,
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: listMaxHeight),
                      child: CustomScrollView(
                        key: const ValueKey('command-palette-list'),
                        controller: _scroll,
                        shrinkWrap: true,
                        slivers: [
                          const SliverToBoxAdapter(
                            child: SizedBox(
                              height: AppTheme.commandPaletteSectionGap,
                            ),
                          ),
                          for (final group in groups) ...[
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: group.headerHeight,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    6,
                                    0,
                                    6,
                                    4,
                                  ),
                                  child: Align(
                                    alignment: Alignment.bottomLeft,
                                    child: Text(
                                      _sectionTitle(group.section),
                                      key: ValueKey(
                                        'palette-section-${group.section.name}',
                                      ),
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                        color: colors.mutedForeground,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SliverFixedExtentList.builder(
                              itemExtent: group.rowHeight,
                              itemCount: group.end - group.start,
                              itemBuilder: (context, localIndex) {
                                final index = group.start + localIndex;
                                return Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AppTheme.commandPaletteItemGap,
                                  ),
                                  child: MouseRegion(
                                    // A stationary pointer does not steal keyboard selection.
                                    onHover: (_) => _selected.value = index,
                                    child: AppIndexedSelection(
                                      selection: _selected,
                                      index: index,
                                      itemCount: entries.length,
                                      builder: (context, selected) => _buildRow(
                                        context,
                                        entries[index],
                                        selected: selected,
                                        onTap: () {
                                          _selected.value = index;
                                          _confirm(entries, allHosts);
                                        },
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                          const SliverToBoxAdapter(
                            child: SizedBox(
                              height:
                                  AppTheme.commandPaletteSectionGap -
                                  AppTheme.commandPaletteItemGap,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (entries.isNotEmpty) ...[
                    const shadcn.Divider(),
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ValueListenableBuilder<int>(
                          valueListenable: _selected,
                          builder: (context, index, _) => Text(
                            _shortcutHint(
                              entries[index.clamp(0, entries.length - 1)],
                              isMac,
                            ).tr,
                            key: const ValueKey('command-palette-shortcuts'),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    _PaletteEntry entry, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final workspaceContext = Get.context!;

    switch (entry) {
      case _HostPaletteEntry(:final host, :final isRecent, :final isConnected):
        return AppListRow(
          key: ValueKey('palette-host-${host.id}'),
          selected: selected,
          contentPadding: AppTheme.commandPaletteItemPadding,
          borderRadius: BorderRadius.circular(
            AppTheme.commandPaletteItemRadius,
          ),
          leading: AppIcon(
            AppIcons.forServiceType(host.serviceType),
            size: 18,
            color: host.colorValue != null
                ? Color(host.colorValue!)
                : colors.primary,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isConnected) ...[
                const SizedBox(width: 6),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: StatusColors.ready,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '已连接'.tr,
                  style: TextStyle(fontSize: 10, color: colors.mutedForeground),
                ),
              ] else if (isRecent) ...[
                const SizedBox(width: 6),
                shadcn.OutlineBadge(
                  child: Text('最近'.tr, style: const TextStyle(fontSize: 10)),
                ),
              ],
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              host.address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!host.isDesktop)
                SizedBox.square(
                  dimension: 26,
                  child: AppIconButton.text(
                    key: ValueKey('palette-sftp-${host.id}'),
                    semanticLabel: '文件传输'.tr,
                    tooltip: '文件传输'.tr,
                    density: shadcn.ButtonDensity.compact,
                    onPressed: () {
                      AppNavigation.closeDialog<void>();
                      unawaited(
                        connectToHost(
                          workspaceContext,
                          host,
                          kind: SessionKind.fileTransfer,
                        ),
                      );
                    },
                    icon: const AppIcon(AppIcons.folderOpen, size: 14),
                  ),
                ),
              SizedBox.square(
                dimension: 26,
                child: AppIconButton.text(
                  key: ValueKey('palette-new-session-${host.id}'),
                  semanticLabel: '新建会话'.tr,
                  tooltip: '新建会话'.tr,
                  density: shadcn.ButtonDensity.compact,
                  onPressed: () {
                    AppNavigation.closeDialog<void>();
                    unawaited(
                      connectToHost(workspaceContext, host, forceNew: true),
                    );
                  },
                  icon: const AppIcon(AppIcons.plus, size: 14),
                ),
              ),
              SizedBox.square(
                dimension: 26,
                child: AppIconButton.text(
                  key: ValueKey('palette-edit-${host.id}'),
                  semanticLabel: '编辑'.tr,
                  tooltip: '编辑'.tr,
                  density: shadcn.ButtonDensity.compact,
                  onPressed: () {
                    AppNavigation.closeDialog<void>();
                    unawaited(showHostEditDialog(workspaceContext, host: host));
                  },
                  icon: const AppIcon(AppIcons.pencil, size: 14),
                ),
              ),
            ],
          ),
          onTap: onTap,
        );
      case _TabPaletteEntry(:final tab, :final session):
        final statusColor = switch (session.phase) {
          SessionPhase.ready => StatusColors.ready,
          SessionPhase.failed => StatusColors.failed,
          SessionPhase.closed => StatusColors.closed,
          _ => StatusColors.connecting,
        };
        return AppListRow(
          key: ValueKey(
            session.id == tab.selectedSessionId
                ? 'palette-tab-${tab.id}'
                : 'palette-pane-${session.id}',
          ),
          selected: selected,
          contentPadding: AppTheme.commandPaletteItemPadding,
          borderRadius: BorderRadius.circular(
            AppTheme.commandPaletteItemRadius,
          ),
          leading: AppIcon(
            switch (session.kind) {
              SessionKind.fileTransfer => AppIcons.folderOpen,
              SessionKind.portForward => AppIcons.arrowLeftRight,
              SessionKind.dynamicProxy => AppIcons.proxy,
              SessionKind.terminal => AppIcons.terminal,
              SessionKind.containerTerminal => AppIcons.container,
              SessionKind.remoteDesktop => AppIcons.forServiceType(
                session.host.serviceType,
              ),
            },
            size: 18,
            color: statusColor,
          ),
          title: Text(
            entry.isSplit
                ? '${session.title} · ${entry.paneLabel}'
                : session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              entry.kindLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ),
          trailing: shadcn.OutlineBadge(
            child: Text(
              (entry.isSplit ? '聚焦窗格' : '切换标签').tr,
              style: const TextStyle(fontSize: 10),
            ),
          ),
          onTap: onTap,
        );
      case _ActionPaletteEntry(:final id, :final icon, :final title):
        return AppListRow(
          key: ValueKey('palette-action-$id'),
          selected: selected,
          contentPadding: AppTheme.commandPaletteItemPadding,
          borderRadius: BorderRadius.circular(
            AppTheme.commandPaletteItemRadius,
          ),
          leading: AppIcon(icon, size: 18, color: colors.primary),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          onTap: onTap,
        );
    }
  }
}
