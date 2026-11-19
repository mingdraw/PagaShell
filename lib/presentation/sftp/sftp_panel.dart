import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/sftp/local_file_controller.dart';
import '../../application/sftp/sftp_controller.dart';
import '../../application/transfer/directory_transfer.dart';
import '../../application/transfer/transfer_controller.dart';
import '../../domain/entities/local_file_entry.dart';
import '../../domain/entities/small_text_file.dart';
import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'file_browser_pane.dart';
import 'small_text_file_dialog.dart';

typedef LocalDirectoryPicker = Future<String?> Function({
  String? initialDirectory,
  String? confirmButtonText,
});

enum _FileConflictAction { overwrite, skip }

typedef _FileConflictDecision = ({
  _FileConflictAction action,
  bool applyToRemaining,
});

/// 冲突策略只在当前批次中共享，新的传输操作重新询问。
class _TransferBatch {
  _FileConflictAction? conflictAction;
  bool cancelled = false;
}

Future<Future<void> Function()> _acquireExternalSource(
  Uint8List? bookmark,
) async {
  var accessing =
      bookmark != null &&
      bookmark.isNotEmpty &&
      await DesktopDrop.instance.startAccessingSecurityScopedResource(
        bookmark: bookmark,
      );
  return () async {
    if (!accessing) return;
    accessing = false;
    try {
      await DesktopDrop.instance.stopAccessingSecurityScopedResource(
        bookmark: bookmark!,
      );
    } on PlatformException {
      // 原生插件退出时由系统回收进程权限。
    } on MissingPluginException {
      // 应用退出阶段原生通道可能已经注销。
    }
  };
}

/// 独立文件传输标签的双栏浏览器：左本地、右远程，支持双向文件拖放。
/// 传输任务交给 [TransferController]，底部传输条展示本会话的任务进度。
class SftpPanel extends StatefulWidget {
  const SftpPanel({
    super.key,
    required this.session,
    required this.localFiles,
    this.directoryPicker = getDirectoryPath,
    this.active = true,
    this.onReconnect,
  });

  final Session session;
  final LocalFileRepository localFiles;
  final LocalDirectoryPicker directoryPicker;
  final bool active;
  final Future<SshEngineSession> Function()? onReconnect;

  @override
  State<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends State<SftpPanel> {
  SshEngineSession get _engine => widget.session.engineSession!;
  late SftpController _browser;
  late LocalFileController _local;
  late String _tag;
  final List<Worker> _transferWorkers = [];
  final Set<String> _preparingTargets = {};
  final _filePane = shadcn.AbsoluteResizablePaneController(0);
  final _localPane = shadcn.FlexibleResizablePaneController(1);
  final _remotePane = shadcn.FlexibleResizablePaneController(1);
  final _showRemoteHidden = true.obs;
  final _transferPane = shadcn.AbsoluteResizablePaneController(
    AppTheme.transferProgressDefaultHeight,
    collapsed: true,
  );
  bool _transferExpanded = false;
  double _expandedTransferHeight = AppTheme.transferProgressDefaultHeight;
  bool _choosingLocalDirectory = false;
  bool _deletingLocal = false;
  bool _deletingRemote = false;
  final _fileMoves = <FileBrowserSide>{};

  @override
  void initState() {
    super.initState();
    _bindBrowser();
  }

  void _bindBrowser() {
    _tag = 'sftp-${widget.session.id}-${identityHashCode(this)}';
    _browser = Get.put(
      SftpController(
        engine: _engine,
        reconnect: widget.onReconnect == null
            ? null
            : () => widget.onReconnect!(),
      ),
      tag: _tag,
    );
    _local = Get.put(LocalFileController(files: widget.localFiles), tag: _tag);
    final local = _local;
    final revision = local.navigationRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await local.initialNavigation;
      if (!_isCurrentLocalNavigation(local, revision)) return;
      final denied = local.permissionDeniedPath.value;
      if (denied != null) {
        await _authorizeLocalDirectory(local, denied, revision);
      }
    });
  }

  @override
  void didUpdateWidget(SftpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _showRemoteHidden.value = true;
      _transferExpanded = false;
      _expandedTransferHeight = AppTheme.transferProgressDefaultHeight;
      _transferPane.collapse();
    }
    if (oldWidget.session.id != widget.session.id ||
        oldWidget.localFiles != widget.localFiles) {
      _releaseBrowser();
      _bindBrowser();
    } else if (!identical(_browser.engine, _engine)) {
      _browser.replaceEngine(_engine);
      unawaited(_browser.refreshDirectory(reconnectIfNeeded: false));
    }
  }

  void _releaseBrowser() {
    for (final worker in _transferWorkers) {
      worker.dispose();
    }
    _transferWorkers.clear();
    Get.delete<SftpController>(tag: _tag);
    Get.delete<LocalFileController>(tag: _tag);
  }

  @override
  void dispose() {
    _releaseBrowser();
    _filePane.dispose();
    _localPane.dispose();
    _remotePane.dispose();
    _transferPane.dispose();
    super.dispose();
  }

  void _toggleTransferExpanded() {
    setState(() {
      _transferExpanded = !_transferExpanded;
      if (_transferExpanded) {
        _transferPane.expand();
      } else {
        _transferPane.collapse();
      }
    });
  }

  void _resizeTransfer(double height) {
    final expanded = !_transferPane.collapsed;
    if (expanded) _expandedTransferHeight = height;
    if (_transferExpanded != expanded) {
      setState(() => _transferExpanded = expanded);
    }
  }

  Future<void> _upload() async {
    final browser = _browser;
    final sessionId = widget.session.id;
    final directory = browser.cwd.value;
    final files = await openFiles();
    if (files.isEmpty || !mounted || browser != _browser) return;
    final batch = _TransferBatch();
    for (final file in files) {
      final proceed = await _transferFile(
        FileTransferDrag(
          sessionId: sessionId,
          source: FileBrowserSide.local,
          path: file.path,
          name: file.name,
        ),
        directory,
        batch,
      );
      if (!proceed || !mounted || browser != _browser) return;
    }
  }

  Future<void> _uploadExternal(List<DropItem> files, String directory) async {
    final browser = _browser;
    final local = _local;
    final sessionId = widget.session.id;
    final batch = _TransferBatch();
    final seen = <String>{};
    for (final file in files) {
      if (!mounted || browser != _browser || local != _local) return;
      if (!seen.add(file.path)) continue;
      final bookmark = file.extraAppleBookmark;
      var started = false;
      Future<void> Function()? release;
      try {
        release = await _acquireExternalSource(bookmark);
        final entry = await local.files.entryAt(file.path);
        if (!mounted || browser != _browser || local != _local) return;
        final proceed = await _transferFile(
          FileTransferDrag(
            sessionId: sessionId,
            source: FileBrowserSide.local,
            path: entry.path,
            name: entry.name,
            isDirectory: entry.isDir,
          ),
          directory,
          batch,
          releaseUploadSource: release,
          acquireUploadSource: () => _acquireExternalSource(bookmark),
          onUploadStarted: () => started = true,
        );
        if (!proceed) return;
      } on Object {
        if (mounted && browser == _browser) {
          AppNotice.error('无法读取拖入的文件，请检查访问权限'.tr);
        }
        return;
      } finally {
        if (!started) await release?.call();
      }
    }
  }

  Future<void> _uploadDirectory() async {
    if (_choosingLocalDirectory) return;
    final browser = _browser;
    final local = _local;
    final directory = browser.cwd.value;
    _choosingLocalDirectory = true;
    String? path;
    try {
      path = await widget.directoryPicker(
        initialDirectory: local.cwd.value,
        confirmButtonText: '上传文件夹'.tr,
      );
    } on Object {
      if (mounted) AppNotice.error('无法打开目录选择窗口，请重试'.tr);
    } finally {
      _choosingLocalDirectory = false;
    }
    if (path == null || !mounted || browser != _browser || local != _local) {
      return;
    }
    late LocalFileEntry entry;
    try {
      entry = await local.files.entryAt(path);
    } on Object {
      if (mounted) AppNotice.error('无法读取文件夹，请检查访问权限'.tr);
      return;
    }
    if (!mounted || browser != _browser || local != _local) return;
    await _transferFile(
      FileTransferDrag(
        sessionId: widget.session.id,
        source: FileBrowserSide.local,
        path: path,
        name: entry.name,
        isDirectory: true,
      ),
      directory,
      _TransferBatch(),
    );
  }

  Future<void> _chooseLocalDirectory() async {
    if (_choosingLocalDirectory) return;
    final local = _local;
    final revision = local.navigationRevision;
    _choosingLocalDirectory = true;
    try {
      final path = await widget.directoryPicker(
        initialDirectory: local.cwd.value.isEmpty
            ? local.files.homeDirectory
            : local.cwd.value,
      );
      if (path != null && _isCurrentLocalNavigation(local, revision)) {
        await local.navigate(path);
      }
    } on Object {
      if (_isCurrentLocalNavigation(local, revision)) {
        AppNotice.error('无法打开目录选择窗口，请重试'.tr);
      }
    } finally {
      _choosingLocalDirectory = false;
    }
  }

  bool _isCurrentLocalNavigation(LocalFileController local, int revision) =>
      mounted && local == _local && revision == local.navigationRevision;

  Future<void> _navigateLocalDirectory(String path) async {
    final local = _local;
    final navigation = local.navigate(path);
    final revision = local.navigationRevision;
    await navigation;
    if (_isCurrentLocalNavigation(local, revision) &&
        local.permissionDeniedPath.value == path) {
      await _authorizeLocalDirectory(local, path, revision);
    }
  }

  Future<void> _authorizeLocalDirectory(
    LocalFileController local,
    String path,
    int revision,
  ) async {
    final selected = await _requestLocalDirectoryAccess(local, path, revision);
    if (selected != null && _isCurrentLocalNavigation(local, revision)) {
      // 系统选择窗口已为所选目录授予本次进程的沙盒访问权限。
      await local.navigate(selected);
    }
  }

  Future<String?> _requestLocalDirectoryAccess(
    LocalFileController local,
    String path,
    int revision,
  ) async {
    if (_choosingLocalDirectory ||
        !_isCurrentLocalNavigation(local, revision)) {
      return null;
    }
    _choosingLocalDirectory = true;
    try {
      final selected = await widget.directoryPicker(
        initialDirectory: path,
        confirmButtonText: '授权访问'.tr,
      );
      return _isCurrentLocalNavigation(local, revision) ? selected : null;
    } on Object {
      if (_isCurrentLocalNavigation(local, revision)) {
        AppNotice.error('无法打开目录选择窗口，请重试'.tr);
      }
      return null;
    } finally {
      _choosingLocalDirectory = false;
    }
  }

  Future<void> _transferFiles(
    List<FileBrowserEntry> files,
    FileBrowserSide source,
    String directory,
  ) async {
    final browser = _browser;
    final local = _local;
    final sessionId = widget.session.id;
    final batch = _TransferBatch();
    for (final file in files) {
      if (!mounted || browser != _browser || local != _local) return;
      final proceed = await _transferFile(
        FileTransferDrag(
          sessionId: sessionId,
          source: source,
          path: file.path,
          name: file.name,
          isDirectory: file.isDir,
        ),
        directory,
        batch,
      );
      if (!proceed) return;
    }
  }

  Future<void> _dropFiles(FileTransferDrag data, String directory) async {
    if (data.sessionId != widget.session.id) return;
    await _transferFiles(data.files, data.source, directory);
  }

  bool _hasActiveTransfer(bool local, String path, {bool isDir = false}) {
    final paths = local ? p.context : p.posix;
    return Get.find<TransferController>().tasks.any((task) {
      if (!(task.status.value.active || task.retrying.value) ||
          (!local && task.sessionId != widget.session.id)) {
        return false;
      }
      final active = local ? task.localPath : task.remotePath;
      return paths.equals(active, path) ||
          (task.isDirectory && paths.isWithin(active, path)) ||
          (isDir && paths.isWithin(path, active));
    });
  }

  Future<void> _moveFiles(FileTransferDrag data, String directory) async {
    if (data.sessionId != widget.session.id || !_fileMoves.add(data.source)) {
      return;
    }
    final local = data.source == FileBrowserSide.local;
    final paths = local ? p.context : p.posix;
    final localBrowser = _local;
    final browser = _browser;
    final engine = browser.engine;
    final mover = localBrowser.files;
    final failures = <String>[];
    bool current() =>
        mounted &&
        browser == _browser &&
        localBrowser == _local &&
        (local ||
            (identical(engine, browser.engine) &&
                !browser.needsReconnect.value &&
                !browser.reconnecting.value));
    var moved = 0;
    try {
      final targetDirectory = local
          ? directory
          : await engine.canonicalize(directory);
      final occupied = local
          ? <String>{}
          : (await engine.listDir(targetDirectory))
                .map((entry) => entry.name)
                .toSet();
      for (final entry in data.files) {
        if (!current()) return;
        final target = local
            ? localBrowser.files.pathOf(targetDirectory, entry.name)
            : SftpController.join(targetDirectory, entry.name);
        try {
          // 服务端返回的名称同样必须是单个文件名。
          if (entry.name.isEmpty ||
              entry.name == '.' ||
              entry.name == '..' ||
              entry.name.contains('/') ||
              paths.equals(entry.path, target) ||
              (entry.isDir && paths.isWithin(entry.path, targetDirectory)) ||
              occupied.contains(entry.name) ||
              _hasActiveTransfer(local, entry.path, isDir: entry.isDir) ||
              _hasActiveTransfer(local, target, isDir: entry.isDir)) {
            failures.add(entry.name);
            continue;
          }
          if (local) {
            if (mover is! LocalFileMover) return;
            await (mover as LocalFileMover).moveTo(
              entry.path,
              target,
              isDir: entry.isDir,
            );
          } else {
            if (entry.isDir) {
              final source = await engine.canonicalize(entry.path);
              if (!current()) return;
              if (paths.equals(source, targetDirectory) ||
                  paths.isWithin(source, targetDirectory)) {
                failures.add(entry.name);
                continue;
              }
            }
            // 使用标准 SFTP RENAME；不使用覆盖目标的 POSIX 扩展。
            await engine.rename(entry.path, target);
          }
          occupied.add(entry.name);
          moved++;
        } on Object catch (error) {
          failures.add(entry.name);
          if (error is SshEngineException && error.isConnectionClosed) break;
        }
      }
      if (!current()) return;
      if (moved > 0) {
        if (local) {
          await localBrowser.refreshDirectory();
        } else {
          await browser.refreshDirectory(reconnectIfNeeded: false);
        }
      }
      if (!current()) return;
      if (failures.isNotEmpty) {
        AppNotice.error('部分文件未能移动，请检查重名、目录权限或进行中的传输');
      } else if (moved > 0) {
        AppNotice.success('已移动 @count 项'.trParams({'count': '$moved'}));
      }
    } on Object {
      if (current()) AppNotice.error('无法移动文件，请检查目标目录');
    } finally {
      _fileMoves.remove(data.source);
    }
  }

  Future<void> _editText(FileBrowserEntry entry, {required bool local}) async {
    final browser = _browser;
    final localBrowser = _local;
    final engine = browser.engine;
    final Object access = local ? localBrowser.files : engine;
    if (access is! SmallTextFileAccess) return;
    bool current() =>
        mounted &&
        browser == _browser &&
        localBrowser == _local &&
        (local ||
            (identical(engine, browser.engine) &&
                !browser.needsReconnect.value &&
                !browser.reconnecting.value));
    final saved = await AppNavigation.dialog<bool>(
      SmallTextFileDialog(
        name: entry.name,
        path: entry.path,
        read: () => access.readSmallText(entry.path),
        save: (original, text) async {
          if (!current()) {
            throw const SmallTextFileException('文件连接已变更，请重新打开');
          }
          if (_hasActiveTransfer(local, entry.path)) {
            throw const SmallTextFileException('文件正在传输，请稍后再保存');
          }
          await access.saveSmallText(entry.path, original, text);
        },
      ),
    );
    if (saved != true || !current()) return;
    if (local) {
      await localBrowser.refreshDirectory();
    } else {
      await browser.refreshDirectory(reconnectIfNeeded: false);
    }
  }

  /// false 表示取消或连接已变更，调用方应停止本批次；跳过仍继续。
  Future<bool> _transferFile(
    FileTransferDrag data,
    String directory,
    _TransferBatch batch, {
    Future<void> Function()? releaseUploadSource,
    TransferSourceAccess? acquireUploadSource,
    VoidCallback? onUploadStarted,
  }) async {
    if (!mounted || data.sessionId != widget.session.id || batch.cancelled) {
      return false;
    }
    if (widget.session.phase != SessionPhase.ready ||
        _browser.needsReconnect.value ||
        _browser.reconnecting.value) {
      return false;
    }
    if (directory.isEmpty) {
      AppNotice.error('请先打开目标目录'.tr);
      return false;
    }
    final browser = _browser;
    final local = _local;
    final engine = _engine;
    final sessionId = widget.session.id;
    final upload = data.source == FileBrowserSide.local;
    final controller = Get.find<TransferController>();
    String? targetKey;
    var ownsTarget = false;
    try {
      final remotePath = upload
          ? SftpController.join(directory, data.name)
          : data.path;
      final localPath = upload
          ? data.path
          : local.files.pathOf(directory, data.name);
      targetKey =
          '${upload ? 'remote' : 'local'}:${upload ? remotePath : localPath}';
      if (!_preparingTargets.add(targetKey)) return true;
      ownsTarget = true;
      bool isRunning() => controller
          .tasksOf(sessionId)
          .any(
            (task) =>
                (task.status.value.active || task.retrying.value) &&
                task.conflictsWithTarget(
                  kind: upload ? TransferKind.upload : TransferKind.download,
                  remotePath: remotePath,
                  localPath: localPath,
                  isDirectory: data.isDirectory,
                ),
          );
      if (isRunning()) return true;

      // 使用目标目录的实时内容判断冲突，目录行落点也适用。
      bool exists;
      bool isDir;
      if (upload) {
        final entry = (await engine.listDir(directory))
            .firstWhereOrNull((entry) => entry.name == data.name);
        exists = entry != null;
        isDir = entry?.isDir ?? false;
      } else {
        final revision = local.navigationRevision;
        late List<LocalFileEntry> entries;
        try {
          entries = await local.files.listDirectory(directory);
        } on LocalDirectoryAccessDenied {
          final selected = await _requestLocalDirectoryAccess(
            local,
            directory,
            revision,
          );
          if (selected == null) return false;
          // 继续读取原落点，避免用户选了其他文件夹后更改下载位置。
          entries = await local.files.listDirectory(directory);
        }
        final entry = entries.firstWhereOrNull(
          (entry) => entry.name == data.name,
        );
        exists = entry != null;
        isDir = entry?.isDir ?? false;
      }
      if (!mounted || browser != _browser || local != _local) return false;
      if (exists && isDir != data.isDirectory) {
        AppNotice.error((isDir ? '目标位置存在同名目录' : '目标文件与目录类型不一致').tr);
        return true;
      }
      Future<_FileConflictAction?> resolveConflict(String name) async {
        if (!mounted ||
            browser != _browser ||
            local != _local ||
            batch.cancelled) {
          return null;
        }
        var action = batch.conflictAction;
        if (action == null) {
          final decision = await AppNavigation.dialog<_FileConflictDecision>(
            _FileConflictDialog(name: name),
          );
          if (decision == null) {
            batch.cancelled = true;
            return null;
          }
          if (!mounted || browser != _browser || local != _local) return null;
          action = decision.action;
          if (decision.applyToRemaining) batch.conflictAction = action;
        }
        return action;
      }

      if (exists && !data.isDirectory) {
        final action = await resolveConflict(data.name);
        if (action == null) return false;
        if (action == _FileConflictAction.skip) return true;
      }
      if (!mounted ||
          browser != _browser ||
          local != _local ||
          !identical(engine, _engine) ||
          widget.session.phase != SessionPhase.ready ||
          browser.needsReconnect.value ||
          browser.reconnecting.value) {
        return false;
      }
      if (isRunning()) return true;
      Future<DirectoryConflictAction> directoryConflict(String name) async =>
          switch (await resolveConflict(name)) {
            _FileConflictAction.overwrite => DirectoryConflictAction.overwrite,
            _FileConflictAction.skip => DirectoryConflictAction.skip,
            null => DirectoryConflictAction.cancel,
          };
      Future<bool> authorize(String path) async =>
          mounted &&
          browser == _browser &&
          local == _local &&
          await _requestLocalDirectoryAccess(
                local,
                path,
                local.navigationRevision,
              ) !=
              null;
      final task = upload
          ? controller.startUpload(
              sessionId: sessionId,
              engineSession: engine,
              localPath: localPath,
              remotePath: remotePath,
              releaseSource: releaseUploadSource,
              acquireSource: acquireUploadSource,
              isDirectory: data.isDirectory,
              localFiles: local.files,
              onConflict: directoryConflict,
              authorizeLocalDirectory: authorize,
            )
          : controller.startDownload(
              sessionId: sessionId,
              engineSession: engine,
              remotePath: remotePath,
              localPath: localPath,
              isDirectory: data.isDirectory,
              localFiles: local.files,
              onConflict: directoryConflict,
              authorizeLocalDirectory: authorize,
            );
      if (upload) onUploadStarted?.call();
      _refreshAfterTransfer(task);
      if (data.isDirectory && task.status.value.active) {
        await task.status.stream.firstWhere((status) => !status.active);
      }
      return !batch.cancelled && task.status.value != TransferStatus.cancelled;
    } on Object catch (e) {
      if (mounted && browser == _browser) {
        AppNotice.error(
          AppTranslations.error(
            e is SshEngineException
                ? e.message
                : e is LocalDirectoryAccessDenied
                ? '需要授权才能访问此文件夹'
                : '无法开始文件传输，请重试',
          ),
        );
      }
      return false;
    } finally {
      if (ownsTarget) _preparingTargets.remove(targetKey);
    }
  }

  void _refreshAfterTransfer(TransferTask task) {
    void refresh() {
      if (!mounted) return;
      unawaited(
        task.kind == TransferKind.upload
            ? _browser.refreshDirectory(reconnectIfNeeded: false)
            : _local.refreshDirectory(),
      );
    }

    if (!task.status.value.active) {
      refresh();
      return;
    }
    late Worker worker;
    worker = ever(task.status, (status) {
      if (status.active) return;
      if (status != TransferStatus.failed) {
        worker.dispose();
        _transferWorkers.remove(worker);
      }
      refresh();
    });
    _transferWorkers.add(worker);
  }

  Future<void> _mkdirLocal() async {
    final local = _local;
    final directory = local.cwd.value;
    if (directory.isEmpty || local.loading.value || local.error.value != null) {
      return;
    }
    await _promptName(
      context,
      title: '新建目录',
      onCommit: (name) async {
        if (!mounted ||
            !identical(local, _local) ||
            local.cwd.value != directory) {
          return '本地目录已变更，请重试';
        }
        try {
          await local.createDirectory(name);
          return null;
        } on LocalFileTargetExists {
          return '目标位置已存在同名文件或目录';
        } on ArgumentError {
          return '请输入有效的目录名称';
        } on UnsupportedError {
          return '请输入有效的目录名称';
        } on Object {
          return '无法新建目录，请检查名称和目录权限';
        }
      },
    );
  }

  Future<void> _mkdir() async {
    final browser = _browser;
    final directory = browser.cwd.value;
    final name = await _promptName(context, title: '新建目录');
    if (name == null ||
        name.isEmpty ||
        !mounted ||
        browser != _browser ||
        directory != browser.cwd.value) {
      return;
    }
    await browser.createDir(name);
  }

  Future<void> _rename(FileBrowserEntry entry, {bool local = false}) async {
    final browser = _browser;
    final localBrowser = _local;
    final directory = local ? localBrowser.cwd.value : browser.cwd.value;
    final name = await _promptName(context, title: '重命名', initial: entry.name);
    if (name == null ||
        name.isEmpty ||
        name == entry.name ||
        !mounted ||
        browser != _browser ||
        localBrowser != _local ||
        directory != (local ? localBrowser.cwd.value : browser.cwd.value)) {
      return;
    }
    if (local) {
      await localBrowser.rename(_localEntry(entry), name);
    } else {
      await browser.rename(entry.name, name);
    }
  }

  LocalFileEntry _localEntry(FileBrowserEntry entry) => LocalFileEntry(
    path: entry.path,
    name: entry.name,
    isDir: entry.isDir,
    size: entry.size,
    modified: entry.modified,
  );

  Future<void> _delete(
    List<FileBrowserEntry> entries, {
    bool local = false,
  }) async {
    if (entries.isEmpty || (local ? _deletingLocal : _deletingRemote)) return;
    final browser = _browser;
    final localBrowser = _local;
    final directory = local ? localBrowser.cwd.value : browser.cwd.value;
    final revision = local
        ? localBrowser.navigationRevision
        : browser.navigationRevision;
    final engine = browser.engine;
    final selected = List<FileBrowserEntry>.of(entries);
    final single = selected.length == 1;
    final hasDirectory = selected.any((entry) => entry.isDir);
    if (local) {
      _deletingLocal = true;
    } else {
      _deletingRemote = true;
    }
    try {
      final ok = await AppNavigation.dialog<bool>(
        AppDialog(
          title: Text(
            single
                ? '删除「@name」？'.trParams({'name': selected.single.name})
                : '删除选中的 @count 项？'.trParams({'count': '${selected.length}'}),
          ),
          content: Text(
            hasDirectory
                ? (single ? '将递归删除该目录及其全部内容。' : '将递归删除所选目录及其全部内容，此操作不可撤销。').tr
                : '该操作不可撤销。'.tr,
          ),
          actions: [
            shadcn.OutlineButton(
              onPressed: () => AppNavigation.closeDialog(result: false),
              child: Text('取消'.tr),
            ),
            shadcn.PrimaryButton(
              onPressed: () => AppNavigation.closeDialog(result: true),
              child: Text('删除'.tr),
            ),
          ],
        ),
      );
      if (!(ok ?? false) ||
          !mounted ||
          browser != _browser ||
          localBrowser != _local ||
          directory != (local ? localBrowser.cwd.value : browser.cwd.value) ||
          revision !=
              (local
                  ? localBrowser.navigationRevision
                  : browser.navigationRevision) ||
          (!local && !identical(engine, browser.engine))) {
        return;
      }
      if (local) {
        if (single) {
          await localBrowser.remove(_localEntry(selected.single));
        } else {
          await localBrowser.removeMany(selected.map(_localEntry).toList());
        }
      } else {
        final remote = [
          for (final entry in selected)
            SftpDirEntry(
              name: entry.name,
              isDir: entry.isDir,
              size: entry.size,
            ),
        ];
        if (single) {
          await browser.remove(remote.single);
        } else {
          await browser.removeMany(remote);
        }
      }
    } finally {
      if (local) {
        _deletingLocal = false;
      } else {
        _deletingRemote = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = math.max(
          AppTheme.transferProgressCollapsedHeight,
          constraints.maxHeight - AppTheme.fileBrowserMinHeight,
        );
        final minHeight = math.min(
          AppTheme.transferProgressMinHeight,
          maxHeight,
        );
        final height = _expandedTransferHeight.clamp(minHeight, maxHeight);
        // 窗口缩小时只限制显示高度，保留用户选择的展开高度。
        if (_transferPane.value != height) _transferPane.size = height;
        final fileHeight = math.max(
          0.0,
          constraints.maxHeight -
              (_transferExpanded
                  ? height
                  : AppTheme.transferProgressCollapsedHeight),
        );
        if (_filePane.value != fileHeight) _filePane.size = fileHeight;
        return shadcn.ResizablePanel.vertical(
          key: const ValueKey('sftp-transfer-resizable'),
          // 边框由传输条绘制，折叠时分隔区域必须为零，避免命中拖动光标。
          dividerBuilder: (_) => const SizedBox.shrink(),
          draggerThickness: _transferExpanded ? null : 0,
          draggerBuilder: (_) => _transferExpanded
              ? const shadcn.VerticalResizableDragger(
                  key: ValueKey('sftp-transfer-resize-handle'),
                )
              : const SizedBox.shrink(),
          children: [
            shadcn.ResizablePane.controlled(
              controller: _filePane,
              minSize: math.min(
                AppTheme.fileBrowserMinHeight,
                math.max(
                  0,
                  constraints.maxHeight -
                      AppTheme.transferProgressCollapsedHeight,
                ),
              ),
              child: shadcn.ResizablePanel.horizontal(
                key: const ValueKey('sftp-panes-resizable'),
                dividerBuilder: (_) =>
                    Container(width: 1, color: AppTheme.border(context)),
                draggerBuilder: (_) => const shadcn.HorizontalResizableDragger(
                  key: ValueKey('sftp-panes-resize-handle'),
                ),
                children: [
                  shadcn.ResizablePane.controlled(
                    controller: _localPane,
                    minSize: math.min(
                      180.0,
                      math.max(0.0, (constraints.maxWidth - 8) / 2),
                    ),
                    child: Obx(
                      () => FileBrowserPane(
                        sessionId: widget.session.id,
                        side: FileBrowserSide.local,
                        active: widget.active,
                        cwd: _local.cwd.value.isEmpty
                            ? _local.files.homeDirectory
                            : _local.cwd.value,
                        loading: _local.loading.value,
                        error: _local.error.value,
                        entries: [
                          for (final entry in _local.visibleEntries)
                            FileBrowserEntry(
                              name: entry.name,
                              path: entry.path,
                              isDir: entry.isDir,
                              size: entry.size,
                              modified: entry.modified,
                            ),
                        ],
                        onNavigate: _navigateLocalDirectory,
                        onUp: _local.up,
                        onRefresh: () => _navigateLocalDirectory(
                          _local.cwd.value.isEmpty
                              ? _local.files.homeDirectory
                              : _local.cwd.value,
                        ),
                        onBrowse: _chooseLocalDirectory,
                        onMkdir: _mkdirLocal,
                        onAuthorize: _local.permissionDeniedPath.value == null
                            ? null
                            : () => _authorizeLocalDirectory(
                                _local,
                                _local.permissionDeniedPath.value!,
                                _local.navigationRevision,
                              ),
                        onOpen: (entry) => _navigateLocalDirectory(entry.path),
                        onTransfer: (entries) => _transferFiles(
                          entries,
                          FileBrowserSide.local,
                          _browser.cwd.value,
                        ),
                        onDrop: _dropFiles,
                        onRename: (entry) => _rename(entry, local: true),
                        onMove: _local.files is LocalFileMover
                            ? _moveFiles
                            : null,
                        onEditText: _local.files is SmallTextFileAccess
                            ? (entry) =>
                                  unawaited(_editText(entry, local: true))
                            : null,
                        onDelete: (entry) => _delete(entry, local: true),
                        showHidden: _local.showHidden.value,
                        onShowHiddenChanged: (value) =>
                            _local.showHidden.value = value,
                      ),
                    ),
                  ),
                  shadcn.ResizablePane.controlled(
                    controller: _remotePane,
                    minSize: math.min(
                      180.0,
                      math.max(0.0, (constraints.maxWidth - 8) / 2),
                    ),
                    child: Obx(
                      () => FileBrowserPane(
                        sessionId: widget.session.id,
                        side: FileBrowserSide.remote,
                        active: widget.active,
                        cwd: _browser.cwd.value,
                        loading: _browser.loading.value,
                        error: _browser.error.value,
                        entries: [
                          for (final entry in _browser.entries)
                            if (_showRemoteHidden.value ||
                                !entry.name.startsWith('.'))
                              FileBrowserEntry(
                                name: entry.name,
                                path: _browser.pathOf(entry.name),
                                isDir: entry.isDir,
                                size: entry.size,
                                modified: entry.modified,
                              ),
                        ],
                        onNavigate: _browser.navigate,
                        onUp: _browser.up,
                        onRefresh: _browser.refreshDirectory,
                        onMkdir: _mkdir,
                        onUpload: _upload,
                        onUploadDirectory: _uploadDirectory,
                        onOpen: (entry) => _browser.enter(entry.name),
                        onTransfer: (entries) => _transferFiles(
                          entries,
                          FileBrowserSide.remote,
                          _local.cwd.value,
                        ),
                        onDrop: _dropFiles,
                        onExternalDrop: _uploadExternal,
                        onRename: _rename,
                        onMove: _moveFiles,
                        onEditText: _browser.engine is SmallTextFileAccess
                            ? (entry) =>
                                  unawaited(_editText(entry, local: false))
                            : null,
                        onDelete: _delete,
                        showHidden: _showRemoteHidden.value,
                        onShowHiddenChanged: (value) =>
                            _showRemoteHidden.value = value,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            shadcn.ResizablePane.controlled(
              controller: _transferPane,
              minSize: minHeight,
              collapsedSize: AppTheme.transferProgressCollapsedHeight,
              onSizeChange: _resizeTransfer,
              onSizeChangeCancel: _resizeTransfer,
              child: _TransferStrip(
                sessionId: widget.session.id,
                expanded: _transferExpanded,
                onToggle: _toggleTransferExpanded,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FileConflictDialog extends StatefulWidget {
  const _FileConflictDialog({required this.name});

  final String name;

  @override
  State<_FileConflictDialog> createState() => _FileConflictDialogState();
}

class _FileConflictDialogState extends State<_FileConflictDialog> {
  bool _applyToRemaining = false;

  void _choose(_FileConflictAction action) =>
      AppNavigation.closeDialog<_FileConflictDecision>(
        result: (action: action, applyToRemaining: _applyToRemaining),
      );

  @override
  Widget build(BuildContext context) => AppDialog(
    maxWidth: AppTheme.fileConflictDialogMaxWidth,
    title: Text('覆盖「@name」？'.trParams({'name': widget.name})),
    content: DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目标目录已存在同名文件，是否覆盖？'.tr),
          const SizedBox(height: 12),
          shadcn.Checkbox(
            theme: const shadcn.CheckboxTheme(size: 14, gap: 8),
            state: _applyToRemaining
                ? shadcn.CheckboxState.checked
                : shadcn.CheckboxState.unchecked,
            onChanged: (state) => setState(
              () => _applyToRemaining = state == shadcn.CheckboxState.checked,
            ),
            trailing: Text(
              '后续文件采用相同操作'.tr,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ),
        ],
      ),
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () => AppNavigation.closeDialog<_FileConflictDecision>(),
        child: Text('取消'.tr),
      ),
      shadcn.OutlineButton(
        onPressed: () => _choose(_FileConflictAction.skip),
        child: Text('跳过'.tr),
      ),
      shadcn.PrimaryButton(
        onPressed: () => _choose(_FileConflictAction.overwrite),
        child: Text('覆盖'.tr),
      ),
    ],
  );
}

/// 本会话的传输任务条，默认折叠。
class _TransferStrip extends StatelessWidget {
  const _TransferStrip({
    required this.sessionId,
    required this.expanded,
    required this.onToggle,
  });

  final String sessionId;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TransferController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    return Obx(() {
      final tasks = controller.tasksOf(sessionId);
      final running = tasks
          .where((task) => task.status.value == TransferStatus.running)
          .length;
      final queued = tasks
          .where((task) => task.status.value == TransferStatus.queued)
          .length;
      final failed = tasks
          .where((task) => task.status.value == TransferStatus.failed)
          .length;
      final retryableFailed = tasks
          .where(
            (task) =>
                task.status.value == TransferStatus.failed &&
                !task.retrying.value &&
                controller.canRetry(task),
          )
          .toList();
      final activeCount = running + queued;
      return Container(
        key: const ValueKey('sftp-transfer-progress'),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.border(context))),
        ),
        child: Column(
          children: [
            Stack(
              children: [
                SizedBox(
                  height: AppTheme.transferProgressCollapsedHeight - 1,
                  child: Row(
                    children: [
                      AppIconButton.text(
                        semanticLabel: (expanded ? '折叠传输进度' : '展开传输进度').tr,
                        tooltip: (expanded ? '折叠传输进度' : '展开传输进度').tr,
                        icon: AppIcon(
                          expanded ? AppIcons.chevronDown : AppIcons.chevronUp,
                          size: 15,
                        ),
                        onPressed: onToggle,
                      ),
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            key: const ValueKey('sftp-transfer-header-toggle'),
                            behavior: HitTestBehavior.opaque,
                            onTap: onToggle,
                            child: SizedBox(
                              height: double.infinity,
                              child: Row(
                                children: [
                                  Flexible(
                                    flex: 2,
                                    child: Text(
                                      '传输进度 · @count 项 · @running 项进行中'
                                          .trParams({
                                            'count': '${tasks.length}',
                                            'running': '$running',
                                          }),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.mutedForeground,
                                      ),
                                    ),
                                  ),
                                  if (queued > 0) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '排队 @count'.trParams({
                                        'count': '$queued',
                                      }),
                                      key: const ValueKey(
                                        'sftp-transfer-queued-badge',
                                      ),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.mutedForeground,
                                      ),
                                    ),
                                  ],
                                  if (failed > 0) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      key: const ValueKey(
                                        'sftp-transfer-failed-badge',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colors.destructive.withValues(
                                          alpha: 0.12,
                                        ),
                                        border: Border.all(
                                          color: colors.destructive.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AppIcon(
                                            AppIcons.circleAlert,
                                            size: 11,
                                            color: colors.destructive,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '失败 @count'.trParams({
                                              'count': '$failed',
                                            }),
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: colors.destructive,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 12),
                                  // 速率每次采样都会变化，单独订阅，避免重建
                                  // 整个传输条与任务列表。
                                  Flexible(
                                    child: Obx(
                                      () => Text(
                                        '总速率 @speed'.trParams({
                                          'speed': formatTransferRate(
                                            controller.totalBytesPerSecond(
                                              sessionId,
                                            ),
                                          ),
                                        }),
                                        key: const ValueKey(
                                          'sftp-total-transfer-rate',
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.mutedForeground,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (retryableFailed.isNotEmpty)
                        AppIconButton.text(
                          key: const ValueKey('sftp-transfer-retry-all'),
                          semanticLabel: '全部重试'.tr,
                          tooltip: '全部重试'.tr,
                          icon: const AppIcon(AppIcons.rotateCw, size: 14),
                          onPressed: () {
                            for (final task in retryableFailed) {
                              unawaited(controller.retry(task.id));
                            }
                          },
                        ),
                      if (activeCount > 0)
                        AppIconButton.text(
                          key: const ValueKey('sftp-transfer-cancel-all'),
                          semanticLabel: '全部取消'.tr,
                          tooltip: '全部取消'.tr,
                          icon: const AppIcon(AppIcons.x, size: 14),
                          onPressed: () {
                            for (final task in tasks) {
                              if (task.status.value.active) {
                                unawaited(controller.cancel(task.id));
                              }
                            }
                          },
                        ),
                      AppIconButton.text(
                        semanticLabel: '清除已完成'.tr,
                        tooltip: '清除已完成'.tr,
                        icon: const AppIcon(AppIcons.listX, size: 15),
                        onPressed: () =>
                            controller.clearFinished(sessionId: sessionId),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
                if (running > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: IgnorePointer(
                      child: Obx(() {
                        var total = 0;
                        var transferred = 0;
                        for (final task in tasks) {
                          if (!task.status.value.active) continue;
                          final taskTotal = task.total.value;
                          if (taskTotal <= 0) continue;
                          total += taskTotal;
                          transferred += task.transferred.value.clamp(
                            0,
                            taskTotal,
                          );
                        }
                        if (total <= 0) return const SizedBox.shrink();
                        final fraction = (transferred / total).clamp(0.0, 1.0);
                        return ColoredBox(
                          color: colors.border.withValues(alpha: 0.4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: fraction,
                              child: ColoredBox(
                                color: colors.primary,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  )
                else if (failed > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: IgnorePointer(
                      child: ColoredBox(
                        key: const ValueKey('sftp-transfer-failed-hairline'),
                        color: colors.destructive.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
            if (expanded)
              Expanded(
                child: tasks.isEmpty
                    ? Center(
                        child: Text(
                          '暂无传输任务'.tr,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.mutedForeground,
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('sftp-transfer-list'),
                        padding: EdgeInsets.zero,
                        itemCount: tasks.length,
                        itemBuilder: (_, index) => SizedBox(
                          key: ValueKey('sftp-transfer-row-${tasks[index].id}'),
                          height: AppTheme.transferProgressRowHeight,
                          child: _TransferRow(task: tasks[index]),
                        ),
                      ),
              ),
          ],
        ),
      );
    });
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final controller = Get.find<TransferController>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Obx(() {
        final status = task.status.value;
        final icon = switch (status) {
          TransferStatus.queued || TransferStatus.running =>
            task.kind == TransferKind.upload
                ? AppIcons.upload
                : AppIcons.download,
          TransferStatus.done => AppIcons.circleCheck,
          TransferStatus.failed => AppIcons.circleAlert,
          TransferStatus.cancelled => AppIcons.circleX,
        };
        final color = switch (status) {
          TransferStatus.failed => colors.destructive,
          TransferStatus.done => StatusColors.ready,
          _ => colors.mutedForeground,
        };
        final labelStyle = TextStyle(fontSize: 11, color: color);
        final rawFailureReason = status == TransferStatus.failed
            ? task.error.value?.trim()
            : null;
        final failureReason = rawFailureReason == null
            ? null
            : AppTranslations.error(rawFailureReason);
        final failureMessage = failureReason == null || failureReason.isEmpty
            ? '传输未完成，请检查连接后重试'.tr
            : failureReason;
        final total = task.total.value;
        String? runningDetail() {
          if (status != TransferStatus.running) return null;
          final transferred = task.transferred.value;
          final speed = task.bytesPerSecond.value;
          final fraction = task.fraction;
          final percent = fraction == null ? null : (fraction * 100).round();
          final eta = formatTransferEta(total - transferred, speed);
          final parts = [
            if (percent != null)
              '${formatFileSize(transferred)} / ${formatFileSize(total)} ($percent%)',
            if (speed.isFinite && speed > 0) formatTransferRate(speed),
            if (eta != null) '剩余 @eta'.trParams({'eta': eta}),
          ];
          return parts.isEmpty ? null : parts.join(' · ');
        }

        final label = Text(
          switch (status) {
            TransferStatus.queued => '等待传输'.tr,
            TransferStatus.running ||
            TransferStatus.failed ||
            TransferStatus.cancelled when total <= 0 => '—',
            _ => formatFileSize(total),
          },
          key: ValueKey('sftp-transfer-label-${task.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle,
        );
        final content = Row(
          key: ValueKey('sftp-transfer-content-${task.id}'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _TransferStatusAction(
              key: ValueKey('sftp-transfer-action-${task.id}'),
              icon: icon,
              color: color,
              hoverIcon: status.active ? AppIcons.x : AppIcons.rotateCw,
              loading: task.retrying.value,
              semanticLabel: switch (status) {
                TransferStatus.queued || TransferStatus.running => '停止传输'.tr,
                TransferStatus.failed => '重试传输'.tr,
                _ => '',
              },
              onPressed: switch (status) {
                TransferStatus.queued ||
                TransferStatus.running => () => controller.cancel(task.id),
                TransferStatus.failed
                    when !task.retrying.value && controller.canRetry(task) =>
                  () => controller.retry(task.id),
                _ => null,
              },
            ),
            const SizedBox(width: 6),
            SizedBox(
              key: ValueKey('sftp-transfer-name-${task.id}'),
              width: 140,
              child: Text(
                task.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle.copyWith(
                  color: status == TransferStatus.running
                      ? colors.foreground
                      : color,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: shadcn.ComponentTheme(
                data: shadcn.LinearProgressIndicatorTheme(
                  minHeight: 3,
                  color: status == TransferStatus.running
                      ? colors.primary
                      : color,
                  backgroundColor: status == TransferStatus.failed
                      ? color.withValues(alpha: 0.2)
                      : null,
                ),
                child: shadcn.LinearProgressIndicator(
                  key: ValueKey('sftp-transfer-progress-${task.id}'),
                  value: status == TransferStatus.running
                      ? task.fraction
                      : status == TransferStatus.done
                      ? 1
                      : (task.fraction ?? 0),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: label,
            ),
          ],
        );
        final path = task.currentPath.value;
        final detail = status == TransferStatus.cancelled
            ? '已取消'.tr
            : runningDetail();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 26, child: content),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: SizedBox(
                height: 14,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final gap = math.min(8.0, constraints.maxWidth);
                    final trailingWidth = math.min(
                      220.0,
                      math.max(0.0, (constraints.maxWidth - gap) / 2),
                    );
                    return Row(
                      children: [
                        Expanded(
                          child: shadcn.Tooltip(
                            tooltip: (_) =>
                                shadcn.TooltipContainer(child: Text(path)),
                            child: Text(
                              path,
                              key: ValueKey('sftp-transfer-path-${task.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                        if (status == TransferStatus.failed) ...[
                          SizedBox(width: gap),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: trailingWidth,
                            ),
                            child: shadcn.Tooltip(
                              tooltip: (_) => shadcn.TooltipContainer(
                                child: Text(failureMessage),
                              ),
                              child: Text(
                                failureMessage,
                                key: ValueKey('sftp-transfer-error-${task.id}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.destructive,
                                ),
                              ),
                            ),
                          ),
                        ] else if (detail != null) ...[
                          SizedBox(width: gap),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: (constraints.maxWidth - gap) * 0.7,
                            ),
                            child: shadcn.Tooltip(
                              tooltip: (_) =>
                                  shadcn.TooltipContainer(child: Text(detail)),
                              child: Text(
                                detail,
                                key: ValueKey(
                                  'sftp-transfer-detail-${task.id}',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.mutedForeground,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _TransferStatusAction extends StatefulWidget {
  const _TransferStatusAction({
    required this.icon,
    required this.hoverIcon,
    required this.color,
    required this.semanticLabel,
    required this.onPressed,
    this.loading = false,
    super.key,
  });

  final AppIcons icon;
  final AppIcons hoverIcon;
  final Color color;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  State<_TransferStatusAction> createState() => _TransferStatusActionState();
}

class _TransferStatusActionState extends State<_TransferStatusAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: SizedBox(
      width: 26,
      height: 26,
      child: widget.loading
          ? const Center(
              child: SizedBox(
                width: 13,
                height: 13,
                child: shadcn.CircularProgressIndicator(strokeWidth: 1.8),
              ),
            )
          : widget.onPressed == null
          ? Center(child: AppIcon(widget.icon, size: 13, color: widget.color))
          : AppIconButton.text(
              semanticLabel: widget.semanticLabel,
              tooltip: widget.semanticLabel,
              icon: AppIcon(
                _hovered ? widget.hoverIcon : widget.icon,
                size: 13,
                color: widget.color,
              ),
              onPressed: widget.onPressed,
            ),
    ),
  );
}

String formatTransferRate(double bytesPerSecond) =>
    '${formatFileSize(bytesPerSecond.isFinite ? bytesPerSecond.clamp(0, double.infinity).round() : 0)}/s';

String? formatTransferEta(int remainingBytes, double bytesPerSecond) {
  if (remainingBytes <= 0 || !bytesPerSecond.isFinite || bytesPerSecond < 1) {
    return null;
  }
  final seconds = (remainingBytes / bytesPerSecond).ceil();
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    final minutes = seconds ~/ 60;
    final rem = seconds % 60;
    return rem == 0 ? '${minutes}m' : '${minutes}m ${rem}s';
  }
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String initial = '',
  Future<String?> Function(String name)? onCommit,
}) {
  return AppNavigation.dialog<String>(
    _NameDialog(title: title, initial: initial, onCommit: onCommit),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    this.onCommit,
  });

  final String title;
  final String initial;

  /// Returns a translation key on failure so the name can be corrected.
  final Future<String?> Function(String name)? onCommit;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final name = _controller.text.trim();
    if (widget.onCommit case final commit?) {
      setState(() {
        _saving = true;
        _error = null;
      });
      final error = await commit(name);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (error != null) {
        setState(() {
          _saving = false;
          _error = error;
        });
        return;
      }
    }
    AppNavigation.closeDialog(result: name);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: Text(widget.title.tr),
      maxWidth: AppTheme.folderDialogMaxWidth,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextFormField(
              controller: _controller,
              autofocus: true,
              enabled: !_saving,
              smartPunctuation: false,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              decoration: AppInputDecoration(labelText: '名称'.tr),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '必填'.tr : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      feedback: _error == null
          ? null
          : Text(
              _error!.tr,
              style: TextStyle(
                color: shadcn.Theme.of(context).colorScheme.destructive,
              ),
            ),
      actions: [
        shadcn.OutlineButton(
          onPressed: _saving ? null : () => AppNavigation.closeDialog<void>(),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          onPressed: _saving ? null : _submit,
          child: Text('确定'.tr),
        ),
      ],
    );
  }
}
