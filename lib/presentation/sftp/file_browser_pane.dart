import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart' as desktop;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/entities/small_text_file.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../components/app_menu.dart';
import '../localization/app_translations.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'file_path_breadcrumb.dart';

enum FileBrowserSide { local, remote }

enum _FileSortField { name, size, modified }

class _FileToolbarAction {
  const _FileToolbarAction(
    this.id,
    this.label,
    this.icon,
    this.onPressed, {
    this.active = false,
  });

  final String id;
  final String label;
  final AppIcons icon;
  final VoidCallback? onPressed;
  final bool active;
}

class FileBrowserEntry {
  const FileBrowserEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.modified,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;

  static final _lowerNames = Expando<String>();
  String get lowerName => _lowerNames[this] ??= name.toLowerCase();

  bool sameContents(FileBrowserEntry other) =>
      path == other.path &&
      name == other.name &&
      isDir == other.isDir &&
      size == other.size &&
      modified == other.modified;
}

/// 仅用于本标签页两侧之间的文件拖放，携带拖动开始时的绝对路径。
class FileTransferDrag {
  const FileTransferDrag({
    required this.sessionId,
    required this.source,
    required this.path,
    required this.name,
    this.selectedFiles,
    this.isDirectory = false,
  });

  final String sessionId;
  final FileBrowserSide source;
  final String path;
  final String name;
  final List<FileBrowserEntry>? selectedFiles;
  final bool isDirectory;

  List<FileBrowserEntry> get files =>
      selectedFiles ??
      [FileBrowserEntry(name: name, path: path, isDir: isDirectory, size: 0)];
}

class FileBrowserPane extends StatefulWidget {
  const FileBrowserPane({
    required this.sessionId,
    required this.side,
    required this.cwd,
    required this.entries,
    required this.loading,
    required this.error,
    required this.onNavigate,
    required this.onRefresh,
    required this.onOpen,
    required this.onTransfer,
    required this.onDrop,
    this.onDismissError,
    this.onUp,
    this.onBrowse,
    this.onAuthorize,
    this.onUpload,
    this.onUploadDirectory,
    this.onMkdir,
    this.onRename,
    this.onDelete,
    this.onEditText,
    this.onMove,
    this.showHidden = false,
    this.onShowHiddenChanged,
    this.active = true,
    this.focusOnActivate = false,
    this.onExternalDrop,
    super.key,
  });

  final String sessionId;
  final FileBrowserSide side;
  final String cwd;
  final List<FileBrowserEntry> entries;
  final bool loading;
  final String? error;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRefresh;
  final VoidCallback? onDismissError;
  final ValueChanged<FileBrowserEntry> onOpen;
  final ValueChanged<List<FileBrowserEntry>> onTransfer;
  final void Function(FileTransferDrag data, String directory) onDrop;
  final VoidCallback? onUp;
  final VoidCallback? onBrowse;
  final VoidCallback? onAuthorize;
  final VoidCallback? onUpload;
  final VoidCallback? onUploadDirectory;
  final VoidCallback? onMkdir;
  final ValueChanged<FileBrowserEntry>? onRename;
  final ValueChanged<List<FileBrowserEntry>>? onDelete;
  final ValueChanged<FileBrowserEntry>? onEditText;
  final void Function(FileTransferDrag data, String directory)? onMove;
  final bool showHidden;
  final ValueChanged<bool>? onShowHiddenChanged;
  final bool active;
  final bool focusOnActivate;
  final void Function(List<desktop.DropItem> files, String directory)?
  onExternalDrop;

  @override
  State<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends State<FileBrowserPane> {
  static const _rowHeight = 34.0;

  final _selected = <String>{};
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _pathController = TextEditingController();
  final _pathFocus = FocusNode();
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode();
  late List<FileBrowserEntry> _sortedEntries;
  List<FileBrowserEntry>? _selectionSnapshot;
  _FileSortField? _sortField = _FileSortField.name;
  bool _sortAscending = true;
  bool _editingPath = false;
  bool _filtering = false;
  String _filterQuery = '';
  String? _anchor;
  int _focusedIndex = 0;
  int? _collapseSelectionPointer;
  String? _externalHoverPath;
  final _directoryDropKeys = <String, GlobalKey>{};
  final _fileListDropKey = GlobalKey();
  int? _selectionPointer;
  Offset? _selectionOrigin;
  Offset? _selectionPosition;
  Rect? _selectionRect;
  Set<String> _selectionBeforeDrag = {};
  String? _selectionAnchorBeforeDrag;
  int _selectionFocusBeforeDrag = 0;
  bool _selectionDragging = false;
  bool _selectionToggle = false;
  bool _selectionAdditive = false;
  Timer? _selectionScrollTimer;

  String get sessionId => widget.sessionId;
  FileBrowserSide get side => widget.side;
  String get cwd => widget.cwd;
  List<FileBrowserEntry> get entries => _sortedEntries;
  bool get loading => widget.loading;
  String? get error => widget.error;
  VoidCallback get onRefresh => widget.onRefresh;
  ValueChanged<FileBrowserEntry> get onOpen => widget.onOpen;
  ValueChanged<List<FileBrowserEntry>> get onTransfer => widget.onTransfer;
  void Function(FileTransferDrag, String) get onDrop => widget.onDrop;
  VoidCallback? get onBrowse => widget.onBrowse;
  VoidCallback? get onAuthorize => widget.onAuthorize;
  VoidCallback? get onUpload => widget.onUpload;
  VoidCallback? get onMkdir => widget.onMkdir;
  ValueChanged<FileBrowserEntry>? get onRename => widget.onRename;
  ValueChanged<List<FileBrowserEntry>>? get onDelete => widget.onDelete;

  bool get _canMkdir =>
      onMkdir != null && cwd.isNotEmpty && !loading && error == null;

  List<FileBrowserEntry> get _selectedEntries => _selected.isEmpty
      ? const []
      : _selectionSnapshot ??= List.unmodifiable([
          for (final entry in entries)
            if (_selected.contains(entry.path)) entry,
        ]);

  @override
  void initState() {
    super.initState();
    _rebuildSortedEntries();
    _scroll.addListener(_selectionScrolled);
    _focusListWhenActive();
  }

  void _focusListWhenActive() {
    if (!widget.active || !widget.focusOnActivate) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focus.requestFocus();
    });
  }

  void _rebuildSortedEntries() {
    _selectionSnapshot = null;
    final query = _filterQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List.of(widget.entries)
        : [
            for (final entry in widget.entries)
              if (entry.lowerName.contains(query)) entry,
          ];
    final field = _sortField;
    if (field == null) {
      _sortedEntries = filtered;
      return;
    }
    int compareByName(FileBrowserEntry a, FileBrowserEntry b) {
      final lower = a.lowerName.compareTo(b.lowerName);
      return lower != 0 ? lower : a.name.compareTo(b.name);
    }

    _sortedEntries = filtered
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        final result = switch (field) {
          _FileSortField.name => compareByName(a, b),
          _FileSortField.size =>
            a.size != b.size ? a.size.compareTo(b.size) : compareByName(a, b),
          _FileSortField.modified => () {
            final am = a.modified?.millisecondsSinceEpoch ?? -1;
            final bm = b.modified?.millisecondsSinceEpoch ?? -1;
            return am != bm ? am.compareTo(bm) : compareByName(a, b);
          }(),
        };
        return _sortAscending ? result : -result;
      });
  }

  void _openFilter() {
    if (loading) return;
    setState(() => _filtering = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _filtering) _filterFocus.requestFocus();
    });
  }

  void _closeFilter() {
    if (!_filtering && _filterQuery.isEmpty) return;
    setState(() {
      _filtering = false;
      _filterQuery = '';
      _filterController.clear();
      _rebuildSortedEntries();
      final paths = _sortedEntries.map((entry) => entry.path).toSet();
      _selected.removeWhere((path) => !paths.contains(path));
      if (!paths.contains(_anchor)) _anchor = null;
    });
    _focus.requestFocus();
  }

  void _updateFilter(String value) {
    setState(() {
      _filterQuery = value;
      _rebuildSortedEntries();
      final paths = _sortedEntries.map((entry) => entry.path).toSet();
      _selected.removeWhere((path) => !paths.contains(path));
      if (!paths.contains(_anchor)) _anchor = null;
      _focusedIndex = 0;
    });
  }

  void _copyText(String text) {
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    AppNotice.success('已复制'.tr);
  }

  void _toggleSort(_FileSortField field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == _FileSortField.name;
      }
      _rebuildSortedEntries();
      if (_anchor != null) {
        final index = _sortedEntries.indexWhere((e) => e.path == _anchor);
        if (index >= 0) _focusedIndex = index;
      }
    });
  }

  void _startPathEdit() {
    if (loading || cwd.isEmpty) return;
    setState(() {
      _editingPath = true;
      _pathController.value = TextEditingValue(
        text: cwd,
        selection: TextSelection(baseOffset: 0, extentOffset: cwd.length),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingPath) _pathFocus.requestFocus();
    });
  }

  void _submitPathEdit() {
    final target = _pathController.text.trim();
    setState(() => _editingPath = false);
    _focus.requestFocus();
    if (target.isNotEmpty && target != cwd) {
      widget.onNavigate(target);
    }
  }

  void _cancelPathEdit() {
    if (!_editingPath) return;
    setState(() => _editingPath = false);
    _focus.requestFocus();
  }

  RenderBox? get _selectionViewport {
    final box = _fileListDropKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  void _beginSelection(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton ||
        !widget.active ||
        loading ||
        error != null ||
        _selectionPointer != null) {
      return;
    }
    final box = _selectionViewport;
    if (box == null) return;
    final local = box.globalToLocal(event.position);
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final inRow =
        local.dx >= AppTheme.fileSelectionGutter &&
        local.dx < box.size.width - AppTheme.fileSelectionGutter &&
        local.dy + offset < entries.length * _rowHeight;
    // 条目上的拖动仍由 Draggable 发起文件传输；空白处才开始框选。
    if (inRow) return;
    // 有滚动条时让出右侧的命中区域，避免拖动滚动条触发框选。
    if (_scroll.hasClients &&
        _scroll.position.maxScrollExtent > 0 &&
        local.dx >= box.size.width - AppTheme.fileSelectionGutter) {
      return;
    }
    _focus.requestFocus();
    final keyboard = HardwareKeyboard.instance;
    setState(() {
      _selectionPointer = event.pointer;
      _selectionOrigin = local + Offset(0, offset);
      _selectionPosition = event.position;
      _selectionBeforeDrag = Set.of(_selected);
      _selectionAnchorBeforeDrag = _anchor;
      _selectionFocusBeforeDrag = _focusedIndex;
      _selectionToggle = keyboard.isMetaPressed || keyboard.isControlPressed;
      _selectionAdditive = keyboard.isShiftPressed;
      if (!_selectionToggle && !_selectionAdditive) {
        _selected.clear();
        _selectionSnapshot = null;
        _anchor = null;
      }
    });
  }

  void _moveSelection(PointerMoveEvent event) {
    if (_selectionPointer != event.pointer) return;
    final box = _selectionViewport;
    final origin = _selectionOrigin;
    if (box == null || origin == null) return;
    _selectionPosition = event.position;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final point = box.globalToLocal(event.position) + Offset(0, offset);
    if (!_selectionDragging &&
        (point - origin).distance < AppTheme.fileSelectionDragThreshold) {
      return;
    }
    setState(() {
      _selectionDragging = true;
      _updateSelectionRect();
    });
    _updateSelectionScrolling();
  }

  void _updateSelectionRect() {
    final box = _selectionViewport;
    final origin = _selectionOrigin;
    final position = _selectionPosition;
    if (box == null || origin == null || position == null) return;
    final local = box.globalToLocal(position);
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final point = Offset(
      local.dx.clamp(0.0, box.size.width),
      local.dy.clamp(0.0, box.size.height) + offset,
    );
    final rect = Rect.fromPoints(origin, point);
    _selectionRect = rect;
    final hits = <String>{};
    if (rect.width > 0 &&
        rect.height > 0 &&
        rect.right > AppTheme.fileSelectionGutter &&
        rect.left < box.size.width - AppTheme.fileSelectionGutter) {
      final first = (rect.top / _rowHeight).floor().clamp(0, entries.length);
      final end = (rect.bottom / _rowHeight).ceil().clamp(0, entries.length);
      for (var index = first; index < end; index++) {
        hits.add(entries[index].path);
      }
    }
    final selection = _selectionToggle
        ? _selectionBeforeDrag
              .difference(hits)
              .union(hits.difference(_selectionBeforeDrag))
        : _selectionAdditive
        ? _selectionBeforeDrag.union(hits)
        : hits;
    _selected
      ..clear()
      ..addAll(selection);
    _selectionSnapshot = null;
  }

  void _selectionScrolled() {
    if (mounted && _selectionDragging) setState(_updateSelectionRect);
  }

  double _selectionScrollDelta() {
    final box = _selectionViewport;
    final position = _selectionPosition;
    if (!_selectionDragging ||
        !_scroll.hasClients ||
        box == null ||
        position == null) {
      return 0;
    }
    final point = box.globalToLocal(position);
    if (point.dx < 0 || point.dx > box.size.width) return 0;
    const edge = AppTheme.fileSelectionEdgeExtent;
    final delta = point.dy < edge
        ? point.dy - edge
        : point.dy > box.size.height - edge
        ? point.dy - (box.size.height - edge)
        : 0.0;
    final scroll = _scroll.position;
    if ((delta < 0 && scroll.pixels <= scroll.minScrollExtent) ||
        (delta > 0 && scroll.pixels >= scroll.maxScrollExtent)) {
      return 0;
    }
    return delta.clamp(-edge, edge);
  }

  void _updateSelectionScrolling() {
    if (_selectionScrollDelta() == 0) {
      _selectionScrollTimer?.cancel();
      _selectionScrollTimer = null;
      return;
    }
    _selectionScrollTimer ??= Timer.periodic(
      AppTheme.fileSelectionScrollInterval,
      (_) {
        final delta = _selectionScrollDelta();
        if (!mounted || delta == 0) {
          _selectionScrollTimer?.cancel();
          _selectionScrollTimer = null;
          return;
        }
        final position = _scroll.position;
        _scroll.jumpTo(
          (position.pixels + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      },
    );
  }

  void _resetSelectionDrag() {
    _selectionScrollTimer?.cancel();
    _selectionScrollTimer = null;
    _selectionPointer = null;
    _selectionOrigin = null;
    _selectionPosition = null;
    _selectionRect = null;
    _selectionBeforeDrag = {};
    _selectionAnchorBeforeDrag = null;
    _selectionDragging = false;
  }

  void _endSelection(PointerUpEvent event) {
    if (_selectionPointer != event.pointer) return;
    setState(() {
      if (_selectionDragging && _selected.isNotEmpty) {
        _focusedIndex = entries.lastIndexWhere(
          (entry) => _selected.contains(entry.path),
        );
        _anchor = entries
            .firstWhere((entry) => _selected.contains(entry.path))
            .path;
      }
      _resetSelectionDrag();
    });
  }

  void _cancelSelection(PointerCancelEvent event) {
    if (_selectionPointer != event.pointer) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(_selectionBeforeDrag);
      _selectionSnapshot = null;
      _anchor = _selectionAnchorBeforeDrag;
      _focusedIndex = _selectionFocusBeforeDrag;
      _resetSelectionDrag();
    });
  }

  @override
  void didUpdateWidget(FileBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active || oldWidget.sessionId != sessionId) {
      _focusListWhenActive();
    }
    final directoryChanged =
        oldWidget.cwd != cwd || oldWidget.sessionId != sessionId;
    final entriesChanged =
        !identical(oldWidget.entries, widget.entries) &&
        (oldWidget.entries.length != widget.entries.length ||
            oldWidget.entries.indexed.any(
              (item) => !item.$2.sameContents(widget.entries[item.$1]),
            ));
    if (!widget.active ||
        loading ||
        error != null ||
        directoryChanged ||
        entriesChanged) {
      _resetSelectionDrag();
    }
    if (!widget.active || loading || error != null || oldWidget.cwd != cwd) {
      _externalHoverPath = null;
    }
    if (directoryChanged) {
      _editingPath = false;
      _filtering = false;
      _filterQuery = '';
      _filterController.clear();
      _selected.clear();
      _anchor = null;
      _focusedIndex = 0;
      _collapseSelectionPointer = null;
      final directory = cwd;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && cwd == directory && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
    if (entriesChanged || directoryChanged) {
      _rebuildSortedEntries();
      if (!directoryChanged) {
        final paths = entries.map((entry) => entry.path).toSet();
        _selected.removeWhere((path) => !paths.contains(path));
        if (!paths.contains(_anchor)) _anchor = null;
      }
      final directories = {
        for (final entry in entries)
          if (entry.isDir) entry.path,
      };
      _directoryDropKeys.removeWhere((path, _) => !directories.contains(path));
    }
  }

  @override
  void dispose() {
    _resetSelectionDrag();
    _pathController.dispose();
    _pathFocus.dispose();
    _filterController.dispose();
    _filterFocus.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _select(FileBrowserEntry entry, {bool? range, bool? additive}) {
    if (loading) return;
    final index = entries.indexWhere((item) => item.path == entry.path);
    if (index < 0) return;
    _focus.requestFocus();
    final keyboard = HardwareKeyboard.instance;
    final extend = range ?? keyboard.isShiftPressed;
    final toggle =
        additive ?? (keyboard.isMetaPressed || keyboard.isControlPressed);
    setState(() {
      _selectionSnapshot = null;
      final anchor = entries.indexWhere((item) => item.path == _anchor);
      _focusedIndex = index;
      if (extend && anchor >= 0) {
        if (!toggle) _selected.clear();
        final start = anchor < index ? anchor : index;
        final end = anchor > index ? anchor : index;
        _selected.addAll(
          entries.sublist(start, end + 1).map((item) => item.path),
        );
      } else {
        if (!toggle) _selected.clear();
        if (toggle && _selected.contains(entry.path)) {
          _selected.remove(entry.path);
        } else {
          _selected.add(entry.path);
        }
        _anchor = entry.path;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final top = _focusedIndex * _rowHeight;
      final position = _scroll.position;
      final bottom = top + _rowHeight;
      final offset = top < position.pixels
          ? top
          : bottom > position.pixels + position.viewportDimension
          ? bottom - position.viewportDimension
          : position.pixels;
      _scroll.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
    });
  }

  List<FileBrowserEntry> _filesFor(FileBrowserEntry entry) =>
      _selected.contains(entry.path) ? _selectedEntries : [entry];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_editingPath || _pathFocus.hasFocus || _filterFocus.hasFocus) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!widget.active || loading) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final primary = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (event is KeyRepeatEvent &&
        (key == LogicalKeyboardKey.f5 ||
            key == LogicalKeyboardKey.f2 ||
            key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            (keyboard.isMetaPressed && key == LogicalKeyboardKey.backspace) ||
            (primary && key == LogicalKeyboardKey.keyR))) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5 ||
        (primary && key == LogicalKeyboardKey.keyR)) {
      onRefresh();
      return KeyEventResult.handled;
    }
    if (primary && key == LogicalKeyboardKey.keyL) {
      _startPathEdit();
      return KeyEventResult.handled;
    }
    if (primary && key == LogicalKeyboardKey.keyF) {
      _openFilter();
      return KeyEventResult.handled;
    }
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final toggleHidden = isMac
        ? keyboard.isMetaPressed &&
              keyboard.isShiftPressed &&
              key == LogicalKeyboardKey.period
        : keyboard.isControlPressed &&
              !keyboard.isShiftPressed &&
              key == LogicalKeyboardKey.keyH;
    final showHiddenChanged = widget.onShowHiddenChanged;
    if (toggleHidden && showHiddenChanged != null) {
      if (event is KeyDownEvent) showHiddenChanged(!widget.showHidden);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        (keyboard.isMetaPressed && key == LogicalKeyboardKey.backspace)) {
      if (_selectedEntries.isNotEmpty && onDelete != null) {
        onDelete!(_selectedEntries);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.backspace &&
        !primary &&
        widget.onUp != null) {
      widget.onUp!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2 &&
        _selectedEntries.length == 1 &&
        onRename != null) {
      onRename!(_selectedEntries.single);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _filtering) {
      _closeFilter();
      return KeyEventResult.handled;
    }
    if (entries.isEmpty) return KeyEventResult.ignored;
    if (primary && key == LogicalKeyboardKey.keyA) {
      setState(() {
        _selected.addAll(entries.map((entry) => entry.path));
        _selectionSnapshot = null;
        _anchor ??= entries.first.path;
      });
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _resetSelectionDrag();
        _selected.clear();
        _selectionSnapshot = null;
        _anchor = null;
      });
    } else if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        _selectedEntries.length == 1) {
      final entry = _selectedEntries.single;
      if (entry.isDir) {
        onOpen(entry);
      } else {
        onTransfer([entry]);
      }
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      final current = _selected.isEmpty ? 0 : _focusedIndex;
      final pageRows = _scroll.hasClients
          ? (_scroll.position.viewportDimension / _rowHeight).floor().clamp(
              1,
              entries.length,
            )
          : 1;
      final next = switch (key) {
        LogicalKeyboardKey.home => 0,
        LogicalKeyboardKey.end => entries.length - 1,
        LogicalKeyboardKey.arrowDown => _selected.isEmpty ? 0 : current + 1,
        LogicalKeyboardKey.pageDown => current + pageRows,
        LogicalKeyboardKey.pageUp => current - pageRows,
        _ => current - 1,
      };
      _select(entries[next.clamp(0, entries.length - 1)], additive: false);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _filterKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final escape = key == LogicalKeyboardKey.escape;
    if (!escape &&
        key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (!_filterController.value.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (event is KeyDownEvent) {
      if (escape) {
        _closeFilter();
      } else if (_selected.isEmpty && entries.isNotEmpty) {
        _select(entries.first, range: false, additive: false);
      } else {
        _focus.requestFocus();
      }
    }
    return KeyEventResult.handled;
  }

  bool _accepts(FileTransferDrag data) =>
      !loading &&
      error == null &&
      cwd.isNotEmpty &&
      data.sessionId == sessionId &&
      data.source != side;

  bool _acceptsDirectory(FileTransferDrag data, FileBrowserEntry directory) {
    if (_accepts(data)) return true;
    if (widget.onMove == null ||
        loading ||
        error != null ||
        data.sessionId != sessionId ||
        data.source != side) {
      return false;
    }
    final paths = side == FileBrowserSide.remote ? p.posix : p.context;
    return data.files.every(
      (entry) =>
          !paths.equals(entry.path, directory.path) &&
          !paths.equals(paths.dirname(entry.path), directory.path) &&
          (!entry.isDir || !paths.isWithin(entry.path, directory.path)),
    );
  }

  String _externalDirectory(Offset position) {
    final viewport = _fileListDropKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox ||
        !viewport.hasSize ||
        !viewport.paintBounds.contains(viewport.globalToLocal(position))) {
      return cwd;
    }
    for (final entry in _directoryDropKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          box.paintBounds.contains(box.globalToLocal(position))) {
        return entry.key;
      }
    }
    return cwd;
  }

  void _setExternalHover(String? path) {
    if (_externalHoverPath == path) return;
    setState(() => _externalHoverPath = path);
  }

  List<_FileToolbarAction> _toolbarActions() {
    final local = side == FileBrowserSide.local;
    final canTransfer = !loading && error == null;
    return [
      if (widget.onUploadDirectory != null)
        _FileToolbarAction(
          'upload-directory',
          '上传文件夹'.tr,
          AppIcons.folderUp,
          canTransfer ? widget.onUploadDirectory : null,
        ),
      if (onUpload != null)
        _FileToolbarAction(
          'upload-file',
          '上传文件'.tr,
          AppIcons.fileUp,
          canTransfer ? onUpload : null,
        ),
      if (onBrowse != null)
        _FileToolbarAction(
          'browse',
          '选择本地目录'.tr,
          AppIcons.folderOpen,
          onBrowse,
        ),
      if (onMkdir != null)
        _FileToolbarAction(
          'new-folder',
          '新建目录'.tr,
          AppIcons.folderPlus,
          _canMkdir ? onMkdir : null,
        ),
      _FileToolbarAction('refresh', '刷新'.tr, AppIcons.refreshCw, onRefresh),
      _FileToolbarAction(
        'transfer-selected',
        (local ? '上传所选文件' : '下载所选文件').tr,
        local ? AppIcons.upload : AppIcons.download,
        canTransfer && _selectedEntries.isNotEmpty
            ? () => onTransfer(_selectedEntries)
            : null,
      ),
      _FileToolbarAction(
        'filter-toggle',
        '筛选当前目录'.tr,
        AppIcons.search,
        loading ? null : (_filtering ? _closeFilter : _openFilter),
        active: _filtering,
      ),
      _FileToolbarAction(
        'edit-path',
        '输入路径'.tr,
        AppIcons.pencil,
        loading || cwd.isEmpty || _editingPath ? null : _startPathEdit,
      ),
    ];
  }

  double _toolbarTextWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  Widget _toolbarRow(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    final colors = theme.colorScheme;
    final iconColor = colors.mutedForeground;
    final disabledIconColor = iconColor.withValues(alpha: 0.55);
    final local = side == FileBrowserSide.local;
    final title = (local ? '本地文件' : '远程文件').tr;
    const titleStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    final hiddenLabel = '隐藏文件'.tr;
    final hiddenStyle = TextStyle(fontSize: 11, color: colors.mutedForeground);
    final showHiddenChanged = widget.onShowHiddenChanged;
    final actions = _toolbarActions();
    return SizedBox(
      height: AppTheme.fileBrowserToolbarRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final compact = width < AppTheme.fileToolbarCompactWidth;
            final density = compact
                ? shadcn.ButtonDensity.iconDense
                : shadcn.ButtonDensity.icon;
            final buttonSize = compact
                ? AppTheme.fileToolbarCompactButtonSize
                : AppTheme.fileToolbarButtonSize;
            final switchWidth = 36 * theme.scaling;
            final badgeWidth = AppTheme.fileToolbarBadgeWidth * theme.scaling;
            final showTitleIcon = width >= 120;
            final gap = showTitleIcon ? 8.0 : 4.0;
            const titleIconSize = 15.0;
            final reservedWidth =
                _toolbarTextWidth(context, title, titleStyle) +
                gap +
                (showTitleIcon ? titleIconSize + gap : 0) +
                (showHiddenChanged != null ? switchWidth + gap : 0);
            final actionWidth = width - reservedWidth;
            final slots = (actionWidth / buttonSize).floor().clamp(
              1,
              actions.length,
            );
            final directCount = slots == actions.length ? slots : slots - 1;
            final overflow = actions.skip(directCount).toList();
            final detailWidth = actionWidth - actions.length * buttonSize;
            final hiddenLabelWidth =
                _toolbarTextWidth(context, hiddenLabel, hiddenStyle) + gap;
            final showHiddenLabel =
                showHiddenChanged != null && detailWidth >= hiddenLabelWidth;
            final showBadge =
                !local &&
                detailWidth - (showHiddenLabel ? hiddenLabelWidth : 0) >=
                    badgeWidth + gap;
            return Row(
              children: [
                if (showTitleIcon) ...[
                  AppIcon(
                    local ? AppIcons.monitor : AppIcons.server,
                    size: titleIconSize,
                    color: iconColor,
                  ),
                  SizedBox(width: gap),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                SizedBox(width: gap),
                for (final action in actions.take(directCount))
                  SizedBox.square(
                    dimension: buttonSize,
                    child: AppIconButton(
                      key: ValueKey('sftp-${side.name}-${action.id}'),
                      semanticLabel: action.label,
                      tooltip: action.label,
                      density: density,
                      icon: AppIcon(
                        action.icon,
                        size: 16,
                        color: action.onPressed == null
                            ? disabledIconColor
                            : action.active
                            ? colors.foreground
                            : iconColor,
                      ),
                      onPressed: action.onPressed,
                    ),
                  ),
                if (overflow.isNotEmpty)
                  SizedBox.square(
                    dimension: buttonSize,
                    child: AppMenuButton<_FileToolbarAction>(
                      key: ValueKey('sftp-${side.name}-toolbar-overflow'),
                      semanticLabel: '更多文件操作'.tr,
                      tooltip: '更多文件操作'.tr,
                      density: density,
                      icon: AppIcon(
                        AppIcons.ellipsis,
                        size: 16,
                        color: iconColor,
                      ),
                      items: [
                        for (final action in overflow) (action, action.label),
                      ],
                      icons: {
                        for (final action in overflow) action: action.icon,
                      },
                      disabledValues: {
                        for (final action in overflow)
                          if (action.onPressed == null) action,
                      },
                      onSelected: (action) => action.onPressed?.call(),
                    ),
                  ),
                if (showBadge) ...[
                  SizedBox(width: gap),
                  SizedBox(
                    width: badgeWidth,
                    child: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: shadcn.OutlineBadge(child: Text('SFTP')),
                    ),
                  ),
                ],
                if (showHiddenChanged != null) ...[
                  SizedBox(width: gap),
                  if (showHiddenLabel) ...[
                    Text(hiddenLabel, style: hiddenStyle),
                    SizedBox(width: gap),
                  ],
                  shadcn.Tooltip(
                    tooltip: (_) =>
                        shadcn.TooltipContainer(child: Text('显示隐藏文件'.tr)),
                    child: Semantics(
                      label: '显示隐藏文件'.tr,
                      child: shadcn.Switch(
                        value: widget.showHidden,
                        onChanged: showHiddenChanged,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _pathRow() => SizedBox(
    height: AppTheme.fileBrowserToolbarRowHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: _editingPath
          ? TapRegion(
              onTapOutside: (_) => _cancelPathEdit(),
              child: Row(
                children: [
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape):
                            _cancelPathEdit,
                      },
                      child: shadcn.TextField(
                        key: ValueKey('sftp-${side.name}-path-input'),
                        controller: _pathController,
                        focusNode: _pathFocus,
                        filled: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        style: const TextStyle(fontSize: 12),
                        onSubmitted: (_) => _submitPathEdit(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AppIconButton(
                    key: ValueKey('sftp-${side.name}-path-submit'),
                    semanticLabel: '前往路径'.tr,
                    tooltip: '前往路径'.tr,
                    density: shadcn.ButtonDensity.compact,
                    icon: const AppIcon(AppIcons.check, size: 15),
                    onPressed: _submitPathEdit,
                  ),
                  AppIconButton(
                    key: ValueKey('sftp-${side.name}-path-cancel'),
                    semanticLabel: '取消编辑路径'.tr,
                    tooltip: '取消编辑路径'.tr,
                    density: shadcn.ButtonDensity.compact,
                    icon: const AppIcon(AppIcons.x, size: 15),
                    onPressed: _cancelPathEdit,
                  ),
                ],
              ),
            )
          : FilePathBreadcrumb(
              path: cwd,
              remote: side == FileBrowserSide.remote,
              onNavigate: loading ? null : widget.onNavigate,
              onTapEmpty: loading || cwd.isEmpty ? null : _startPathEdit,
            ),
    ),
  );

  Widget _fileList(BuildContext context) => LayoutBuilder(
    key: _fileListDropKey,
    builder: (context, constraints) {
      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
      final rect = _selectionRect
          ?.shift(Offset(0, -offset))
          .intersect(Offset.zero & constraints.biggest);
      final colors = shadcn.Theme.of(context).colorScheme;
      final showSize =
          constraints.maxWidth >= AppTheme.fileSizeColumnMinPaneWidth;
      final showModified =
          constraints.maxWidth >= AppTheme.fileModifiedColumnMinPaneWidth;
      final emptyAreaActions = <(String, String)>[
        ('refresh', '刷新'.tr),
        if (_canMkdir) ('mkdir', '新建目录'.tr),
        if (cwd.isNotEmpty) ('copy-cwd', '复制当前路径'.tr),
      ];
      return _FileContextMenu(
        enabled: !loading && emptyAreaActions.isNotEmpty,
        items: appMenuItems<String>(
          emptyAreaActions,
          (value) {
            switch (value) {
              case 'refresh':
                onRefresh();
              case 'mkdir':
                onMkdir?.call();
              case 'copy-cwd':
                _copyText(cwd);
            }
          },
          icons: const {
            'refresh': AppIcons.refreshCw,
            'mkdir': AppIcons.folderPlus,
            'copy-cwd': AppIcons.folderMarker,
          },
        ),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _beginSelection,
          onPointerMove: _moveSelection,
          onPointerUp: _endSelection,
          onPointerCancel: _cancelSelection,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              if (loading)
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: shadcn.CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (entries.isEmpty)
                Center(
                  child: Text(
                    (_filterQuery.trim().isNotEmpty ? '无匹配文件' : '空目录').tr,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                    ),
                  ),
                )
              else
                ListView.builder(
                  key: ValueKey('sftp-${side.name}-file-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.fileSelectionGutter,
                  ),
                  itemExtent: _rowHeight,
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(
                    context,
                    entries[index],
                    showSize: showSize,
                    showModified: showModified,
                  ),
                ),
              if (rect != null && !rect.isEmpty)
                Positioned.fromRect(
                  rect: rect,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: ValueKey('sftp-${side.name}-selection-box'),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final pane = Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (!focused && _selectionPointer != null) {
          setState(_resetSelectionDrag);
        }
      },
      onKeyEvent: _onKeyEvent,
      child: DragTarget<FileTransferDrag>(
        onWillAcceptWithDetails: (details) => _accepts(details.data),
        onAcceptWithDetails: (details) => onDrop(details.data, cwd),
        builder: (context, candidates, rejected) => Container(
          key: ValueKey('sftp-${side.name}-pane'),
          decoration: BoxDecoration(
            color: candidates.isEmpty && _externalHoverPath != cwd
                ? AppTheme.surface(context)
                : colors.primary.withValues(alpha: 0.08),
            border: Border.all(
              color: candidates.isEmpty && _externalHoverPath != cwd
                  ? shadcn.Colors.transparent
                  : colors.primary,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbarRow(context),
              _pathRow(),
              const shadcn.Divider(),
              if (_filtering)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppTheme.border(context)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Focus(
                          canRequestFocus: false,
                          onKeyEvent: _filterKey,
                          child: shadcn.TextField(
                            key: ValueKey('sftp-${side.name}-filter'),
                            controller: _filterController,
                            focusNode: _filterFocus,
                            filled: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            style: const TextStyle(fontSize: 12),
                            placeholder: Text(
                              '筛选当前目录文件…'.tr,
                              style: const TextStyle(fontSize: 12),
                            ),
                            features: const [
                              shadcn.InputFeature.leading(
                                AppIcon(AppIcons.search, size: 13),
                              ),
                            ],
                            onChanged: _updateFilter,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      AppIconButton(
                        key: ValueKey('sftp-${side.name}-filter-clear'),
                        semanticLabel: '关闭筛选'.tr,
                        tooltip: '关闭筛选'.tr,
                        density: shadcn.ButtonDensity.compact,
                        icon: const AppIcon(AppIcons.x, size: 14),
                        onPressed: _closeFilter,
                      ),
                    ],
                  ),
                ),
              SizedBox(
                height: 26,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final showSize =
                        constraints.maxWidth >=
                        AppTheme.fileSizeColumnMinPaneWidth;
                    final showModified =
                        constraints.maxWidth >=
                        AppTheme.fileModifiedColumnMinPaneWidth;
                    return Padding(
                      padding: const EdgeInsets.only(left: 35, right: 12),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.mutedForeground,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _sortHeader(
                                context,
                                _FileSortField.name,
                                '名称'.tr,
                                tooltip: '按名称排序'.tr,
                              ),
                            ),
                            if (showSize)
                              SizedBox(
                                width: AppTheme.fileSizeColumnWidth,
                                child: _sortHeader(
                                  context,
                                  _FileSortField.size,
                                  '大小'.tr,
                                  tooltip: '按大小排序'.tr,
                                  alignRight: true,
                                ),
                              ),
                            if (showModified) ...[
                              const SizedBox(width: 12),
                              SizedBox(
                                width: AppTheme.fileModifiedColumnWidth,
                                child: _sortHeader(
                                  context,
                                  _FileSortField.modified,
                                  '更新时间'.tr,
                                  tooltip: '按更新时间排序'.tr,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          AppTranslations.error(error!),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.destructive,
                          ),
                        ),
                      ),
                      if (onAuthorize != null) ...[
                        const SizedBox(width: 8),
                        shadcn.OutlineButton(
                          onPressed: onAuthorize,
                          child: Text('授权访问'.tr),
                        ),
                      ],
                      const SizedBox(width: 4),
                      AppIconButton(
                        key: ValueKey('sftp-${side.name}-error-retry'),
                        semanticLabel: '重试'.tr,
                        tooltip: '重试'.tr,
                        onPressed: loading ? null : onRefresh,
                        icon: AppIcon(
                          AppIcons.rotateCw,
                          size: 14,
                          color: colors.mutedForeground,
                        ),
                      ),
                      if (widget.onDismissError != null)
                        AppIconButton(
                          key: ValueKey('sftp-${side.name}-error-dismiss'),
                          semanticLabel: '关闭提示'.tr,
                          tooltip: '关闭提示'.tr,
                          onPressed: widget.onDismissError,
                          icon: AppIcon(
                            AppIcons.x,
                            size: 14,
                            color: colors.mutedForeground,
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(child: _fileList(context)),
              if (_selectedEntries.isNotEmpty && !loading && error == null)
                _selectionBar(context),
            ],
          ),
        ),
      ),
    );
    if (side != FileBrowserSide.remote || widget.onExternalDrop == null) {
      return pane;
    }
    // 原生事件绕过 Flutter 命中测试，必须显式禁用后台标签和弹框下的区域。
    final enabled =
        widget.active &&
        !loading &&
        error == null &&
        cwd.isNotEmpty &&
        (ModalRoute.isCurrentOf(context) ?? true);
    return desktop.DropTarget(
      enable: enabled,
      onDragEntered: (details) =>
          _setExternalHover(_externalDirectory(details.globalPosition)),
      onDragUpdated: (details) =>
          _setExternalHover(_externalDirectory(details.globalPosition)),
      onDragExited: (_) => _setExternalHover(null),
      onDragDone: (details) {
        final directory = _externalDirectory(details.globalPosition);
        _setExternalHover(null);
        if (enabled) widget.onExternalDrop!(details.files, directory);
      },
      child: pane,
    );
  }

  Widget _sortHeader(
    BuildContext context,
    _FileSortField field,
    String label, {
    required String tooltip,
    bool alignRight = false,
  }) {
    final active = _sortField == field;
    final colors = shadcn.Theme.of(context).colorScheme;
    final labelColor = active ? colors.foreground : colors.mutedForeground;
    return shadcn.Tooltip(
      tooltip: (_) => shadcn.TooltipContainer(child: Text(tooltip)),
      child: Semantics(
        button: true,
        label: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('sftp-${side.name}-sort-${field.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: loading ? null : () => _toggleSort(field),
            child: Row(
              mainAxisAlignment: alignRight
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: labelColor,
                    ),
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 2),
                  AppIcon(
                    _sortAscending ? AppIcons.chevronUp : AppIcons.chevronDown,
                    size: 12,
                    color: labelColor,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionBar(BuildContext context) {
    final selected = _selectedEntries;
    final colors = shadcn.Theme.of(context).colorScheme;
    final hasFile = selected.any((entry) => !entry.isDir);
    final totalSize = selected.fold<int>(
      0,
      (sum, entry) => sum + (entry.isDir ? 0 : entry.size),
    );
    final summary = '已选 @count 项'.trParams({'count': '${selected.length}'});
    return Container(
      key: ValueKey('sftp-${side.name}-selection-bar'),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppTheme.sidebar(context),
        border: Border(top: BorderSide(color: AppTheme.border(context))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hasFile ? '$summary · ${formatFileSize(totalSize)}' : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ),
          AppIconButton(
            key: ValueKey('sftp-${side.name}-selection-clear'),
            semanticLabel: '取消选择'.tr,
            tooltip: '取消选择'.tr,
            density: shadcn.ButtonDensity.compact,
            icon: const AppIcon(AppIcons.x, size: 14),
            onPressed: () => setState(() {
              _selected.clear();
              _selectionSnapshot = null;
              _anchor = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    FileBrowserEntry entry, {
    required bool showSize,
    required bool showModified,
  }) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final selected = _selected.contains(entry.path);
    final selectedForeground = AppTheme.fileSelectionForeground(context);
    final targets = _filesFor(entry);
    final multi = targets.length > 1;
    final actions = [
      if (entry.isDir && !multi) ('open', '打开'.tr),
      if (!multi &&
          !entry.isDir &&
          entry.size <= smallTextFileByteLimit &&
          widget.onEditText != null)
        ('edit-text', '查看／编辑文本'.tr),
      (
        side == FileBrowserSide.local ? 'upload' : 'download',
        (side == FileBrowserSide.local ? '上传' : '下载').tr,
      ),
      if (!multi && onRename != null) ('rename', '重命名'.tr),
      ('copy-path', '复制路径'.tr),
      if (!multi) ('copy-name', '复制名称'.tr),
      if (onDelete != null) ('delete', '删除'.tr),
    ];
    void action(String value) {
      switch (value) {
        case 'open':
          onOpen(entry);
        case 'edit-text':
          widget.onEditText?.call(entry);
        case 'upload':
        case 'download':
          onTransfer(_filesFor(entry));
        case 'rename':
          onRename?.call(entry);
        case 'copy-path':
          _copyText(_filesFor(entry).map((item) => item.path).join('\n'));
        case 'copy-name':
          _copyText(entry.name);
        case 'delete':
          onDelete?.call(_filesFor(entry));
      }
    }

    final row = Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryMouseButton) {
          final keyboard = HardwareKeyboard.instance;
          if (_selected.contains(entry.path) &&
              !keyboard.isControlPressed &&
              !keyboard.isMetaPressed &&
              !keyboard.isShiftPressed) {
            // 已选中的整组保留到拖拽开始；普通点击在松开时收为单项。
            _collapseSelectionPointer = event.pointer;
            _focus.requestFocus();
          } else {
            _collapseSelectionPointer = null;
            _select(entry);
          }
        } else if (event.buttons == kSecondaryMouseButton &&
            !_selected.contains(entry.path)) {
          _select(entry, range: false, additive: false);
        }
      },
      onPointerUp: (event) {
        if (_collapseSelectionPointer == event.pointer) {
          _collapseSelectionPointer = null;
          _select(entry, range: false, additive: false);
        }
      },
      onPointerCancel: (event) {
        if (_collapseSelectionPointer == event.pointer) {
          _collapseSelectionPointer = null;
        }
      },
      child: _FileContextMenu(
        items: appMenuItems(
          actions,
          action,
          icons: const {
            'edit-text': AppIcons.fileText,
            'copy-path': AppIcons.link,
            'copy-name': AppIcons.letterCase,
          },
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 消费单击，避免列表空白区的手势在双击判定后清空选择。
          onTap: () {},
          onDoubleTap: () {
            final keyboard = HardwareKeyboard.instance;
            if (keyboard.isControlPressed ||
                keyboard.isMetaPressed ||
                keyboard.isShiftPressed) {
              return;
            } else if (entry.isDir) {
              onOpen(entry);
            } else {
              onTransfer([entry]);
            }
          },
          child: AppSurfaceAction(
            key: ValueKey('sftp-${side.name}-row-${entry.path}'),
            selected: selected,
            selectedColor: AppTheme.fileSelectionBackground(context),
            disableTransition: true,
            child: SizedBox(
              height: _rowHeight,
              child: Row(
                children: [
                  const SizedBox(width: 12 - AppTheme.fileSelectionGutter),
                  AppIcon(
                    entry.isDir ? AppIcons.folder : AppIcons.file,
                    size: 15,
                    color: selected
                        ? selectedForeground
                        : entry.isDir
                        ? colors.primary
                        : colors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: selected
                            ? selectedForeground
                            : colors.foreground,
                      ),
                    ),
                  ),
                  if (showSize)
                    SizedBox(
                      width: AppTheme.fileSizeColumnWidth,
                      child: Text(
                        entry.isDir ? '—' : formatFileSize(entry.size),
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? selectedForeground
                              : colors.mutedForeground,
                        ),
                      ),
                    ),
                  if (showModified) ...[
                    const SizedBox(width: 12),
                    SizedBox(
                      width: AppTheme.fileModifiedColumnWidth,
                      child: Text(
                        formatFileModified(entry.modified),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? selectedForeground
                              : colors.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12 - AppTheme.fileSelectionGutter),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final draggableRow = entry.isDir
        ? DragTarget<FileTransferDrag>(
            onWillAcceptWithDetails: (details) =>
                _acceptsDirectory(details.data, entry),
            onAcceptWithDetails: (details) {
              if (details.data.source == side) {
                widget.onMove?.call(details.data, entry.path);
              } else {
                onDrop(details.data, entry.path);
              }
            },
            builder: (context, candidates, rejected) => ColoredBox(
              key: _directoryDropKeys.putIfAbsent(entry.path, GlobalKey.new),
              color: candidates.isEmpty && _externalHoverPath != entry.path
                  ? shadcn.Colors.transparent
                  : colors.primary.withValues(alpha: 0.16),
              child: row,
            ),
          )
        : row;
    return Draggable<FileTransferDrag>(
      key: ValueKey('sftp-${side.name}-${entry.path}'),
      maxSimultaneousDrags: loading || error != null ? 0 : 1,
      onDragStarted: () => _collapseSelectionPointer = null,
      data: FileTransferDrag(
        sessionId: sessionId,
        source: side,
        path: entry.path,
        name: entry.name,
        isDirectory: entry.isDir,
        selectedFiles: targets,
      ),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: shadcn.Card(
        child: SizedBox(
          width: 200,
          child: Text(
            multi
                ? '已选择 @count 个文件'.trParams({'count': '${targets.length}'})
                : entry.name,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: draggableRow),
      child: draggableRow,
    );
  }
}

/// Wait for the gesture to resolve so a row and its surrounding list cannot
/// both open a menu when the secondary button is held down.
class _FileContextMenu extends StatelessWidget {
  const _FileContextMenu({
    required this.items,
    required this.child,
    this.enabled = true,
  });

  final List<shadcn.MenuItem> items;
  final Widget child;
  final bool enabled;

  void _show(BuildContext context, Offset position) {
    shadcn.showDropdown<void>(
      context: context,
      position: position + const Offset(8, 0),
      alignment: Alignment.topLeft,
      anchorAlignment: Alignment.topRight,
      offset: Offset.zero,
      follow: false,
      dismissBackdropFocus: false,
      builder: (_) => shadcn.DropdownMenu(children: items),
    );
  }

  @override
  Widget build(BuildContext context) {
    final longPressEnabled = switch (shadcn.Theme.of(context).platform) {
      TargetPlatform.iOS ||
      TargetPlatform.android ||
      TargetPlatform.fuchsia => enabled,
      _ => false,
    };
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: enabled
          ? (details) => _show(context, details.globalPosition)
          : null,
      onLongPressStart: longPressEnabled
          ? (details) => _show(context, details.globalPosition)
          : null,
      child: child,
    );
  }
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatFileModified(DateTime? modified) {
  if (modified == null) return '—';
  final local = modified.toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
}
