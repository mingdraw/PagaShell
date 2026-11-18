import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart' as desktop;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../components/app_menu.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';
import 'file_path_breadcrumb.dart';

enum FileBrowserSide { local, remote }

enum _FileSortField { name, size, modified }

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
    this.onUp,
    this.onBrowse,
    this.onAuthorize,
    this.onUpload,
    this.onUploadDirectory,
    this.onMkdir,
    this.onRename,
    this.onDelete,
    this.showHidden = false,
    this.onShowHiddenChanged,
    this.active = true,
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
  final bool showHidden;
  final ValueChanged<bool>? onShowHiddenChanged;
  final bool active;
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
  late List<FileBrowserEntry> _sortedEntries;
  _FileSortField? _sortField;
  bool _sortAscending = true;
  bool _editingPath = false;
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

  List<FileBrowserEntry> get _selectedEntries => [
    for (final entry in entries)
      if (_selected.contains(entry.path)) entry,
  ];

  @override
  void initState() {
    super.initState();
    _rebuildSortedEntries();
    _scroll.addListener(_selectionScrolled);
  }

  void _rebuildSortedEntries() {
    final field = _sortField;
    if (field == null) {
      _sortedEntries = List.of(widget.entries);
      return;
    }
    int compareByName(FileBrowserEntry a, FileBrowserEntry b) {
      final lower = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return lower != 0 ? lower : a.name.compareTo(b.name);
    }

    _sortedEntries = List.of(widget.entries)
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
      _anchor = _selectionAnchorBeforeDrag;
      _focusedIndex = _selectionFocusBeforeDrag;
      _resetSelectionDrag();
    });
  }

  @override
  void didUpdateWidget(FileBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final entriesChanged =
        oldWidget.entries.length != widget.entries.length ||
        oldWidget.entries.indexed.any(
          (item) => item.$2.path != widget.entries[item.$1].path,
        );
    _rebuildSortedEntries();
    if (!widget.active ||
        loading ||
        error != null ||
        oldWidget.cwd != cwd ||
        oldWidget.sessionId != sessionId ||
        entriesChanged) {
      _resetSelectionDrag();
    }
    if (_directoryDropKeys.isNotEmpty) {
      final directories = {
        for (final entry in entries)
          if (entry.isDir) entry.path,
      };
      _directoryDropKeys.removeWhere((path, _) => !directories.contains(path));
    }
    if (!widget.active || loading || error != null || oldWidget.cwd != cwd) {
      _externalHoverPath = null;
    }
    if (oldWidget.cwd != cwd || oldWidget.sessionId != sessionId) {
      _editingPath = false;
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
    } else {
      final paths = entries.map((entry) => entry.path).toSet();
      _selected.removeWhere((path) => !paths.contains(path));
      if (!paths.contains(_anchor)) _anchor = null;
    }
  }

  @override
  void dispose() {
    _resetSelectionDrag();
    _pathController.dispose();
    _pathFocus.dispose();
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
    if (_editingPath || _pathFocus.hasFocus) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (loading) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace && widget.onUp != null) {
      widget.onUp!();
      return KeyEventResult.handled;
    }
    if (entries.isEmpty) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if ((keyboard.isMetaPressed || keyboard.isControlPressed) &&
        key == LogicalKeyboardKey.keyA) {
      setState(() {
        _selected.addAll(entries.map((entry) => entry.path));
        _anchor ??= entries.first.path;
      });
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _resetSelectionDrag();
        _selected.clear();
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
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      final next = switch (key) {
        LogicalKeyboardKey.home => 0,
        LogicalKeyboardKey.end => entries.length - 1,
        LogicalKeyboardKey.arrowDown =>
          _selected.isEmpty ? 0 : _focusedIndex + 1,
        _ => _selected.isEmpty ? 0 : _focusedIndex - 1,
      };
      _select(entries[next.clamp(0, entries.length - 1)], additive: false);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool _accepts(FileTransferDrag data) =>
      !loading &&
      error == null &&
      cwd.isNotEmpty &&
      data.sessionId == sessionId &&
      data.source != side;

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

  Widget _fileList(BuildContext context) => LayoutBuilder(
    key: _fileListDropKey,
    builder: (context, constraints) {
      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
      final rect = _selectionRect
          ?.shift(Offset(0, -offset))
          .intersect(Offset.zero & constraints.biggest);
      final colors = shadcn.Theme.of(context).colorScheme;
      return Listener(
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
                  '空目录'.tr,
                  style: TextStyle(fontSize: 12, color: colors.mutedForeground),
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
                itemBuilder: (context, index) =>
                    _entry(context, entries[index]),
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
              SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      AppIcon(
                        side == FileBrowserSide.local
                            ? AppIcons.monitor
                            : AppIcons.server,
                        size: 15,
                        color: colors.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (side == FileBrowserSide.local ? '本地文件' : '远程文件').tr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      AppIconButton(
                        key: ValueKey('sftp-${side.name}-edit-path'),
                        semanticLabel: '输入路径'.tr,
                        tooltip: '输入路径'.tr,
                        density: shadcn.ButtonDensity.compact,
                        icon: const AppIcon(AppIcons.pencil, size: 13),
                        onPressed: loading || cwd.isEmpty
                            ? null
                            : _editingPath
                            ? _cancelPathEdit
                            : _startPathEdit,
                      ),
                      const SizedBox(width: 6),
                      if (side == FileBrowserSide.remote)
                        const shadcn.OutlineBadge(child: Text('SFTP')),
                      if (widget.onShowHiddenChanged != null) ...[
                        Text(
                          '隐藏文件'.tr,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.mutedForeground,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Semantics(
                          label: '显示隐藏文件'.tr,
                          child: shadcn.Switch(
                            value: widget.showHidden,
                            onChanged: widget.onShowHiddenChanged,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 40,
                child: _editingPath
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: CallbackShortcuts(
                                bindings: {
                                  const SingleActivator(
                                    LogicalKeyboardKey.escape,
                                  ): _cancelPathEdit,
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
                    : Row(
                        children: [
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilePathBreadcrumb(
                              path: cwd,
                              remote: side == FileBrowserSide.remote,
                              onNavigate: loading ? null : widget.onNavigate,
                            ),
                          ),
                          AppIconButton(
                            semanticLabel:
                                (side == FileBrowserSide.local
                                        ? '上传所选文件'
                                        : '下载所选文件')
                                    .tr,
                            tooltip:
                                (side == FileBrowserSide.local
                                        ? '上传所选文件'
                                        : '下载所选文件')
                                    .tr,
                            icon: AppIcon(
                              side == FileBrowserSide.local
                                  ? AppIcons.upload
                                  : AppIcons.download,
                              size: 16,
                            ),
                            onPressed:
                                loading ||
                                    error != null ||
                                    _selectedEntries.isEmpty
                                ? null
                                : () => onTransfer(_selectedEntries),
                          ),
                          AppIconButton(
                            semanticLabel: '刷新'.tr,
                            tooltip: '刷新'.tr,
                            icon: const AppIcon(AppIcons.refreshCw, size: 16),
                            onPressed: onRefresh,
                          ),
                          if (onBrowse != null)
                            AppIconButton(
                              semanticLabel: '选择本地目录'.tr,
                              tooltip: '选择本地目录'.tr,
                              icon: const AppIcon(
                                AppIcons.folderOpen,
                                size: 16,
                              ),
                              onPressed: onBrowse,
                            ),
                          if (onMkdir != null)
                            AppIconButton(
                              semanticLabel: '新建目录'.tr,
                              tooltip: '新建目录'.tr,
                              icon: const AppIcon(
                                AppIcons.folderPlus,
                                size: 16,
                              ),
                              onPressed: loading || error != null
                                  ? null
                                  : onMkdir,
                            ),
                          if (onUpload != null)
                            AppIconButton(
                              semanticLabel: '上传文件'.tr,
                              tooltip: '上传文件'.tr,
                              icon: const AppIcon(AppIcons.fileUp, size: 16),
                              onPressed: loading || error != null
                                  ? null
                                  : onUpload,
                            ),
                          if (widget.onUploadDirectory != null)
                            AppIconButton(
                              semanticLabel: '上传文件夹'.tr,
                              tooltip: '上传文件夹'.tr,
                              icon: const AppIcon(AppIcons.folderUp, size: 16),
                              onPressed: loading || error != null
                                  ? null
                                  : widget.onUploadDirectory,
                            ),
                          const SizedBox(width: 4),
                        ],
                      ),
              ),
              const shadcn.Divider(),
              SizedBox(
                height: 26,
                child: Padding(
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
                    ),
                  ),
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
          if (onDelete != null)
            AppIconButton(
              key: ValueKey('sftp-${side.name}-selection-delete'),
              semanticLabel: '删除所选'.tr,
              tooltip: '删除所选'.tr,
              density: shadcn.ButtonDensity.compact,
              icon: AppIcon(
                AppIcons.trash2,
                size: 14,
                color: colors.destructive,
              ),
              onPressed: () => onDelete!(selected),
            ),
          AppIconButton(
            key: ValueKey('sftp-${side.name}-selection-clear'),
            semanticLabel: '取消选择'.tr,
            tooltip: '取消选择'.tr,
            density: shadcn.ButtonDensity.compact,
            icon: const AppIcon(AppIcons.x, size: 14),
            onPressed: () => setState(() {
              _selected.clear();
              _anchor = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, FileBrowserEntry entry) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final selected = _selected.contains(entry.path);
    final selectedForeground = AppTheme.fileSelectionForeground(context);
    final actions = [
      if (entry.isDir) ('open', '打开'.tr),
      (
        side == FileBrowserSide.local ? 'upload' : 'download',
        (side == FileBrowserSide.local ? '上传' : '下载').tr,
      ),
      if (onRename != null) ('rename', '重命名'.tr),
      if (onDelete != null) ('delete', '删除'.tr),
    ];
    void action(String value) {
      switch (value) {
        case 'open':
          onOpen(entry);
        case 'upload':
        case 'download':
          onTransfer(_filesFor(entry));
        case 'rename':
          onRename?.call(entry);
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
      child: shadcn.ContextMenu(
        items: appMenuItems(actions, action),
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
            onWillAcceptWithDetails: (details) => _accepts(details.data),
            onAcceptWithDetails: (details) => onDrop(details.data, entry.path),
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
        selectedFiles: List.of(_filesFor(entry)),
      ),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: shadcn.Card(
        child: SizedBox(
          width: 200,
          child: Text(
            _filesFor(entry).length > 1
                ? '已选择 @count 个文件'.trParams({
                    'count': '${_filesFor(entry).length}',
                  })
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
