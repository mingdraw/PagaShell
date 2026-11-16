import 'dart:async';
import 'dart:collection';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../../domain/repositories/local_file_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import 'directory_transfer.dart';
import 'transfer_limiter.dart';

enum TransferKind { upload, download }

enum TransferStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  bool get active => this == queued || this == running;
}

typedef TransferSourceAccess = Future<Future<void> Function()> Function();

class _TransferRequest {
  _TransferRequest(this.engine, this.open, this.acquireSource);
  SshEngineSession engine;
  final Stream<SftpTransferProgress> Function(
    SshEngineSession engine,
    bool resume,
  )
  open;
  final TransferSourceAccess? acquireSource;
  bool started = false;
  bool needsInitialAccess = false;
}

class _TransferAcquisition {
  final done = Completer<void>();
  bool cancelled = false;
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
  TransferController({
    Duration Function()? elapsed,
    this.maxConcurrentFiles = 3,
  }) : assert(maxConcurrentFiles > 0),
       _elapsed = elapsed ?? _monotonicClock();

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final Duration Function() _elapsed;
  final int maxConcurrentFiles;
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
  final Set<String> _disconnectedSessions = {};
  final Map<String, TransferLimiter> _limiters = {};
  final Map<String, Completer<void>> _pendingInitialAccess = {};
  final Map<String, _TransferAcquisition> _acquiring = {};
  final Set<String> _closingSessions = {};
  bool _disposed = false;
  int _nextId = 1;

  TransferLimiter _limiter(String sessionId) => _limiters.putIfAbsent(
    sessionId,
    () => TransferLimiter(maxConcurrentFiles),
  );

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
    final directoryState = DirectoryTransferState();
    Stream<SftpTransferProgress> open(SshEngineSession engine, bool resume) =>
        isDirectory
        ? transferDirectory(
            engine: engine,
            localFiles:
                localFiles ?? (throw ArgumentError.notNull('localFiles')),
            localPath: localPath,
            remotePath: remotePath,
            upload: false,
            onConflict: onConflict,
            authorizeLocalDirectory: authorizeLocalDirectory,
            state: directoryState,
            resume: resume,
            scheduleFile: (open) => _limiter(sessionId).schedule(open),
            maxPendingFiles: maxConcurrentFiles,
          )
        : openSftpFile(
            engine: engine,
            localPath: localPath,
            remotePath: remotePath,
            upload: false,
            resume: resume,
          );
    return _start(
      sessionId: sessionId,
      kind: TransferKind.download,
      fileName: _baseName(remotePath),
      remotePath: remotePath,
      localPath: localPath,
      isDirectory: isDirectory,
      request: _TransferRequest(engineSession, open, null),
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
    final directoryState = DirectoryTransferState();
    Stream<SftpTransferProgress> open(SshEngineSession engine, bool resume) =>
        isDirectory
        ? transferDirectory(
            engine: engine,
            localFiles:
                localFiles ?? (throw ArgumentError.notNull('localFiles')),
            localPath: localPath,
            remotePath: remotePath,
            upload: true,
            onConflict: onConflict,
            authorizeLocalDirectory: authorizeLocalDirectory,
            state: directoryState,
            resume: resume,
            scheduleFile: (open) => _limiter(sessionId).schedule(open),
            maxPendingFiles: maxConcurrentFiles,
          )
        : openSftpFile(
            engine: engine,
            localPath: localPath,
            remotePath: remotePath,
            upload: true,
            resume: resume,
          );
    return _start(
      sessionId: sessionId,
      kind: TransferKind.upload,
      fileName: _baseName(localPath),
      remotePath: remotePath,
      localPath: localPath,
      isDirectory: isDirectory,
      releaseSource: releaseSource,
      request: _TransferRequest(engineSession, open, acquireSource),
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
    if (releaseSource != null) {
      _sourceReleases[task.id] = releaseSource;
    }
    _launch(task, request, resume: false);
    return task;
  }

  void _launch(
    TransferTask task,
    _TransferRequest request, {
    required bool resume,
  }) {
    Stream<SftpTransferProgress> open() {
      request.started = true;
      return request.open(request.engine, resume);
    }

    Stream<SftpTransferProgress> openWithAccess() {
      if (!request.needsInitialAccess) return open();
      final cancelled = Completer<void>();
      StreamSubscription<SftpTransferProgress>? source;
      var finished = false;
      late final StreamController<SftpTransferProgress> output;

      Future<void> start() async {
        Future<void> Function()? release;
        final acquisition = _TransferAcquisition();
        _acquiring[task.id] = acquisition;
        try {
          await _pendingInitialAccess[task.id]?.future;
          if (cancelled.isCompleted || acquisition.cancelled) return;
          release = await request.acquireSource!();
          if (cancelled.isCompleted || acquisition.cancelled) return;
          _sourceReleases[task.id] = release;
          release = null;
          request.needsInitialAccess = false;
          source = open().listen(
            output.add,
            onError: output.addError,
            onDone: () {
              finished = true;
              unawaited(output.close());
            },
          );
        } on Object catch (error, stack) {
          if (!cancelled.isCompleted) {
            output.addError(error, stack);
            finished = true;
            unawaited(output.close());
          }
        } finally {
          try {
            await release?.call();
          } finally {
            if (identical(_acquiring[task.id], acquisition)) {
              _acquiring.remove(task.id);
            }
            acquisition.done.complete();
          }
        }
      }

      output = StreamController<SftpTransferProgress>(
        sync: true,
        onListen: () => unawaited(start()),
        onCancel: () async {
          if (!cancelled.isCompleted) cancelled.complete();
          final acquisition = _acquiring[task.id];
          if (acquisition != null) acquisition.cancelled = true;
          if (!finished) await source?.cancel();
        },
      );
      return output.stream;
    }

    final progress = task.isDirectory
        ? open()
        : _limiter(task.sessionId).schedule(
            openWithAccess,
            onQueued: () {
              if (task.status.value.active) {
                task.status.value = TransferStatus.queued;
              }
              if (_sourceReleases.containsKey(task.id) &&
                  request.acquireSource != null) {
                request.needsInitialAccess = true;
                final pending = Completer<void>();
                _pendingInitialAccess[task.id] = pending;
                unawaited(() async {
                  try {
                    await _releaseSource(task.id);
                  } on Object {
                    // 由系统回收权限；后续获取仍单独校验。
                  } finally {
                    if (identical(_pendingInitialAccess[task.id], pending)) {
                      _pendingInitialAccess.remove(task.id);
                    }
                    pending.complete();
                  }
                }());
              }
              _finishRate(task);
            },
            onStarted: () {
              if (task.status.value == TransferStatus.queued) {
                task.status.value = TransferStatus.running;
              }
              _startRate(task);
            },
          );
    _listen(task, progress);
  }

  void _startRate(TransferTask task) {
    _rateSamples[task.id] = ListQueue()
      ..add((time: _elapsed(), bytes: task.transferred.value));
    _rateTimer ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sampleRates(),
    );
  }

  void _listen(TransferTask task, Stream<SftpTransferProgress> progress) {
    if (task.isDirectory) _startRate(task);

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
      !_disposed &&
      !_disconnectedSessions.contains(task.sessionId) &&
      _requests.containsKey(task.id);

  /// 重连前等待旧传输收尾，保留失败记录与请求，供新连接手动重试。
  Future<void> interruptSession(String sessionId) async {
    _disconnectedSessions.add(sessionId);
    _limiters[sessionId]?.pause();
    final pending = <Future<void>>[];
    for (final task in tasksOf(sessionId)) {
      final initialAccess = _pendingInitialAccess[task.id];
      _retryAttempts.remove(task.id);
      _acquiring[task.id]?.cancelled = true;
      task.retrying.value = false;
      if (task.status.value.active) {
        final sub = _subs.remove(task.id);
        _flushProgress(task);
        task.error.value = SshEngineException.connectionClosedMessage;
        task.status.value = TransferStatus.failed;
        _finishRate(task);
        _cleanup[task.id] = sub == null
            ? _releaseSource(task.id)
            : sub.cancel().whenComplete(() => _releaseSource(task.id));
      }
      if (_cleanup[task.id] case final cleanup?) pending.add(cleanup);
      if (initialAccess != null) pending.add(initialAccess.future);
      if (_acquiring[task.id] case final acquisition?) {
        pending.add(acquisition.done.future);
      }
    }
    await Future.wait(pending);
  }

  void bindSession(String sessionId, SshEngineSession engine) {
    if (_disposed || _closingSessions.contains(sessionId)) return;
    for (final task in tasksOf(sessionId)) {
      _requests[task.id]?.engine = engine;
    }
    _disconnectedSessions.remove(sessionId);
    _limiters[sessionId]?.resume();
  }

  /// 失败任务从已校验的位置续传，防止连点及同一目标的并行写入。
  Future<void> retry(String taskId) async {
    final task = tasks.firstWhereOrNull((task) => task.id == taskId);
    final request = _requests[taskId];
    if (_disposed ||
        task == null ||
        request == null ||
        _disconnectedSessions.contains(task.sessionId) ||
        _closingSessions.contains(task.sessionId) ||
        task.status.value != TransferStatus.failed ||
        task.retrying.value) {
      return;
    }
    bool targetBusy() => tasks.any(
      (other) =>
          other.id != taskId &&
          other.sessionId == task.sessionId &&
          other.kind == task.kind &&
          (other.status.value.active || other.retrying.value) &&
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
    final acquisition = _TransferAcquisition();
    _acquiring[taskId] = acquisition;
    bool current() =>
        !_disposed &&
        identical(_retryAttempts[taskId], attempt) &&
        !acquisition.cancelled &&
        !_disconnectedSessions.contains(task.sessionId) &&
        _requests.containsKey(taskId);
    Future<void> Function()? release;
    try {
      await _cleanup[taskId];
      if (!current()) return;
      await _pendingInitialAccess[taskId]?.future;
      if (!current()) return;
      release = await request.acquireSource?.call();
      if (!current() || targetBusy()) return;
      final resume = request.started;
      task.transferred.value = 0;
      task.total.value = 0;
      task.currentPath.value = task.kind == TransferKind.upload
          ? task.localPath
          : task.remotePath;
      task.bytesPerSecond.value = 0;
      task.error.value = null;
      task.status.value = TransferStatus.running;
      if (release != null) _sourceReleases[taskId] = release;
      request.needsInitialAccess = false;
      release = null;
      if (identical(_acquiring[taskId], acquisition)) {
        _acquiring.remove(taskId);
      }
      _launch(task, request, resume: resume);
    } on Object catch (e) {
      if (current()) {
        task.error.value = _errorMessage(e);
        task.status.value = TransferStatus.failed;
      }
    } finally {
      try {
        await release?.call();
      } finally {
        if (identical(_retryAttempts[taskId], attempt)) {
          _retryAttempts.remove(taskId);
          task.retrying.value = false;
        }
        if (identical(_acquiring[taskId], acquisition)) {
          _acquiring.remove(taskId);
        }
        acquisition.done.complete();
      }
    }
  }

  /// 取消进行中的任务；引擎侧停止传输并释放句柄，保留已写入的文件。
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
    final cleanup = sub.cancel().whenComplete(() => _releaseSource(taskId));
    _cleanup[taskId] = cleanup;
    await cleanup;
    await _pendingInitialAccess[taskId]?.future;
  }

  /// 关闭文件传输标签时，只取消该连接的在途任务。
  Future<void> cancelSession(String sessionId) async {
    _closingSessions.add(sessionId);
    _limiters[sessionId]?.pause();
    final initialAccess = [
      for (final task in tasksOf(sessionId))
        if (_pendingInitialAccess[task.id] case final pending?) pending.future,
    ];
    for (final task in tasksOf(sessionId)) {
      _retryAttempts.remove(task.id);
      _acquiring[task.id]?.cancelled = true;
      task.retrying.value = false;
      _requests.remove(task.id);
    }
    await Future.wait([
      for (final task in tasksOf(sessionId))
        if (task.status.value.active) cancel(task.id) else ?_cleanup[task.id],
      ...initialAccess,
    ]);
    _disconnectedSessions.remove(sessionId);
    _limiters.remove(sessionId);
    _closingSessions.remove(sessionId);
  }

  /// 清掉已结束（完成/失败/取消）的任务。
  void clearFinished({String? sessionId}) {
    final finished = tasks
        .where(
          (task) =>
              !task.status.value.active &&
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
    _disconnectedSessions.clear();
    for (final limiter in _limiters.values) {
      limiter.pause();
    }
    _limiters.clear();
    _retryAttempts.clear();
    for (final acquisition in _acquiring.values) {
      acquisition.cancelled = true;
    }
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
