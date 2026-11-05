part of 'agent_controller.dart';

class _AgentHistoryState {
  final conversations = <AgentConversation>[].obs;
  final currentConversationId = RxnString();
  final loadingHistory = false.obs;
  final historyLoadFailed = false.obs;
  final historyError = RxnString();
  Future<void>? loading;
  Future<void> persistence = Future<void>.value();
  final unsaved = <String, AgentConversation>{};
  final deleting = <String>{};
  final deleted = <String>{};
  String? failedDeleteId;
}

extension _AgentHistoryOperations on AgentController {
  Future<void> _loadConversations({bool retry = false}) {
    if (_storage.loading != null && (!retry || loadingHistory.value)) {
      return _storage.loading!;
    }
    loadingHistory.value = true;
    return _storage.loading = (() async {
      try {
        final saved = await _conversations.readAll();
        if (isClosed) return;
        final merged = {
          for (final item in saved)
            if (!_storage.deleted.contains(item.id)) item.id: item,
        };
        for (final item in conversations) {
          if (!_storage.deleted.contains(item.id)) merged[item.id] = item;
        }
        conversations.assignAll(
          merged.values.toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        );
        historyLoadFailed.value = false;
        if (_storage.unsaved.isEmpty && _storage.failedDeleteId == null) {
          historyError.value = null;
        }
      } on Object {
        if (!isClosed) {
          historyLoadFailed.value = true;
          historyError.value = '历史对话读取失败，请检查本地存储和凭据保险库后重试';
        }
      } finally {
        if (!isClosed) loadingHistory.value = false;
      }
    })();
  }

  Future<bool> _persist(Future<void> Function() action) {
    final done = Completer<bool>();
    _storage.persistence = _storage.persistence.then((_) async {
      try {
        await action();
        done.complete(true);
      } on Object {
        if (!isClosed) {
          historyError.value = '历史对话保存或删除失败，请重试';
        }
        done.complete(false);
      }
    });
    return done.future;
  }

  void _addEntry(AgentEntry entry) {
    entries.add(entry);
    _saveConversation();
  }

  void _saveConversation() {
    if (entries.isEmpty) return;
    final now = DateTime.now();
    final id = currentConversationId.value ??= List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    if (_storage.deleting.contains(id) || _storage.deleted.contains(id)) return;
    final previous = conversations.where((item) => item.id == id).firstOrNull;
    final first = entries
        .firstWhere((entry) => entry.kind == AgentEntryKind.user)
        .text
        .replaceAll(RegExp(r'\s+'), ' ');
    final snapshot = AgentConversation(
      id: id,
      title: String.fromCharCodes(first.runes.take(60)),
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
      model: _conversationModel ?? currentModel?.model ?? '',
      messages: List.unmodifiable(entries.map((entry) => entry.toMessage())),
      turns: List.unmodifiable(_history.map((turn) => turn.toJson())),
      historyTrimmed: historyTrimmed.value,
      historyRevision: _historyRevision,
      error: error.value,
    );
    // 一次替换，避免 removeWhere + insert 触发两次列表通知。
    conversations.assignAll([
      snapshot,
      for (final item in conversations)
        if (item.id != id) item,
    ]);
    _queueSave(snapshot);
  }

  void _queueSave(AgentConversation snapshot) {
    if (_storage.deleting.contains(snapshot.id) ||
        _storage.deleted.contains(snapshot.id)) {
      return;
    }
    _storage.unsaved[snapshot.id] = snapshot;
    unawaited(
      _persist(() async {
        await loadConversations();
        if (historyLoadFailed.value) throw const FormatException();
        if (_storage.deleted.contains(snapshot.id)) return;
        // 写入排队期间可能又产生了更新的快照：直接写最新的那份，
        // 之后为旧快照排队的任务发现已写入便跳过，避免重复加密落库。
        final latest = _storage.unsaved[snapshot.id];
        if (latest != null) {
          await _conversations.save(latest);
          if (identical(_storage.unsaved[snapshot.id], latest)) {
            _storage.unsaved.remove(snapshot.id);
          }
        }
        if (!isClosed &&
            _storage.unsaved.isEmpty &&
            _storage.failedDeleteId == null) {
          historyError.value = null;
        }
      }),
    );
  }

  Future<void> _retryHistory() async {
    if (historyLoadFailed.value) await loadConversations(retry: true);
    if (historyLoadFailed.value) return;
    for (final snapshot in _storage.unsaved.values.toList()) {
      _queueSave(snapshot);
    }
    await historySaved;
    final deletion = _storage.failedDeleteId;
    if (deletion != null) await deleteConversation(deletion);
  }

  /// 窗口关闭和系统退出均先排空本地写入，不等待仍在服务商运行的请求。
  Future<bool> _prepareForExit() async {
    stop();
    await modesSaved;
    if (_modesDirty) await retryModes();
    await historySaved;
    if (_storage.unsaved.isNotEmpty || _storage.failedDeleteId != null) {
      await retryHistory();
    }
    return !_modesDirty &&
        _storage.unsaved.isEmpty &&
        _storage.failedDeleteId == null;
  }

  bool _openConversation(String id) {
    if (_storage.deleting.contains(id) || _storage.deleted.contains(id)) {
      return false;
    }
    final saved = conversations.where((item) => item.id == id).firstOrNull;
    if (saved == null) return false;
    if (_storage.failedDeleteId == id) _storage.failedDeleteId = null;
    if (currentConversationId.value == id) return true;
    List<AgentTurn> turns;
    try {
      turns = saved.turns.map(AgentTurn.fromJson).toList();
    } on Object {
      historyError.value = '历史对话读取失败，请检查本地存储和凭据保险库后重试';
      return false;
    }
    stop();
    _resetConversation();
    currentConversationId.value = saved.id;
    _conversationModel = saved.model;
    entries.assignAll([
      for (final message in saved.messages)
        AgentEntry(
          message.kind,
          message.text,
          archivedCommand: message.command,
        ),
    ]);
    _history = turns;
    _historyRevision = saved.historyRevision;
    historyTrimmed.value = saved.historyTrimmed;
    error.value = saved.error;
    return true;
  }

  Future<bool> _deleteConversation(String id) async {
    if (!_storage.deleting.add(id)) return false;
    if (currentConversationId.value == id) {
      stop();
      _resetConversation();
    }
    final removed = await _persist(() => _conversations.remove(id));
    if (removed) {
      _storage.deleted.add(id);
      if (_storage.failedDeleteId == id) _storage.failedDeleteId = null;
      _storage.unsaved.remove(id);
      conversations.removeWhere((item) => item.id == id);
      if (!isClosed && _storage.unsaved.isEmpty && !historyLoadFailed.value) {
        historyError.value = null;
      }
    } else {
      _storage.failedDeleteId = id;
    }
    _storage.deleting.remove(id);
    return removed;
  }

  /// 仅移除完整的较早轮次，保留工具调用与结果配对。可见聊天不受影响。
  void _trimHistory(List<AgentTurn> turns) {
    int size() => turns.fold(
      0,
      (total, turn) =>
          total +
          (turn.anthropicContent.isNotEmpty
              ? jsonEncode(turn.anthropicContent).length
              : turn.responsesOutput.isNotEmpty
              ? jsonEncode(turn.responsesOutput).length
              : turn.text.length +
                    turn.calls.fold(
                      0,
                      (sum, call) => sum + jsonEncode(call.arguments).length,
                    )),
    );
    while (turns.where((turn) => turn.role == 'user').length > 12 ||
        size() > 60000) {
      final next = turns.indexWhere((turn) => turn.role == 'user', 1);
      if (next < 0) break;
      turns.removeRange(0, next);
      ++_historyRevision;
      historyTrimmed.value = true;
    }
  }
}
