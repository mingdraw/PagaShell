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
import '../components/app_list_row.dart';
import '../hosts/host_edit_dialog.dart';
import '../navigation/app_navigation.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'connect_flow.dart';

/// 命令面板（⌘K / Ctrl+Shift+K）：多词模糊搜服务、切换已打开标签、快捷执行工作区操作。
Future<void> showCommandPalette(BuildContext context) {
  return AppNavigation.dialog<void>(
    const _CommandPalette(),
    barrierColor: const Color(0x61000000),
  );
}

enum _PaletteSection { hosts, tabs, actions }

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
  const _CommandPalette();

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _scroll = ScrollController();
  String _query = '';
  int _selected = 0;
  bool _keyboardScrolling = false;
  bool _movingUp = false;

  @override
  void dispose() {
    _scroll.dispose();
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

  List<_PaletteEntry> _buildEntries(
    List<Host> allHosts,
    Set<String> recentIds,
    List<SessionTab> tabs,
    Map<String, Session> sessionsById,
    Set<String> connectedHostIds,
    SessionController? sessionController,
    SettingsController? settingsController,
  ) {
    final tokens = _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    bool matches(String haystack) =>
        tokens.isEmpty || tokens.every(haystack.contains);

    final ordered = _orderedHosts(allHosts, recentIds, connectedHostIds);
    final entries = <_PaletteEntry>[];

    for (final host in ordered) {
      final target = '${host.searchText} ${host.port} ${host.note}'
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
      final session = sessionsById[tab.selectedSessionId];
      if (session == null) continue;
      final tabEntry = _TabPaletteEntry(tab: tab, session: session);
      final searchTarget =
          '${session.title} ${session.address} ${tabEntry.kindLabel}'
              .toLowerCase();
      if (matches(searchTarget)) {
        entries.add(tabEntry);
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
            onRun: (_) => unawaited(
              settingsController
                  .setSidebarVisible(!settingsController.sidebarVisible.value)
                  .catchError((Object _) {}),
            ),
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

  void _confirm(
    List<_PaletteEntry> entries,
    List<Host> allHosts, {
    bool openTransfer = false,
    bool forceNew = false,
  }) {
    final workspaceContext = Get.context!;
    AppNavigation.closeDialog<void>();
    if (entries.isEmpty) {
      if (allHosts.isEmpty) {
        unawaited(showHostEditDialog(workspaceContext));
      }
      return;
    }
    final entry = entries[_selected.clamp(0, entries.length - 1)];
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
      case _TabPaletteEntry(:final tab):
        if (Get.isRegistered<SessionController>()) {
          Get.find<SessionController>().activateTab(tab.id);
        }
      case _ActionPaletteEntry(:final onRun):
        onRun(workspaceContext);
    }
  }

  KeyEventResult _onKey(
    FocusNode node,
    KeyEvent event,
    List<_PaletteEntry> entries,
    List<Host> allHosts,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowUp:
        if (entries.isEmpty) return KeyEventResult.handled;
        setState(() {
          final current = _selected.clamp(0, entries.length - 1);
          final step = event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1;
          _selected = (current + step) % entries.length;
          _keyboardScrolling = true;
          _movingUp = _selected < current;
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        final keyboard = HardwareKeyboard.instance;
        final openTransfer =
            keyboard.isMetaPressed || keyboard.isControlPressed;
        final forceNew = keyboard.isShiftPressed;
        _confirm(
          entries,
          allHosts,
          openTransfer: openTransfer,
          forceNew: forceNew,
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
            final sessionController = Get.isRegistered<SessionController>()
                ? Get.find<SessionController>()
                : null;
            final settingsController = Get.isRegistered<SettingsController>()
                ? Get.find<SettingsController>()
                : null;
            final recentIds = <String>{
              if (sessionController != null) ...sessionController.recentHostIds,
              if (settingsController != null)
                ...settingsController.sidebarState.value.recentHostIds,
            };
            final sessions = sessionController?.sessions.toList() ?? const [];
            final tabs = sessionController?.tabs ?? const [];
            final sessionsById = {for (final s in sessions) s.id: s};
            final connectedHostIds = {
              for (final s in sessions)
                if (s.phase.isAlive && s.kind != SessionKind.containerTerminal)
                  s.host.id,
            };
            final entries = _buildEntries(
              allHosts,
              recentIds,
              tabs,
              sessionsById,
              connectedHostIds,
              sessionController,
              settingsController,
            );
            final hasHostEntries = entries.any((e) => e is _HostPaletteEntry);
            final activeIndex = entries.isEmpty
                ? 0
                : _selected.clamp(0, entries.length - 1);

            final listChildren = <Widget>[];
            _PaletteSection? lastSection;
            for (var index = 0; index < entries.length; index++) {
              final entry = entries[index];
              if (entry.section != lastSection) {
                if (lastSection != null) {
                  listChildren.add(const SizedBox(height: 8));
                }
                lastSection = entry.section;
                listChildren.add(
                  Padding(
                    key: ValueKey('palette-section-${entry.section.name}'),
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                    child: Text(
                      _sectionTitle(entry.section),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
                );
              } else {
                listChildren.add(
                  const SizedBox(height: AppTheme.commandPaletteItemGap),
                );
              }
              final selected = index == activeIndex;
              listChildren.add(
                _PaletteRowHost(
                  selected: selected,
                  ensureVisible: _keyboardScrolling,
                  movingUp: _movingUp,
                  onHover: () {
                    if (_selected != index) {
                      setState(() {
                        _keyboardScrolling = false;
                        _selected = index;
                      });
                    }
                  },
                  child: _buildRow(
                    context,
                    entry,
                    selected: selected,
                    onTap: () {
                      _selected = index;
                      _confirm(entries, allHosts);
                    },
                  ),
                ),
              );
            }

            return SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    onKeyEvent: (node, event) =>
                        _onKey(node, event, entries, allHosts),
                    child: shadcn.TextField(
                      autofocus: true,
                      onChanged: (v) {
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                        setState(() {
                          _query = v;
                          _selected = 0;
                          _keyboardScrolling = true;
                          _movingUp = true;
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
                        allHosts.isEmpty ? '还没有服务，回车直接新建'.tr : '没有匹配的服务'.tr,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.mutedForeground,
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: listMaxHeight),
                      child: SingleChildScrollView(
                        key: const ValueKey('command-palette-list'),
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppTheme.commandPaletteSectionGap,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: listChildren,
                        ),
                      ),
                    ),
                  if (hasHostEntries) ...[
                    const shadcn.Divider(),
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          (isMac
                                  ? '回车连接 · ⌘↵ 文件传输 · ⇧↵ 新建会话'
                                  : '回车连接 · Ctrl+↵ 文件传输 · ⇧↵ 新建会话')
                              .tr,
                          key: const ValueKey('command-palette-shortcuts'),
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.mutedForeground,
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
          key: ValueKey('palette-tab-${tab.id}'),
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
            tab.sessionIds.length > 1
                ? '${session.title} · ${tab.sessionIds.length}'
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
            child: Text('切换标签'.tr, style: const TextStyle(fontSize: 10)),
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

class _PaletteRowHost extends StatefulWidget {
  const _PaletteRowHost({
    required this.selected,
    required this.ensureVisible,
    required this.movingUp,
    required this.onHover,
    required this.child,
  });

  final bool selected;
  final bool ensureVisible;
  final bool movingUp;
  final VoidCallback onHover;
  final Widget child;

  @override
  State<_PaletteRowHost> createState() => _PaletteRowHostState();
}

class _PaletteRowHostState extends State<_PaletteRowHost> {
  @override
  void initState() {
    super.initState();
    _revealIfSelected();
  }

  @override
  void didUpdateWidget(covariant _PaletteRowHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected || !oldWidget.ensureVisible) _revealIfSelected();
  }

  void _revealIfSelected() {
    if (!widget.selected || !widget.ensureVisible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.selected || !widget.ensureVisible) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: widget.movingUp
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      // 键盘滚动时，静止指针下的行会变；只有实际移动才切换到鼠标选中。
      MouseRegion(onHover: (_) => widget.onHover(), child: widget.child);
}
