import 'package:desktop_drop/desktop_drop.dart' as desktop;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../components/app_menu.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';
import 'file_path_breadcrumb.dart';

enum FileBrowserSide { local, remote }

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
  });

  final String sessionId;
  final FileBrowserSide source;
  final String path;
  final String name;
  final List<FileBrowserEntry>? selectedFiles;

  List<FileBrowserEntry> get files =>
      selectedFiles ??
      [FileBrowserEntry(name: name, path: path, isDir: false, size: 0)];
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
    this.onBrowse,
    this.onAuthorize,
    this.onUpload,
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
  final VoidCallback? onBrowse;
  final VoidCallback? onAuthorize;
  final VoidCallback? onUpload;
  final VoidCallback? onMkdir;
  final ValueChanged<FileBrowserEntry>? onRename;
  final ValueChanged<FileBrowserEntry>? onDelete;
  final bool showHidden;
  final ValueChanged<bool>? onShowHiddenChanged;
  final bool active;
  final void Function(List<desktop.DropItem> files, String directory)?
  onExternalDrop;

  @override
  State<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends State<FileBrowserPane> {
  final _selected = <String>{};
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _anchor;
  int _focusedIndex = 0;
  int? _collapseSelectionPointer;
  String? _externalHoverPath;
  final _directoryDropKeys = <String, GlobalKey>{};
  final _fileListDropKey = GlobalKey();

  String get sessionId => widget.sessionId;
  FileBrowserSide get side => widget.side;
  String get cwd => widget.cwd;
  List<FileBrowserEntry> get entries => widget.entries;
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
  ValueChanged<FileBrowserEntry>? get onDelete => widget.onDelete;

  List<FileBrowserEntry> get _selectedFiles => [
    for (final entry in entries)
      if (_selected.contains(entry.path) && !entry.isDir) entry,
  ];

  @override
  void didUpdateWidget(FileBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _directoryDropKeys.removeWhere(
      (path, _) => !entries.any((entry) => entry.isDir && entry.path == path),
    );
    if (!widget.active || loading || error != null || oldWidget.cwd != cwd) {
      _externalHoverPath = null;
    }
    if (oldWidget.cwd != cwd || oldWidget.sessionId != sessionId) {
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
      final top = _focusedIndex * 34.0;
      final position = _scroll.position;
      final bottom = top + 34;
      final offset = top < position.pixels
          ? top
          : bottom > position.pixels + position.viewportDimension
          ? bottom - position.viewportDimension
          : position.pixels;
      _scroll.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
    });
  }

  List<FileBrowserEntry> _filesFor(FileBrowserEntry entry) =>
      _selected.contains(entry.path) ? _selectedFiles : [entry];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (loading || entries.isEmpty) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if ((keyboard.isMetaPressed || keyboard.isControlPressed) &&
        key == LogicalKeyboardKey.keyA) {
      setState(() {
        _selected.addAll(entries.map((entry) => entry.path));
        _anchor ??= entries.first.path;
      });
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selected.clear();
        _anchor = null;
      });
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

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final pane = Focus(
      focusNode: _focus,
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
                      Icon(
                        side == FileBrowserSide.local
                            ? shadcn.LucideIcons.monitor
                            : shadcn.LucideIcons.server,
                        size: 15,
                        color: colors.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (side == FileBrowserSide.local ? '本地文件' : '远程文件').tr,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
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
                child: Row(
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
                          (side == FileBrowserSide.local ? '上传所选文件' : '下载所选文件')
                              .tr,
                      icon: Icon(
                        side == FileBrowserSide.local
                            ? shadcn.LucideIcons.upload
                            : shadcn.LucideIcons.download,
                        size: 16,
                      ),
                      onPressed:
                          loading || error != null || _selectedFiles.isEmpty
                          ? null
                          : () => onTransfer(_selectedFiles),
                    ),
                    AppIconButton(
                      semanticLabel: '刷新'.tr,
                      icon: const Icon(shadcn.LucideIcons.refreshCw, size: 16),
                      onPressed: onRefresh,
                    ),
                    if (onBrowse != null)
                      AppIconButton(
                        semanticLabel: '选择本地目录'.tr,
                        icon: const Icon(
                          shadcn.LucideIcons.folderOpen,
                          size: 16,
                        ),
                        onPressed: onBrowse,
                      ),
                    if (onMkdir != null)
                      AppIconButton(
                        semanticLabel: '新建目录'.tr,
                        icon: const Icon(
                          shadcn.LucideIcons.folderPlus,
                          size: 16,
                        ),
                        onPressed: loading || error != null ? null : onMkdir,
                      ),
                    if (onUpload != null)
                      AppIconButton(
                        semanticLabel: '上传文件'.tr,
                        icon: const Icon(shadcn.LucideIcons.fileUp, size: 16),
                        onPressed: loading || error != null ? null : onUpload,
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
                        Expanded(child: Text('名称'.tr)),
                        SizedBox(
                          width: AppTheme.fileSizeColumnWidth,
                          child: Text('大小'.tr, textAlign: TextAlign.right),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: AppTheme.fileModifiedColumnWidth,
                          child: Text('更新时间'.tr),
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
              Expanded(
                child: GestureDetector(
                  key: _fileListDropKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _focus.requestFocus();
                    setState(() {
                      _selected.clear();
                      _anchor = null;
                    });
                  },
                  child: loading
                      ? const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: shadcn.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        )
                      : entries.isEmpty
                      ? Center(
                          child: Text(
                            '空目录'.tr,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.mutedForeground,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: entries.length,
                          itemBuilder: (context, index) =>
                              _entry(context, entries[index]),
                        ),
                ),
              ),
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

  Widget _entry(BuildContext context, FileBrowserEntry entry) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final selected = _selected.contains(entry.path);
    final selectedForeground = AppTheme.fileSelectionForeground(context);
    final actions = [
      if (entry.isDir)
        ('open', '打开'.tr)
      else
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
          onDelete?.call(entry);
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
              height: 34,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    entry.isDir
                        ? shadcn.LucideIcons.folder
                        : shadcn.LucideIcons.file,
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
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (entry.isDir) {
      return DragTarget<FileTransferDrag>(
        onWillAcceptWithDetails: (details) => _accepts(details.data),
        onAcceptWithDetails: (details) => onDrop(details.data, entry.path),
        builder: (context, candidates, rejected) => ColoredBox(
          key: _directoryDropKeys.putIfAbsent(entry.path, GlobalKey.new),
          color: candidates.isEmpty && _externalHoverPath != entry.path
              ? shadcn.Colors.transparent
              : colors.primary.withValues(alpha: 0.16),
          child: row,
        ),
      );
    }
    return Draggable<FileTransferDrag>(
      key: ValueKey('sftp-${side.name}-${entry.path}'),
      maxSimultaneousDrags: loading || error != null ? 0 : 1,
      onDragStarted: () => _collapseSelectionPointer = null,
      data: FileTransferDrag(
        sessionId: sessionId,
        source: side,
        path: entry.path,
        name: entry.name,
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
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
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
