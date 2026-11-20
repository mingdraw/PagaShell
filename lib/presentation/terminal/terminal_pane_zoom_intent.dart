import 'package:flutter/widgets.dart';

class TerminalPaneZoomIntent extends Intent {
  const TerminalPaneZoomIntent();
}

class TerminalPaneCycleIntent extends Intent {
  const TerminalPaneCycleIntent(this.direction);

  final int direction;
}
