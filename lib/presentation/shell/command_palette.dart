import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/hosts/host_controller.dart';
import '../../domain/entities/host.dart';
import '../components/app_list_row.dart';
import '../hosts/host_edit_dialog.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';
import 'connect_flow.dart';

/// 命令面板（⌘K / Ctrl+K）：模糊搜服务，回车即连接。
Future<void> showCommandPalette(BuildContext context) {
  return AppNavigation.dialog<void>(
    const _CommandPalette(),
    barrierColor: const Color(0x61000000),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette();

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  String _query = '';
  int _selected = 0;

  List<Host> _filter(List<Host> hosts) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return hosts;
    return hosts.where((h) => h.searchText.contains(q)).toList();
  }

  void _confirm(List<Host> hosts) {
    final workspaceContext = Get.context!;
    AppNavigation.closeDialog<void>();
    if (hosts.isEmpty) {
      showHostEditDialog(workspaceContext);
      return;
    }
    final host = hosts[_selected.clamp(0, hosts.length - 1)];
    connectToHost(workspaceContext, host);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<Host> hosts) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        setState(
          () =>
              _selected = (_selected + 1) % (hosts.isEmpty ? 1 : hosts.length),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        setState(() {
          final len = hosts.isEmpty ? 1 : hosts.length;
          _selected = (_selected - 1 + len) % len;
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        _confirm(hosts);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<HostController>();
    final colors = shadcn.Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: const Alignment(0, -0.6),
        child: shadcn.SurfaceCard(
          // 面板不受侧边栏搜索词影响，读取全量列表自行过滤。
          child: Obx(() {
            final allHosts = controller.sorted;
            final hosts = _filter(allHosts);
            return SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    onKeyEvent: (node, event) => _onKey(node, event, hosts),
                    child: shadcn.TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() {
                        _query = v;
                        _selected = 0;
                      }),
                      hintText: '输入服务名称 / 地址，回车连接…'.tr,
                      placeholder: Text('输入服务名称 / 地址，回车连接…'.tr),
                      border: Border.all(color: shadcn.Colors.transparent),
                      padding: const EdgeInsets.all(16),
                      features: const [
                        shadcn.InputFeature.leading(
                          Icon(shadcn.LucideIcons.search, size: 16),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.commandPaletteSectionGap),
                  const shadcn.Divider(),
                  if (hosts.isEmpty)
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
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppTheme.commandPaletteSectionGap,
                        ),
                        itemCount: hosts.length,
                        separatorBuilder: (context, index) => const SizedBox(
                          height: AppTheme.commandPaletteItemGap,
                        ),
                        itemBuilder: (context, index) {
                          final host = hosts[index];
                          final selected = index == _selected;
                          return AppListRow(
                            selected: selected,
                            contentPadding: AppTheme.commandPaletteItemPadding,
                            borderRadius: BorderRadius.circular(
                              AppTheme.commandPaletteItemRadius,
                            ),
                            leading: const Icon(
                              shadcn.LucideIcons.fileTerminal,
                              size: 18,
                            ),
                            title: Text(
                              host.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                host.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.mutedForeground,
                                ),
                              ),
                            ),
                            onTap: () {
                              _selected = index;
                              _confirm(hosts);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
