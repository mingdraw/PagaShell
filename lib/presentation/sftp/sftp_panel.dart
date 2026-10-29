import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/sftp/local_file_controller.dart';
import '../../application/sftp/sftp_controller.dart';
import '../../application/transfer/transfer_controller.dart';
import '../../domain/entities/local_file_entry.dart';
import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'file_browser_pane.dart';

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
  });

  final Session session;
  final LocalFileRepository localFiles;
  final LocalDirectoryPicker directoryPicker;
  final bool active;

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
  bool _choosingLocalDirectory = false;

  @override
  void initState() {
    super.initState();
    _bindBrowser();
  }

  void _bindBrowser() {
    _tag = 'sftp-${widget.session.id}-${identityHashCode(this)}';
    _browser = Get.put(SftpController(engine: _engine), tag: _tag);
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
    if (oldWidget.session.id != widget.session.id ||
        oldWidget.session.engineSession != widget.session.engineSession ||
        oldWidget.localFiles != widget.localFiles) {
      _releaseBrowser();
      _bindBrowser();
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
    super.dispose();
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
    var skippedDirectory = false;
    for (final file in files) {
      if (!mounted || browser != _browser || local != _local) return;
      if (!seen.add(file.path)) continue;
      if (file is DropItemDirectory) {
        skippedDirectory = true;
        continue;
      }
      final bookmark = file.extraAppleBookmark;
      var started = false;
      Future<void> Function()? release;
      try {
        release = await _acquireExternalSource(bookmark);
        final entry = await local.files.entryAt(file.path);
        if (entry.isDir) {
          skippedDirectory = true;
          continue;
        }
        if (!mounted || browser != _browser || local != _local) return;
        final proceed = await _transferFile(
          FileTransferDrag(
            sessionId: sessionId,
            source: FileBrowserSide.local,
            path: entry.path,
            name: entry.name,
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
    if (skippedDirectory && mounted && browser == _browser) {
      AppNotice.error('拖入上传仅支持文件，已跳过文件夹'.tr);
    }
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
    for (final file in files.where((entry) => !entry.isDir)) {
      if (!mounted || browser != _browser || local != _local) return;
      final proceed = await _transferFile(
        FileTransferDrag(
          sessionId: sessionId,
          source: source,
          path: file.path,
          name: file.name,
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

  /// false 表示取消或连接已变更，调用方应停止本批次；跳过仍继续。
  Future<bool> _transferFile(
    FileTransferDrag data,
    String directory,
    _TransferBatch batch, {
    Future<void> Function()? releaseUploadSource,
    TransferSourceAccess? acquireUploadSource,
    VoidCallback? onUploadStarted,
  }) async {
    if (!mounted || data.sessionId != widget.session.id) return false;
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
                task.status.value == TransferStatus.running &&
                (upload
                    ? task.kind == TransferKind.upload &&
                          task.remotePath == remotePath
                    : task.kind == TransferKind.download &&
                          task.localPath == localPath),
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
      if (isDir) {
        AppNotice.error('目标位置存在同名目录'.tr);
        return true;
      }
      if (exists) {
        var action = batch.conflictAction;
        if (action == null) {
          final decision = await AppNavigation.dialog<_FileConflictDecision>(
            _FileConflictDialog(name: data.name),
          );
          if (decision == null) return false;
          if (!mounted || browser != _browser || local != _local) return false;
          action = decision.action;
          if (decision.applyToRemaining) batch.conflictAction = action;
        }
        if (action == _FileConflictAction.skip) return true;
      }
      if (!mounted || browser != _browser || local != _local) {
        return false;
      }
      if (isRunning()) return true;
      final task = upload
          ? controller.startUpload(
              sessionId: sessionId,
              engineSession: engine,
              localPath: localPath,
              remotePath: remotePath,
              releaseSource: releaseUploadSource,
              acquireSource: acquireUploadSource,
            )
          : controller.startDownload(
              sessionId: sessionId,
              engineSession: engine,
              remotePath: remotePath,
              localPath: localPath,
            );
      if (upload) onUploadStarted?.call();
      _refreshAfterTransfer(task);
      return true;
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
            ? _browser.refreshDirectory()
            : _local.refreshDirectory(),
      );
    }

    if (task.status.value != TransferStatus.running) {
      refresh();
      return;
    }
    late Worker worker;
    worker = ever(task.status, (status) {
      if (status == TransferStatus.running) return;
      if (status != TransferStatus.failed) {
        worker.dispose();
        _transferWorkers.remove(worker);
      }
      refresh();
    });
    _transferWorkers.add(worker);
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

  Future<void> _delete(FileBrowserEntry entry, {bool local = false}) async {
    final browser = _browser;
    final localBrowser = _local;
    final directory = local ? localBrowser.cwd.value : browser.cwd.value;
    final ok = await AppNavigation.dialog<bool>(
      AppDialog(
        title: Text('删除「@name」？'.trParams({'name': entry.name})),
        content: Text(entry.isDir ? '将递归删除该目录及其全部内容。'.tr : '该操作不可撤销。'.tr),
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
        directory != (local ? localBrowser.cwd.value : browser.cwd.value)) {
      return;
    }
    if (local) {
      await localBrowser.remove(_localEntry(entry));
    } else {
      await browser.remove(
        SftpDirEntry(name: entry.name, isDir: entry.isDir, size: entry.size),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Obx(
                  () => FileBrowserPane(
                    sessionId: widget.session.id,
                    side: FileBrowserSide.local,
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
                    onRefresh: () => _navigateLocalDirectory(
                      _local.cwd.value.isEmpty
                          ? _local.files.homeDirectory
                          : _local.cwd.value,
                    ),
                    onBrowse: _chooseLocalDirectory,
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
                    onDelete: (entry) => _delete(entry, local: true),
                    showHidden: _local.showHidden.value,
                    onShowHiddenChanged: (value) =>
                        _local.showHidden.value = value,
                  ),
                ),
              ),
              Container(width: 1, color: AppTheme.border(context)),
              Expanded(
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
                        FileBrowserEntry(
                          name: entry.name,
                          path: _browser.pathOf(entry.name),
                          isDir: entry.isDir,
                          size: entry.size,
                          modified: entry.modified,
                        ),
                    ],
                    onNavigate: _browser.navigate,
                    onRefresh: _browser.refreshDirectory,
                    onMkdir: _mkdir,
                    onUpload: _upload,
                    onOpen: (entry) => _browser.enter(entry.name),
                    onTransfer: (entries) => _transferFiles(
                      entries,
                      FileBrowserSide.remote,
                      _local.cwd.value,
                    ),
                    onDrop: _dropFiles,
                    onExternalDrop: _uploadExternal,
                    onRename: _rename,
                    onDelete: _delete,
                  ),
                ),
              ),
            ],
          ),
        ),
        _TransferStrip(sessionId: widget.session.id),
      ],
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
class _TransferStrip extends StatefulWidget {
  const _TransferStrip({required this.sessionId});

  final String sessionId;

  @override
  State<_TransferStrip> createState() => _TransferStripState();
}

class _TransferStripState extends State<_TransferStrip> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_TransferStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TransferController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    return Obx(() {
      final tasks = controller.tasksOf(widget.sessionId);
      final running = tasks
          .where((task) => task.status.value == TransferStatus.running)
          .length;
      return Container(
        key: const ValueKey('sftp-transfer-progress'),
        height: _expanded ? 144 : 36,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.border(context))),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 35,
              child: Row(
                children: [
                  AppIconButton.text(
                    semanticLabel: (_expanded ? '折叠传输进度' : '展开传输进度').tr,
                    icon: Icon(
                      _expanded
                          ? shadcn.LucideIcons.chevronDown
                          : shadcn.LucideIcons.chevronUp,
                      size: 15,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          '传输进度 · @count 项 · @running 项进行中'.trParams({
                            'count': '${tasks.length}',
                            'running': '$running',
                          }),
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.mutedForeground,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            '总速率 @speed'.trParams({
                              'speed': formatTransferRate(
                                controller.totalBytesPerSecond(
                                  widget.sessionId,
                                ),
                              ),
                            }),
                            key: const ValueKey('sftp-total-transfer-rate'),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AppIconButton.text(
                    semanticLabel: '清除已完成'.tr,
                    icon: const Icon(shadcn.LucideIcons.listX, size: 15),
                    onPressed: () =>
                        controller.clearFinished(sessionId: widget.sessionId),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            if (_expanded)
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
                          height: 30,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Obx(() {
        final status = task.status.value;
        final icon = switch (status) {
          TransferStatus.running =>
            task.kind == TransferKind.upload
                ? shadcn.LucideIcons.upload
                : shadcn.LucideIcons.download,
          TransferStatus.done => shadcn.LucideIcons.circleCheck,
          TransferStatus.failed => shadcn.LucideIcons.circleAlert,
          TransferStatus.cancelled => shadcn.LucideIcons.circleX,
        };
        final color = switch (status) {
          TransferStatus.failed => colors.destructive,
          TransferStatus.done => StatusColors.ready,
          _ => colors.mutedForeground,
        };
        final labelStyle = TextStyle(fontSize: 11, color: color);
        final failureReason = status == TransferStatus.failed
            ? task.error.value?.trim()
            : null;
        final label = Text(
          switch (status) {
            TransferStatus.failed =>
              failureReason == null || failureReason.isEmpty
                  ? '传输未完成，请检查连接后重试'.tr
                  : failureReason,
            TransferStatus.cancelled => '已取消'.tr,
            _ => formatFileSize(task.transferred.value),
          },
          key: ValueKey('sftp-transfer-label-${task.id}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _TransferStatusAction(
              key: ValueKey('sftp-transfer-action-${task.id}'),
              icon: icon,
              color: color,
              hoverIcon: status == TransferStatus.running
                  ? shadcn.LucideIcons.x
                  : shadcn.LucideIcons.rotateCw,
              semanticLabel: switch (status) {
                TransferStatus.running => '停止传输'.tr,
                TransferStatus.failed => '重试传输'.tr,
                _ => '',
              },
              onPressed: switch (status) {
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
              child: status == TransferStatus.failed
                  ? shadcn.Tooltip(
                      tooltip: (_) =>
                          shadcn.TooltipContainer(child: Text(label.data!)),
                      child: label,
                    )
                  : label,
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
    super.key,
  });

  final IconData icon;
  final IconData hoverIcon;
  final Color color;
  final String semanticLabel;
  final VoidCallback? onPressed;

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
      child: widget.onPressed == null
          ? Center(child: Icon(widget.icon, size: 13, color: widget.color))
          : AppIconButton.text(
              semanticLabel: widget.semanticLabel,
              icon: Icon(
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

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return AppNavigation.dialog<String>(
    _NameDialog(title: title, initial: initial),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    AppNavigation.closeDialog(result: _controller.text.trim());
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
              autovalidateMode: AutovalidateMode.onUserInteraction,
              decoration: AppInputDecoration(labelText: '名称'.tr),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '必填'.tr : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<void>(),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(onPressed: _submit, child: Text('确定'.tr)),
      ],
    );
  }
}
