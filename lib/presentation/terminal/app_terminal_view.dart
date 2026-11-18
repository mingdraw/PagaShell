import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

import '../../application/settings/settings_controller.dart';
import '../../domain/entities/sidebar_state.dart';
import '../theme/app_theme.dart';

class AppTerminalView extends StatelessWidget {
  const AppTerminalView(
    this.terminal, {
    required this.focusNode,
    required this.active,
    super.key,
  });

  final Terminal terminal;
  final FocusNode focusNode;
  final bool active;

  Widget _pane(double fontSize) => TerminalPane(
    terminal,
    focusNode: focusNode,
    active: active,
    backgroundColor: AppTheme.terminalBackground,
    selectionEdgeExtent: AppTheme.terminalSelectionEdgeExtent,
    selectionScrollInterval: AppTheme.terminalSelectionScrollInterval,
    textStyle: TerminalStyle(
      fontSize: fontSize,
      fontFamily: 'FiraCode Nerd Font Mono',
      fontFamilyFallback: const [
        'MesloLGS NF',
        'Menlo',
        'PingFang SC',
        'Microsoft YaHei',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
        'monospace',
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<SettingsController>()) {
      return _pane(SidebarState.defaultTerminalFontSize);
    }
    final settings = Get.find<SettingsController>();
    return Obx(() => _pane(settings.terminalFontSize.value));
  }
}
