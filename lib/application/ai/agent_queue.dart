part of 'agent_controller.dart';

class _AgentQueuedRequest {
  _AgentQueuedRequest({
    required this.entry,
    required this.targets,
    required this.labels,
    required this.model,
    required this.reasoningEffort,
    required this.accessMode,
  });

  final AgentEntry entry;
  final List<Session> targets;
  final Map<String, String> labels;
  final AiModelConfig? model;
  final AiReasoningEffort? reasoningEffort;
  final AgentAccessMode? accessMode;
  final done = Completer<void>();
}

class _AgentQueueState {
  final pending = <_AgentQueuedRequest>[].obs;
  _AgentQueuedRequest? active;
}

extension _AgentQueueOperations on AgentController {
  Future<void> _enqueue(
    String input, {
    List<Session>? referencedSessions,
    required Map<String, String> referenceLabels,
  }) {
    final text = input.trim();
    if (text.isEmpty || isClosed) return Future<void>.value();
    if (text.length > 20000) {
      error.value = '消息过长，请缩短后发送';
      return Future<void>.value();
    }
    if (modesLoaded) _syncModes();
    final request = _AgentQueuedRequest(
      entry: AgentEntry(
        AgentEntryKind.user,
        text,
        requestState: AgentRequestState.queued,
      ),
      // 在任何异步操作前复制，后续草稿、活动页签和模式变化不改变已发送消息。
      targets: List.unmodifiable(
        {
          for (final session in referencedSessions ?? selectedSessions)
            if (_boundSession(session) != null) session.id: session,
        }.values,
      ),
      labels: Map.unmodifiable(referenceLabels),
      model: currentModel,
      reasoningEffort: modesLoaded ? reasoningEffort.value : null,
      accessMode: modesLoaded ? accessMode.value : null,
    );
    _queue.pending.add(request);
    _addEntry(request.entry);
    _startNextRequest();
    return request.done.future;
  }

  void _startNextRequest() {
    if (isClosed || _queue.active != null) return;
    if (_queue.pending.isEmpty) {
      busy.value = false;
      return;
    }
    final request = _queue.pending.first;
    final generation = ++_generation;
    _queue.active = request;
    _queue.pending.removeAt(0);
    bool current() => _live(generation) && identical(_queue.active, request);
    if (!current()) return;
    _tools.activeTargets = request.targets;
    request.entry.requestState.value = AgentRequestState.running;
    if (!current()) return;
    error.value = null;
    if (!current()) return;
    activity.value = '正在思考';
    if (!current()) return;
    busy.value = true;
    if (current()) unawaited(_runRequest(request, generation));
  }

  void _finishRequest(
    _AgentQueuedRequest request,
    int generation, {
    required bool committed,
  }) {
    if (!_live(generation)) return;
    if (!committed) _rejectPending();
    if (!_live(generation)) return;
    request.entry.requestError.value = committed ? null : error.value;
    if (!_live(generation)) return;
    request.entry.requestState.value = committed
        ? AgentRequestState.completed
        : AgentRequestState.failed;
    if (!_live(generation)) return;
    _tools.activeTargets = const [];
    _queue.active = null;
    _saveConversation();
    if (_live(generation)) _startNextRequest();
  }

  void _cancelQueuedRequests() {
    final cancelled = [
      if (_queue.active != null) _queue.active!,
      ..._queue.pending,
    ];
    _queue.active = null;
    _queue.pending.clear();
    for (final request in cancelled) {
      request.entry.requestState.value = AgentRequestState.cancelled;
      if (!request.done.isCompleted) request.done.complete();
    }
  }
}
