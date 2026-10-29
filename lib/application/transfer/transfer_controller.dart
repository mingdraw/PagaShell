import 'dart:async';
import 'dart:collection';

import 'package:get/get.dart';

import '../../domain/ssh/ssh_engine.dart';

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
  });

  final String id;
  final String sessionId;
  final TransferKind kind;
  final String fileName;
  final String remotePath;
  final String localPath;

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
  }) {
    return _start(
      sessionId: sessionId,
      kind: TransferKind.download,
      fileName: _baseName(remotePath),
      remotePath: remotePath,
      localPath: localPath,
      progress: engineSession.download(remotePath, localPath),
      request: _TransferRequest(
        () => engineSession.download(remotePath, localPath),
        null,
      ),
    );
  }

  TransferTask startUpload({
    required String sessionId,
    required SshEngineSession engineSession,
    required String localPath,
    required String remotePath,
    Future<void> Function()? releaseSource,
    TransferSourceAccess? acquireSource,
  }) {
    final progress = engineSession.upload(localPath, remotePath);
    return _start(
      sessionId: sessionId,
      kind: TransferKind.upload,
      fileName: _baseName(localPath),
      remotePath: remotePath,
      localPath: localPath,
      progress: progress,
      releaseSource: releaseSource,
      request: _TransferRequest(
        () => engineSession.upload(localPath, remotePath),
        acquireSource,
      ),
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
      (p) {
        task.transferred.value = p.transferred;
        task.total.value = p.total;
      },
      onError: (Object e, StackTrace _) {
        task.error.value = e is SshEngineException ? e.message : e.toString();
        task.status.value = TransferStatus.failed;
        _finishRate(task);
        _cleanup[task.id] =
            _subs
                .remove(task.id)
                ?.cancel()
                .whenComplete(() => _releaseSource(task.id)) ??
            _releaseSource(task.id);
      },
      onDone: () {
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
          (task.kind == TransferKind.upload
              ? other.remotePath == task.remotePath
              : other.localPath == task.localPath),
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
      task.bytesPerSecond.value = 0;
      task.error.value = null;
      task.status.value = TransferStatus.running;
      if (release != null) _sourceReleases[taskId] = release;
      release = null;
      _listen(task, progress);
    } on Object catch (e) {
      if (current()) {
        task.error.value = e is SshEngineException ? e.message : e.toString();
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

  /// 取路径最后一段作为展示名（远端为 POSIX，本地兼容 Windows 分隔符）。
  static String _baseName(String path) {
    final segments = path
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? path : segments.last;
  }
}
