import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// Only rebuilds a mounted row when its own selection changes.
class AppIndexedSelection extends StatefulWidget {
  const AppIndexedSelection({
    required this.selection,
    required this.index,
    required this.itemCount,
    required this.builder,
    super.key,
  });

  final ValueListenable<int> selection;
  final int index;
  final int itemCount;
  final Widget Function(BuildContext, bool) builder;

  @override
  State<AppIndexedSelection> createState() => _AppIndexedSelectionState();
}

class _AppIndexedSelectionState extends State<AppIndexedSelection> {
  bool get _matches =>
      widget.index == widget.selection.value.clamp(0, widget.itemCount - 1);
  late bool _selected;

  @override
  void initState() {
    super.initState();
    _selected = _matches;
    widget.selection.addListener(_onSelection);
  }

  @override
  void didUpdateWidget(covariant AppIndexedSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection.removeListener(_onSelection);
      widget.selection.addListener(_onSelection);
    }
    _selected = _matches;
  }

  void _onSelection() {
    final selected = _matches;
    if (_selected != selected) setState(() => _selected = selected);
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _selected);
}
