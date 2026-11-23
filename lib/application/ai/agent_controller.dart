import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';
import 'package:pagashell/terminal/core.dart';

import '../../domain/ai/agent_conversation.dart';
import '../../domain/ai/agent_diff.dart';
import '../../domain/ai/agent_skill.dart';
import '../../domain/ai/ai_model.dart';
import '../../domain/ai/command_classifier.dart';
import '../../domain/repositories/agent_conversation_repository.dart';
import '../../domain/ssh/agent_ops.dart';
import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/vault/secret_store.dart';
import '../network/app_connect.dart';
import '../session/session.dart';
import '../session/session_controller.dart';
import 'agent_api_codec.dart';
import 'agent_sse.dart';
import 'ai_settings_controller.dart';

export '../../domain/ai/agent_conversation.dart'
    show
        AgentEntryKind,
        AgentCommandState,
        AgentRequestState,
        AgentCommandExecutionMode,
        AgentFileChangeState;
export '../../domain/ai/ai_model.dart' show AgentAccessMode;
export '../../domain/ai/command_classifier.dart' show AgentCommandRisk;

part 'agent_history.dart';
part 'agent_api.dart';
part 'agent_tools.dart';
part 'agent_exec_tools.dart';
part 'agent_file_tools.dart';
part 'agent_inspection_tools.dart';
part 'agent_queue.dart';
part 'agent_preview.dart';

class AgentEntry {
  AgentEntry(
    this.kind,
    String text, {
    this.command,
    this.archivedCommand,
    this.fileChange,
    this.archivedFileChange,
    AgentRequestState? requestState,
    String? requestError,
    AgentToolSummary? toolSummary,
    this.hadSessionReferences = false,
  }) : _text = text.obs,
       _toolSummary = Rxn<AgentToolSummary>(toolSummary),
       requestState = Rxn<AgentRequestState>(requestState),
       requestError = RxnString(requestError);
  final AgentEntryKind kind;
  final RxString _text;
  String get text => _text.value;
  final Rxn<AgentToolSummary> _toolSummary;
  AgentToolSummary? get toolSummary => _toolSummary.value;
  final AgentCommandProposal? command;
  final AgentArchivedCommand? archivedCommand;
  final AgentFileChangeProposal? fileChange;
  final AgentArchivedFileChange? archivedFileChange;
  final Rxn<AgentRequestState> requestState;
  final RxnString requestError;
  final bool hadSessionReferences;
  _AgentSessionReferences? _references;
  bool _hasToolCheckpoint = false;

  AgentMessage toMessage() => AgentMessage(
    kind,
    text,
    requestState: switch (requestState.value) {
      AgentRequestState.queued ||
      AgentRequestState.running => AgentRequestState.cancelled,
      final state => state,
    },
    requestError: requestError.value,
    toolSummary: switch (toolSummary) {
      final summary? when summary.elapsedMs == null && !summary.cancelled =>
        AgentToolSummary(summary.target, cancelled: true),
      final summary => summary,
    },
    hadSessionReferences: hadSessionReferences,
    command: command?._archive() ?? archivedCommand,
    fileChange: fileChange?._archive() ?? archivedFileChange,
  );
}

class AgentController extends GetxController {
  AgentController({
    required this._connect,
    required this._settings,
    required this._secretStore,
    required this._sessions,
    required this._conversations,
  });

  final GetConnect _connect;
  final AiSettingsController _settings;
  final SecretStore _secretStore;
  final SessionController _sessions;
  final AgentConversationRepository _conversations;
  final entries = <AgentEntry>[].obs;
  static const maxToolSteps = 24;
  final canContinueTurn = false.obs;
  final _storage = _AgentHistoryState();
  final _api = _AgentApiState();
  final _tools = _AgentToolState();
  final _queue = _AgentQueueState();
  int get queuedCount => _queue.pending.length;
  RxList<AgentConversationSummary> get conversations => _storage.conversations;
  RxnString get currentConversationId => _storage.currentConversationId;
  RxBool get loadingHistory => _storage.loadingHistory;
  RxBool get historyLoadFailed => _storage.historyLoadFailed;
  RxnString get historyError => _storage.historyError;
  String? _conversationModel;
  final busy = false.obs;
  final selectedSessions = <Session>[].obs;
  final accessMode = AgentAccessMode.requestApproval.obs;
  final waitingForApproval = false.obs;
  final error = RxnString();
  final activity = '正在思考'.obs;
  final historyTrimmed = false.obs;
  final reasoningEffort = AiReasoningEffort.auto.obs;
  final modesError = RxnString();
  Future<void> _modeSave = Future<void>.value();
  bool _modesDirty = false;
  int _modeRevision = 0;
  List<AgentTurn> _history = [];
  Worker? _settingsWorker;
  Worker? _sessionsWorker;
  int _historyRevision = 0;
  int _generation = 0;
  bool _live(int generation) => !isClosed && generation == _generation;

  @override
  void onInit() {
    super.onInit();
    unawaited(loadConversations());
    _settingsWorker = ever(_settings.state, (_) => _syncApi());
    _sessionsWorker = ever(_sessions.sessions, (_) {
      if (_tools.activeTargets.any((target) => _boundSession(target) == null) ||
          _queue.continuation?.targets.any(
                (target) => _boundSession(target) == null,
              ) ==
              true) {
        stop();
      }
      // RxList.removeWhere 即使没有删除也会通知，先判断避免二次重建。
      if (selectedSessions.any((target) => _boundSession(target) == null)) {
        selectedSessions.removeWhere((target) => _boundSession(target) == null);
      }
    });
    unawaited(
      _settings.ready.then((_) {
        if (!isClosed) _syncApi();
      }),
    );
  }

  AiModelConfig? get currentModel => _settings.state.value.apiConfig;

  List<AiReasoningEffort> get reasoningOptions {
    _api.capabilityRevision.value;
    final model = currentModel;
    if (model == null) return [AiReasoningEffort.auto];
    final detail =
        _api.modelDetails[_capabilityScope(model)] ??
        AiAvailableModel(model.model);
    return detail.reasoningOptions(model.format);
  }

  void selectReasoningEffort(AiReasoningEffort value) {
    if (modesLoaded && reasoningOptions.contains(value)) {
      _syncModes();
      reasoningEffort.value = value;
      _saveModes();
    }
  }

  bool get modesLoaded =>
      _settings.isLoaded.value && !_settings.loadFailed.value;
  Future<void> get modesSaved => _modeSave;

  void _syncModes() {
    if (_modesDirty) return;
    reasoningEffort.value = _settings.state.value.reasoningEffort;
    accessMode.value = _settings.state.value.accessMode;
  }

  void _saveModes() {
    final revision = ++_modeRevision;
    final effort = reasoningEffort.value;
    final access = accessMode.value;
    _modesDirty = true;
    _modeSave = _modeSave.then((_) async {
      try {
        await _settings.setAgentModes(
          reasoningEffort: effort,
          accessMode: access,
        );
        if (revision == _modeRevision && !isClosed) {
          _modesDirty = false;
          modesError.value = null;
        }
      } on Object {
        if (revision == _modeRevision && !isClosed) {
          modesError.value = 'Agent 模式保存失败，请重试';
        }
      }
    });
  }

  Future<void> retryModes() async {
    _saveModes();
    await modesSaved;
  }

  void _syncApi() {
    _syncModes();
    final api = _settings.state.value.apiConfig;
    final scope = api == null
        ? null
        : '${AgentApiCodec.responsesScope(api)}#${api.id}';
    if (_api.scope != scope) {
      _api.scope = scope;
      _api.modelDetails.clear();
      _api.modelLimits.clear();
      _api.capabilityRevision.value++;
    }
  }

  Future<void> loadConversations({bool retry = false}) =>
      _loadConversations(retry: retry);
  Future<void> get historySaved {
    _flushPendingSave();
    return _storage.persistence;
  }

  Future<void> retryHistory() => _retryHistory();
  Future<bool> prepareForExit() => _prepareForExit();
  Future<bool> openConversation(String id, {bool Function()? canApply}) =>
      _openConversation(id, canApply: canApply);
  Future<bool> deleteConversation(String id) => _deleteConversation(id);

  List<Session> get selectableSessions => _sessions.sessions
      .where(
        (session) =>
            session.phase == SessionPhase.ready &&
            (session.kind == SessionKind.remoteDesktop ||
                (session.kind == SessionKind.terminal &&
                    session.engineSession != null &&
                    session.terminal != null)),
      )
      .toList();

  bool canReferenceSession(Session session) =>
      _boundSession(session) != null &&
      selectableSessions.any((item) => item.id == session.id);

  /// 当前草稿的关联。发送后使用独立快照，编辑下一条草稿不改变运行目标。
  void setReferencedSessions(Iterable<Session> sessions) {
    final next = {
      for (final session in sessions)
        if (canReferenceSession(session)) session.id: session,
    }.values.toList();
    if (selectedSessions.length == next.length &&
        Iterable<int>.generate(
          next.length,
        ).every((index) => identical(selectedSessions[index], next[index]))) {
      return;
    }
    selectedSessions.assignAll(next);
  }

  void selectAccessMode(AgentAccessMode mode) {
    if (!modesLoaded) return;
    _syncModes();
    accessMode.value = mode;
    _saveModes();
  }

  bool canSendCommand(AgentCommandProposal proposal) =>
      _canSendCommand(proposal);
  bool canFillCommand(AgentCommandProposal proposal) =>
      _boundSession(proposal.target) != null &&
      _sessions.canSendCommandToSession(proposal.target.id);
  bool canFillFileChange(AgentFileChangeProposal proposal) =>
      _ownsFileCard(proposal) &&
      _boundSession(proposal.target) != null &&
      _sessions.canSendCommandToSession(proposal.target.id);

  bool canApplyFileChange(AgentFileChangeProposal proposal) =>
      _canApplyFileChange(proposal);
  bool approveFileChange(AgentFileChangeProposal proposal) =>
      _approveFileChange(proposal);
  void rejectFileChange(AgentFileChangeProposal proposal) =>
      _rejectFileChange(proposal);
  bool canRollbackFileChange(AgentFileChangeProposal proposal) =>
      _canRollbackFileChange(proposal);
  Future<bool> rollbackFileChange(AgentFileChangeProposal proposal) =>
      _rollbackFileChange(proposal);

  Future<List<AiAvailableModel>> fetchModels({
    required AiApiFormat format,
    required String baseUrl,
    String? apiKey,
    String? modelConfigId,
  }) => _fetchModels(
    format: format,
    baseUrl: baseUrl,
    apiKey: apiKey,
    modelConfigId: modelConfigId,
  );

  Future<void> testConnection(AiModelConfig model, {String? apiKey}) =>
      _testConnection(model, apiKey: apiKey);

  Future<void> send(
    String input, {
    List<Session>? referencedSessions,
    Map<String, String> referenceLabels = const {},
  }) => _enqueue(
    input,
    referencedSessions: referencedSessions,
    referenceLabels: referenceLabels,
  );

  Future<void> continueLastTurn() => _continueLastTurn();

  /// Retry the original text and live connection identities, not the draft.
  Future<void> retry(AgentEntry entry) async {
    final state = entry.requestState.value;
    if (isClosed ||
        entry.kind != AgentEntryKind.user ||
        (state != AgentRequestState.failed &&
            state != AgentRequestState.cancelled) ||
        !entries.contains(entry)) {
      return;
    }
    final references = entry._references;
    if (entry._hasToolCheckpoint) {
      error.value = '上一次已执行部分工具，请查看记录后发送新的指令';
      return;
    }
    if ((entry.hadSessionReferences && references == null) ||
        references?.targets.any((target) => _boundSession(target) == null) ==
            true) {
      error.value = '原消息引用的会话不可用，请重新选择会话后发送';
      return;
    }
    await _enqueue(
      entry.text,
      referencedSessions: references?.targets ?? const [],
      referenceLabels: references?.labels ?? const {},
    );
  }

  Future<void> _runRequest(_AgentQueuedRequest request, int generation) async {
    final text = request.entry.text;
    final targets = request.targets;
    final labels = request.labels;
    var committed = false;
    var paused = false;
    try {
      await _settings.ready;
      _syncModes();
      await loadConversations();
      if (!_live(generation)) return;
      if (_settings.loadFailed.value) {
        throw const AgentApiException('AI 设置读取失败，请重试');
      }
      if (targets.any((target) => _boundSession(target) == null)) {
        throw const AgentApiException('排队消息引用的会话已关闭或重连，请重新选择会话后发送');
      }
      final model = request.model ?? currentModel;
      if (model == null) throw const AgentApiException('请先在设置中配置 AI API');
      final mode = request.accessMode ?? accessMode.value;
      _conversationModel = model.model;
      final effort = request.reasoningEffort ?? reasoningEffort.value;
      request.resolvedModel = model;
      request.resolvedMode = mode;
      request.resolvedEffort = effort;
      final key = await _secretStore.read(model.secretRef);
      if (!_live(generation)) return;
      if (key == null || key.trim().isEmpty) {
        throw const AgentApiException('API Key 不可用，请在设置中重新保存');
      }
      final limit = await _anthropicMaxTokens(model, key);
      if (!_live(generation)) return;
      final turns = [
        ..._history,
        if (!request.resuming) AgentTurn('user', text),
      ];
      _trimHistory(turns);
      if (!_live(generation)) return;
      final capabilities = _api.modelDetails[_capabilityScope(model)];
      final system = request.system ??= _system(targets, mode, labels);
      final anthropicScope = request.anthropicScope ??=
          '${AgentApiCodec.responsesScope(model)}#$system#${effort.name}#$_historyRevision';
      for (var step = 0; step < maxToolSteps; step++) {
        if (!_live(generation)) return;
        final preview = _AgentTurnPreview(this, generation, key);
        request.preview = preview;
        final reply = await _request(
          model,
          key,
          system,
          turns,
          anthropicMaxTokens: limit,
          effort: effort,
          capabilities: capabilities,
          anthropicScope: anthropicScope,
          onDelta: preview.add,
        );
        if (!_live(generation)) return;
        request.lastAnswer = preview.commit(reply) ?? request.lastAnswer;
        request.preview = null;
        if (!_live(generation)) return;
        final turn = reply.turn;
        if (reply.truncated && turn.calls.isNotEmpty) {
          throw const AgentApiException('AI 回复达到服务商长度上限，请缩小问题或继续提问');
        }
        turns.add(turn);
        if (turn.calls.isEmpty) {
          _trimHistory(turns);
          if (!_live(generation)) return;
          _setHistory(turns);
          committed = true;
          if (reply.truncated) error.value = 'AI 回复达到服务商长度上限，请缩小问题或继续提问';
          break;
        }
        request.inFlightTurns = turns;
        request.inFlightResults = 0;
        for (final call in turn.calls) {
          if (!_live(generation)) return;
          activity.value = '正在使用工具';
          final result = await _tool(call, targets, generation, mode, labels);
          if (!_live(generation)) return;
          turns.add(
            AgentTurn('tool', _limitToolResult(result), toolCallId: call.id),
          );
          request.inFlightResults++;
        }
        request.inFlightTurns = null;
        _checkpoint(request, turns);
        activity.value = '正在思考';
      }
      if (!committed && _live(generation)) {
        _queue.continuation = request;
        paused = true;
      }
    } on AgentApiException catch (e) {
      if (_live(generation)) error.value = e.message;
    } on TimeoutException {
      if (_live(generation)) error.value = 'AI 请求超时，请重试';
    } on Object {
      // 不展示平台/服务端异常原文，以免其中带入请求头或密钥。
      if (_live(generation)) error.value = 'AI 请求失败，请检查模型配置或凭据存储';
    } finally {
      if (!committed && !paused && _live(generation)) {
        _preserveInterruptedBatch(request);
        request.interrupt(AgentRequestState.failed);
      }
      _finishRequest(request, generation, committed: committed, paused: paused);
      if (!request.done.isCompleted) request.done.complete();
    }
  }

  bool approveCommand(AgentCommandProposal proposal, {String? editedCommand}) =>
      _approveCommand(proposal, editedCommand ?? proposal.command);
  void rejectCommand(AgentCommandProposal proposal) => _rejectCommand(proposal);

  void stop() {
    final active = _queue.active;
    final wasBusy = busy.value || active != null;
    _discardContinuation();
    _preserveInterruptedBatch(active);
    ++_generation;
    _api.activeStream?.cancel();
    active?.interrupt(AgentRequestState.cancelled);
    _tools.cancelRunningTool?.call();
    _tools.cancelRunningTool = null;
    _tools.cancelExec?.call();
    _tools.cancelExec = null;
    _tools.cancelOutputWait?.call();
    _tools.activeTargets = const [];
    waitingForApproval.value = false;
    busy.value = false;
    _rejectPending();
    _cancelQueuedRequests();
    if (wasBusy || _storage.savePending) {
      _saveConversation();
    } else {
      _cancelPendingSave();
    }
  }

  void clear() {
    stop();
    _resetConversation();
  }

  void _resetConversation() {
    _cancelPendingSave();
    _cancelHistoryOpen();
    currentConversationId.value = null;
    _conversationModel = null;
    selectedSessions.clear();
    entries.clear();
    _setHistory([]);
    _storage.turnWeights.clear();
    _historyRevision = 0;
    historyTrimmed.value = false;
    error.value = null;
  }

  @override
  void onClose() {
    _settingsWorker?.dispose();
    _sessionsWorker?.dispose();
    stop();
    _cancelPendingSave();
    _cancelHistoryOpen();
    _setHistory([]);
    _storage.turnWeights.clear();
    super.onClose();
  }
}
