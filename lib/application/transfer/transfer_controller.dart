import 'dart:async';
import 'dart:collection';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import 'directory_transfer.dart';

enum TransferKind { upload, download }

enum TransferStatus { running, done, failed, cancelled }

typedef TransferSourceAccess = Future<Future<void> Function()> Function();

class _TransferRequest {
  const _TransferRequest(this.open, this.acquireSource);
  final Stream<SftpTransferProgress> Function() open;
  final TransferSourceAccess? acquireSource;
}

/// 单个传输任务。进度/状态字段为响应式，UI 可直接在 Obx 中绑定。
class TransferTask {
  TransferTask({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.fileName,
    required this.remotePath,
    required this.localPath,
    this.isDirectory = false,
  }) : currentPath = (kind == TransferKind.upload ? localPath : remotePath).obs;

  final String id;
  final String sessionId;
  final TransferKind kind;
  final String fileName;
  final String remotePath;
  final String localPath;
  final bool isDirectory;
  final RxString currentPath;

  final Rx<TransferStatus> status = TransferStatus.running.obs;
  final RxInt transferred = 0.obs;
  final RxInt total = 0.obs;
  final RxDouble bytesPerSecond = 0.0.obs;
  final RxnString error = RxnString();
  final RxBool retrying = false.obs;

  /// 完成比例（0~1）；大小未知时为 null（UI 显示不定进度条）。
  double? get fraction => total.value <= 0
      ? null
      : (transferred.value / total.value).clamp(0.0, 1.0).toDouble();

  /// 目录任务占用整个目标树，避免重试或另一项操作并行写入子文件。
  bool conflictsWithTarget({
    required TransferKind kind,
    required String localPath,
    required String remotePath,
    bool isDirectory = false,
  }) {
    if (this.kind != kind) return false;
    final own = kind == TransferKind.upload ? this.remotePath : this.localPath;
    final target = kind == TransferKind.upload ? remotePath : localPath;
    final windows =
        kind == TransferKind.download &&
        (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(own) || own.startsWith(r'\\'));
    final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    return paths.equals(own, target) ||
        (this.isDirectory && paths.isWithin(own, target)) ||
        (isDirectory && paths.isWithin(target, own));
  }
}

/// 传输队列控制器：发起上传/下载、跟踪进度、取消与清理。
///
/// 引擎会话由调用方（SFTP 面板）传入，本控制器无静态依赖。
class TransferController extends GetxController {
  TransferController({Duration Function()? elapsed})
    : _elapsed = elapsed ?? _monotonicClock();

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final Duration Function() _elapsed;
  static const _rateWindow = Duration(seconds: 3);

  /// 进度写入 Rx 的最小间隔。引擎每 512KB 上报一次，高吞吐时可达每秒数百次，
  /// 逐条写入会让绑定进度的 Obx 跟着重建；首个事件立即生效，之后合并到该间隔。
  static const progressInterval = Duration(milliseconds: 200);
  final Map<String, SftpTransferProgress> _pendingProgress = {};
  final Map<String, Timer> _progressTimers = {};
  final Map<String, ListQueue<({Duration time, int bytes})>> _rateSamples = {};
  Timer? _rateTimer;

  /// 全部传输任务，新任务在前。
  final RxList<TransferTask> tasks = <TransferTask>[].obs;

  final Map<String, StreamSubscription<SftpTransferProgress>> _subs = {};
  final Map<String, Future<void> Function()> _sourceReleases = {};
  final Map<String, _TransferRequest> _requests = {};
  final Map<String, Future<void>> _cleanup = {};
  final Map<String, Object> _retryAttempts = {};
  bool _disposed = false;
  int _nextId = 1;

  /// 某会话的任务（新任务在前，供面板传输条展示）。
  List<TransferTask> tasksOf(String sessionId) =>
      tasks.where((t) => t.sessionId == sessionId).toList();

  double totalBytesPerSecond(String sessionId) =>
      tasksOf(sessionId)
          .where((task) => task.status.value == TransferStatus.running)
          .fold(0.0, (sum, task) => sum + task.bytesPerSecond.value);

  void _sampleRates() {
    final now = _elapsed();
    for (final task in tasks) {
      final samples = _rateSamples[task.id];
      if (samples == null || task.status.value != TransferStatus.running) {
        continue;
      }
      final transferred = task.transferred.value;
      if (now <= samples.last.time) continue;
      samples.add((time: now, bytes: transferred));
      // 保留窗口起点，平滑分块进度上报之间的短暂空档。
      final cutoff = now - _rateWindow;
      while (samples.length > 1 && samples.elementAt(1).time <= cutoff) {
        samples.removeFirst();
      }
      final previous = samples.first;
      final microseconds = (now - previous.time).inMicroseconds;
      if (microseconds <= 0) continue;
      final delta = (transferred - previous.bytes).clamp(0, transferred);
      task.bytesPerSecond.value =
          delta * Duration.microsecondsPerSecond / microseconds;
    }
  }

  void _onProgress(TransferTask task, SftpTransferProgress progress) {
    if (progress.currentPath case final path?) task.currentPath.value = path;
    if (_progressTimers.containsKey(task.id)) {
      _pendingProgress[task.id] = progress;
      return;
    }
    _applyProgress(task, progress);
    _progressTimers[task.id] = Timer(
      progressInterval,
      () => _onProgressTick(task),
    );
  }

  void _onProgressTick(TransferTask task) {
    _progressTimers.remove(task.id);
    final pending = _pendingProgress.remove(task.id);
    if (pending == null) return;
    _applyProgress(task, pending);
    _progressTimers[task.id] = Timer(
      progressInterval,
      () => _onProgressTick(task),
    );
  }

  /// 流结束、失败或取消前把尚未写入的最后进度落到 Rx。
  void _flushProgress(TransferTask task) {
    _progressTimers.remove(task.id)?.cancel();
    final pending = _pendingProgress.remove(task.id);
    if (pending != null) _applyProgress(task, pending);
  }

  static void _applyProgress(TransferTask task, SftpTransferProgress p) {
    task.transferred.value = p.transferred;
    task.total.value = p.total;
  }

  void _finishRate(TransferTask task) {
    task.bytesPerSecond.value = 0;
    _rateSamples.remove(task.id);
    if (_rateSamples.isEmpty) {
      _rateTimer?.cancel();
      _rateTimer = null;
    }
  }

  TransferTask startDownload({
    required String sessionId,
    required SshEngineSession engineSession,
    required String remotePath,
    required String localPath,
    bool isDirectory = false,
    LocalFileRepository? localFiles,
    DirectoryConflictResolver? onConflict,
    DirectoryAccessRequest? authorizeLocalDirectory,
  }) {
    Stream<SftpTransferProgress> open() => isDirectory
        ? transferDirectory(
            engine: engineSession,
            localFiles:
                localFiles ?? (throw ArgumentError.notNull('localFiles')),
            localPath: localPath,
            remotePath: remotePath,
            upload: false,
            onConflict: onConflict,
            authorizeLocalDirectory: authorizeLocalDirectory,
          )
        : engineSession.download(remotePath, localPath);
    return _start(
      sessionId: sessionId,
      kind: TransferKind.download,
      fileName: _baseName(remotePath),
      remotePath: remotePath,
      localPath: localPath,
      isDirectory: isDirectory,
      progress: open(),
      request: _TransferRequest(open, null),
    );
  }

  TransferTask startUpload({
    required String sessionId,
    required SshEngineSession engineSession,
    required String localPath,
    required String remotePath,
    Future<void> Function()? releaseSource,
    TransferSourceAccess? acquireSource,
    bool isDirectory = false,
    LocalFileRepository? localFiles,
    DirectoryConflictResolver? onConflict,
    DirectoryAccessRequest? authorizeLocalDirectory,
  }) {
    Stream<SftpTransferProgress> open() => isDirectory
        ? transferDirectory(
            engine: engineSession,
            localFiles:
                localFiles ?? (throw ArgumentError.notNull('localFiles')),
            localPath: localPath,
            remotePath: remotePath,
            upload: true,
            onConflict: onConflict,
            authorizeLocalDirectory: authorizeLocalDirectory,
          )
        : engineSession.upload(localPath, remotePath);
    return _start(
      sessionId: sessionId,
      kind: TransferKind.upload,
      fileName: _baseName(localPath),
      remotePath: remotePath,
      localPath: localPath,
      isDirectory: isDirectory,
      progress: open(),
      releaseSource: releaseSource,
      request: _TransferRequest(open, acquireSource),
    );
  }

  /// 源文件的临时访问权限覆盖整个流，包括取消时引擎的收尾过程。
  Future<void> _releaseSource(String taskId) async {
    final release = _sourceReleases.remove(taskId);
    await release?.call();
  }

  TransferTask _start({
    required String sessionId,
    required TransferKind kind,
    required String fileName,
    required String remotePath,
    required String localPath,
    required Stream<SftpTransferProgress> progress,
    bool isDirectory = false,
    Future<void> Function()? releaseSource,
    required _TransferRequest request,
  }) {
    final task = TransferTask(
      id: 'tx-${_nextId++}',
      sessionId: sessionId,
      kind: kind,
      fileName: fileName,
      remotePath: remotePath,
      localPath: localPath,
      isDirectory: isDirectory,
    );
    tasks.insert(0, task);
    _requests[task.id] = request;
    if (releaseSource != null) _sourceReleases[task.id] = releaseSource;
    _listen(task, progress);
    return task;
  }

  void _listen(TransferTask task, Stream<SftpTransferProgress> progress) {
    _rateSamples[task.id] = ListQueue()..add((time: _elapsed(), bytes: 0));
    _rateTimer ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sampleRates(),
    );

    _subs[task.id] = progress.listen(
      (p) => _onProgress(task, p),
      onError: (Object e, StackTrace _) {
        _flushProgress(task);
        if (e is DirectoryTransferCancelled) {
          task.status.value = TransferStatus.cancelled;
          _requests.remove(task.id);
        } else {
          task.error.value = _errorMessage(e);
          task.status.value = TransferStatus.failed;
        }
        _finishRate(task);
        _cleanup[task.id] =
            _subs
                .remove(task.id)
                ?.cancel()
                .whenComplete(() => _releaseSource(task.id)) ??
            _releaseSource(task.id);
      },
      onDone: () {
        _flushProgress(task);
        _subs.remove(task.id);
        if (task.status.value == TransferStatus.running) {
          task.status.value = TransferStatus.done;
        }
        _finishRate(task);
        _cleanup[task.id] = _releaseSource(task.id);
        _requests.remove(task.id);
      },
    );
  }

  bool canRetry(TransferTask task) =>
      !_disposed && _requests.containsKey(task.id);

  /// 原任务从头传输，防止连点以及同一目标的并行写入。
  Future<void> retry(String taskId) async {
    final task = tasks.firstWhereOrNull((task) => task.id == taskId);
    final request = _requests[taskId];
    if (_disposed ||
        task == null ||
        request == null ||
        task.status.value != TransferStatus.failed ||
        task.retrying.value) {
      return;
    }
    bool targetBusy() => tasks.any(
      (other) =>
          other.id != taskId &&
          other.sessionId == task.sessionId &&
          other.kind == task.kind &&
          (other.status.value == TransferStatus.running ||
              other.retrying.value) &&
          other.conflictsWithTarget(
            kind: task.kind,
            localPath: task.localPath,
            remotePath: task.remotePath,
            isDirectory: task.isDirectory,
          ),
    );
    if (targetBusy()) return;
    final attempt = Object();
    _retryAttempts[taskId] = attempt;
    task.retrying.value = true;
    bool current() =>
        !_disposed &&
        identical(_retryAttempts[taskId], attempt) &&
        _requests.containsKey(taskId);
    Future<void> Function()? release;
    try {
      await _cleanup[taskId];
      if (!current()) return;
      release = await request.acquireSource?.call();
      if (!current() || targetBusy()) return;
      final progress = request.open();
      task.transferred.value = 0;
      task.total.value = 0;
      task.currentPath.value = task.kind == TransferKind.upload
          ? task.localPath
          : task.remotePath;
      task.bytesPerSecond.value = 0;
      task.error.value = null;
      task.status.value = TransferStatus.running;
      if (release != null) _sourceReleases[taskId] = release;
      release = null;
      _listen(task, progress);
    } on Object catch (e) {
      if (current()) {
        task.error.value = _errorMessage(e);
        task.status.value = TransferStatus.failed;
      }
    } finally {
      await release?.call();
      if (identical(_retryAttempts[taskId], attempt)) {
        _retryAttempts.remove(taskId);
        task.retrying.value = false;
      }
    }
  }

  /// 取消进行中的任务；引擎侧会停止传输并清理半成品文件。
  Future<void> cancel(String taskId) async {
    final sub = _subs.remove(taskId);
    if (sub == null) return;
    // 先标记状态：取消订阅后引擎流不再投递任何事件。
    for (final task in tasks) {
      if (task.id == taskId) {
        _flushProgress(task);
        task.status.value = TransferStatus.cancelled;
        _finishRate(task);
        break;
      }
    }
    try {
      await sub.cancel();
    } finally {
      await _releaseSource(taskId);
    }
  }

  /// 关闭文件传输标签时，只取消该连接的在途任务。
  Future<void> cancelSession(String sessionId) async {
    for (final task in tasksOf(sessionId)) {
      _retryAttempts.remove(task.id);
      task.retrying.value = false;
      _requests.remove(task.id);
    }
    await Future.wait([
      for (final task in tasksOf(sessionId))
        if (task.status.value == TransferStatus.running) cancel(task.id),
    ]);
  }

  /// 清掉已结束（完成/失败/取消）的任务。
  void clearFinished({String? sessionId}) {
    final finished = tasks
        .where(
          (task) =>
              task.status.value != TransferStatus.running &&
              !task.retrying.value &&
              (sessionId == null || task.sessionId == sessionId),
        )
        .toList();
    for (final task in finished) {
      _requests.remove(task.id);
      _cleanup.remove(task.id);
      tasks.remove(task);
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _requests.clear();
    _retryAttempts.clear();
    _rateTimer?.cancel();
    _rateTimer = null;
    _rateSamples.clear();
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    _pendingProgress.clear();
    for (final task in tasks) {
      task.bytesPerSecond.value = 0;
      task.retrying.value = false;
    }
    for (final entry in _subs.entries.toList()) {
      unawaited(
        entry.value.cancel().whenComplete(() => _releaseSource(entry.key)),
      );
    }
    _subs.clear();
    super.onClose();
  }

  static String _errorMessage(Object error) => switch (error) {
    SshEngineException() => error.message,
    LocalDirectoryAccessDenied() => '需要授权才能访问此文件夹',
    _ => error.toString(),
  };

  /// 取路径最后一段作为展示名（远端为 POSIX，本地兼容 Windows 分隔符）。
  static String _baseName(String path) {
    final segments = path
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? path : segments.last;
  }
}
