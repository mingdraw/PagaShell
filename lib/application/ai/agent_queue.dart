part of 'agent_controller.dart';

typedef _AgentSessionReferences = ({
  List<Session> targets,
  Map<String, String> labels,
});

class _AgentQueuedRequest {
  _AgentQueuedRequest({
    required this.entry,
    required this.model,
    required this.reasoningEffort,
    required this.accessMode,
    this.resuming = false,
  });

  final AgentEntry entry;
  List<Session> get targets => entry._references!.targets;
  Map<String, String> get labels => entry._references!.labels;
  final AiModelConfig? model;
  final AiReasoningEffort? reasoningEffort;
  final AgentAccessMode? accessMode;
  final bool resuming;
  AiModelConfig? resolvedModel;
  AiReasoningEffort? resolvedEffort;
  AgentAccessMode? resolvedMode;
  String? system, anthropicScope;
  List<AgentTurn>? inFlightTurns;
  int inFlightResults = 0;
  final done = Completer<void>();
  _AgentTurnPreview? preview;
  AgentEntry? lastAnswer;

  void interrupt(AgentRequestState state) {
    final current = preview;
    preview = null;
    final answer = current?.interrupt(state) ?? lastAnswer;
    answer?.requestState.value = state;
  }
}

class _AgentQueueState {
  final pending = <_AgentQueuedRequest>[].obs;
  _AgentQueuedRequest? active;
  _AgentQueuedRequest? continuation;
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
    _discardContinuation();
    // Copy before any asynchronous work. An explicit reference that becomes
    // stale is checked by _runRequest, never silently replaced by the draft.
    final targets = List<Session>.unmodifiable(
      {
        for (final session in referencedSessions ?? selectedSessions)
          session.id: session,
      }.values,
    );
    final request = _AgentQueuedRequest(
      entry:
          AgentEntry(
              AgentEntryKind.user,
              text,
              requestState: AgentRequestState.queued,
              hadSessionReferences: targets.isNotEmpty,
            )
            .._references = (
              targets: targets,
              labels: Map.unmodifiable(referenceLabels),
            ),
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
    if (_queue.continuation != null || _queue.pending.isEmpty) {
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
    required bool paused,
  }) {
    if (!_live(generation)) return;
    if (!committed && !paused) _rejectPending();
    if (!_live(generation)) return;
    request.entry.requestError.value = committed || paused ? null : error.value;
    if (!_live(generation)) return;
    if (committed) request.entry._references = null;
    request.entry.requestState.value = committed || paused
        ? AgentRequestState.completed
        : AgentRequestState.failed;
    if (!_live(generation)) return;
    _tools.activeTargets = const [];
    _queue.active = null;
    _saveConversation();
    if (paused && _live(generation)) canContinueTurn.value = true;
    if (_live(generation)) _startNextRequest();
  }

  void _discardContinuation() {
    _queue.continuation = null;
    canContinueTurn.value = false;
  }

  Future<void> _continueLastTurn() async {
    final previous = _queue.continuation;
    if (previous == null || _queue.active != null || isClosed) return;
    final model = previous.resolvedModel;
    final current = currentModel;
    if (model == null ||
        current == null ||
        current.id != model.id ||
        current.format != model.format ||
        AgentApiCodec.responsesScope(current) !=
            AgentApiCodec.responsesScope(model) ||
        previous.targets.any((target) => _boundSession(target) == null)) {
      _discardContinuation();
      error.value = '原模型或会话已变更，请重新选择后发送';
      _startNextRequest();
      return;
    }
    final next =
        _AgentQueuedRequest(
            entry: previous.entry,
            model: model,
            reasoningEffort: previous.resolvedEffort,
            accessMode: previous.resolvedMode,
            resuming: true,
          )
          ..system = previous.system
          ..anthropicScope = previous.anthropicScope
          ..lastAnswer = previous.lastAnswer;
    _discardContinuation();
    _queue.pending.insert(0, next);
    _startNextRequest();
    await next.done.future;
  }

  void _checkpoint(_AgentQueuedRequest request, List<AgentTurn> turns) {
    request.entry._hasToolCheckpoint = true;
    _trimHistory(turns);
    _history = List.of(turns);
    _saveConversation();
  }

  void _preserveInterruptedBatch(_AgentQueuedRequest? request) {
    final turns = request?.inFlightTurns;
    if (request == null || turns == null) return;
    request.inFlightTurns = null;
    final assistant = turns.lastWhere((turn) => turn.role == 'assistant');
    final complete = [
      ...turns,
      for (var i = request.inFlightResults; i < assistant.calls.length; i++)
        AgentTurn(
          'tool',
          i == request.inFlightResults
              ? 'Interrupted: result unavailable; the operation may have started. Verify before retrying.'
              : 'Not invoked: user interrupted this batch.',
          toolCallId: assistant.calls[i].id,
        ),
    ];
    _checkpoint(request, complete);
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
