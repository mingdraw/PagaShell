import 'package:flutter/widgets.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

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

  @override
  Widget build(BuildContext context) => TerminalPane(
    terminal,
    focusNode: focusNode,
    active: active,
    backgroundColor: AppTheme.terminalBackground,
    selectionEdgeExtent: AppTheme.terminalSelectionEdgeExtent,
    selectionScrollInterval: AppTheme.terminalSelectionScrollInterval,
    textStyle: const TerminalStyle(
      fontSize: 13,
      fontFamily: 'FiraCode Nerd Font Mono',
      fontFamilyFallback: [
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
}
