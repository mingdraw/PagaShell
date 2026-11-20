import 'package:flutter/widgets.dart';
import 'package:pagashell/terminal/src/base/disposable.dart';
import 'package:pagashell/terminal/src/core/buffer/buffer.dart';
import 'package:pagashell/terminal/src/core/buffer/cell_offset.dart';
import 'package:pagashell/terminal/src/core/buffer/line.dart';
import 'package:pagashell/terminal/src/core/buffer/range.dart';
import 'package:pagashell/terminal/src/core/buffer/range_block.dart';
import 'package:pagashell/terminal/src/core/buffer/range_line.dart';
import 'package:pagashell/terminal/src/core/buffer/terminal_text.dart';
import 'package:pagashell/terminal/src/ui/pointer_input.dart';
import 'package:pagashell/terminal/src/ui/selection_mode.dart';

typedef TerminalSearchHighlight = ({
  TerminalTextMatch match,
  int index,
  int version,
  int? start,
  int? end,
});

class TerminalController with ChangeNotifier {
  TerminalController({
    this._selectionMode = SelectionMode.line,
    this._pointerInputs = const PointerInputs({PointerInput.tap}),
    bool suspendPointerInput = false,
  }) : _suspendPointerInputs = suspendPointerInput;

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;
  bool _disposed = false;

  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  /// The set of pointer events which will be used as mouse input for the terminal.
  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  /// True if sending pointer events to the terminal is suspended.
  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];
  final _searchByRow =
      Map<BufferLine, List<TerminalSearchHighlight>>.identity();
  int _selectedSearchMatch = -1;
  Color _searchMatchColor = const Color(0x00000000);
  Color _selectedSearchColor = const Color(0x00000000);

  Iterable<TerminalSearchHighlight> searchHighlightsFor(BufferLine line) =>
      _searchByRow[line] ?? const [];

  bool isSelectedSearchMatch(int index) => _selectedSearchMatch == index;

  Color searchHighlightColor(int index) =>
      isSelectedSearchMatch(index) ? _selectedSearchColor : _searchMatchColor;

  /// Index by row identity: log trimming and scrolling do not require a re-sort.
  /// Links and selection use their own highlights and are left alone.
  void setSearchMatches(
    Buffer buffer,
    List<TerminalTextMatch> matches,
    int selected, {
    required Color matchColor,
    required Color selectedColor,
  }) {
    _searchByRow.clear();
    _selectedSearchMatch = selected;
    _searchMatchColor = matchColor;
    _selectedSearchColor = selectedColor;
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      if (!match.attached) continue;
      final first = match.first.index;
      final last = match.last.index;
      if (first > last ||
          last >= buffer.height ||
          !identical(buffer.lines[first], match.first) ||
          !identical(buffer.lines[last], match.last)) {
        continue;
      }
      for (var row = first; row <= last; row++) {
        final line = buffer.lines[row];
        (_searchByRow[line] ??= []).add((
          match: match,
          index: index,
          version: line.version,
          start: row == first ? match.start : null,
          end: row == last ? match.end : null,
        ));
      }
    }
    notifyListeners();
  }

  void selectSearchMatch(int index) {
    if (_selectedSearchMatch == index) return;
    _selectedSearchMatch = index;
    notifyListeners();
  }

  BufferRange? get selection {
    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  /// Set selection on the terminal from [base] to [extent]. This method takes
  /// the ownership of [base] and [extent] and will dispose them when the
  /// selection is cleared or changed.
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    notifyListeners();
  }

  /// 选择当前屏幕及其可用的回滚记录。
  void selectAll(Buffer buffer) {
    if (buffer.height == 0) {
      clearSelection();
      return;
    }
    setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(buffer.viewWidth, buffer.height - 1),
      mode: SelectionMode.line,
    );
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  /// Controls how the terminal behaves when the user selects a range of text.
  /// The default is [SelectionMode.line]. Setting this to [SelectionMode.block]
  /// enables block selection mode.
  void setSelectionMode(SelectionMode newSelectionMode) {
    // If the new mode is the same as the old mode,
    // nothing has to be changed.
    if (_selectionMode == newSelectionMode) {
      return;
    }
    // Set the new mode.
    _selectionMode = newSelectionMode;
    notifyListeners();
  }

  /// Clears the current selection.
  void clearSelection() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    notifyListeners();
  }

  // Select which type of pointer events are send to the terminal.
  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  // Toggle sending pointer events to the terminal.
  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  // Returns true if this type of PointerInput should be send to the Terminal.
  bool shouldSendPointerInput(PointerInput pointerInput) {
    // Always return false if pointer input is suspended.
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  /// Creates a new highlight on the terminal from [p1] to [p2] with the given
  /// [color]. The highlight will be removed when the returned object is
  /// disposed.
  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
    bool underline = false,
  }) {
    final highlight = TerminalHighlight(
      this,
      p1: p1,
      p2: p2,
      color: color,
      underline: underline,
    );

    _highlights.add(highlight);
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      if (!_disposed) notifyListeners();
    });

    return highlight;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    _searchByRow.clear();
    for (final highlight in List<TerminalHighlight>.of(_highlights)) {
      highlight.dispose();
    }
    super.dispose();
  }
}

class TerminalHighlight with Disposable {
  final TerminalController owner;

  final CellAnchor p1;

  final CellAnchor p2;

  final Color color;
  final bool underline;

  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
    this.underline = false,
  });

  /// Returns the range of the highlight. May be null if the anchors that
  /// define the highlight are not attached to the terminal.
  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }

  @override
  void dispose() {
    if (disposed) return;
    p1.dispose();
    p2.dispose();
    super.dispose();
  }
}
