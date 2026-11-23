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

  void _addEntry(AgentEntry entry, {bool persist = true}) {
    final active = _queue.active;
    final activeIndex = active == null ? -1 : entries.indexOf(active.entry);
    final nextUser = entry.kind == AgentEntryKind.user || activeIndex < 0
        ? -1
        : entries.indexWhere(
            (item) => item.kind == AgentEntryKind.user,
            activeIndex + 1,
          );
    // 工具和回复跟在本轮用户消息后面，尚未执行的消息保持在其下方。
    if (nextUser < 0) {
      entries.add(entry);
    } else {
      entries.insert(nextUser, entry);
    }
    if (persist) _saveConversation();
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
          archivedFileChange: message.fileChange,
          requestState: message.requestState,
          requestError: message.requestError,
          toolSummary: message.toolSummary,
          hadSessionReferences: message.hadSessionReferences,
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

  /// 移除旧轮次并压缩长工具链。可见对话及审阅卡片不受影响。
  void _trimHistory(List<AgentTurn> turns) {
    const budget = 120000;
    int weight(AgentTurn turn) => switch (turn) {
      _ when turn.anthropicContent.isNotEmpty => jsonEncode(
        turn.anthropicContent,
      ).length,
      _ when turn.responsesOutput.isNotEmpty => jsonEncode(
        turn.responsesOutput,
      ).length,
      _ =>
        turn.text.length +
            (turn.toolCallId?.length ?? 0) +
            turn.calls.fold(
              0,
              (sum, call) =>
                  sum +
                  call.id.length +
                  call.name.length +
                  jsonEncode(call.arguments).length,
            ),
    };
    final weights = turns.map(weight).toList();
    var size = weights.fold(0, (sum, value) => sum + value);
    var userTurns = turns.where((turn) => turn.role == 'user').length;
    var trimmed = false;

    while (userTurns > 20 || size > budget) {
      final next = turns.indexWhere((turn) => turn.role == 'user', 1);
      if (next < 0) break;
      for (final value in weights.take(next)) {
        size -= value;
      }
      userTurns--;
      turns.removeRange(0, next);
      weights.removeRange(0, next);
      trimmed = true;
    }

    void compact(int index, AgentTurn turn) {
      final shrunk = weight(turn);
      if (shrunk >= weights[index]) return;
      size -= weights[index] - shrunk;
      weights[index] = shrunk;
      turns[index] = turn;
      trimmed = true;
    }

    // Preserve complete call/result pairs. A long tool chain usually fits
    // after cropping result bodies, while signed thinking blocks stay intact.
    for (final limit in [1200, 260]) {
      for (var i = 0; i < turns.length && size > budget; i++) {
        final turn = turns[i];
        if (turn.role != 'tool' || turn.text.length <= limit) continue;
        compact(
          i,
          AgentTurn(
            'tool',
            _truncateToolOutput(turn.text, maxChars: limit),
            toolCallId: turn.toolCallId,
          ),
        );
      }
    }
    // Large model-authored file payloads or reasoning can be bigger than the
    // entire budget. Rebuild the oldest oversized reply from the portable
    // fields, keeping tool IDs and the operation's main arguments.
    for (var i = 0; i < turns.length && size > budget; i++) {
      final turn = turns[i];
      if (turn.role != 'assistant') continue;
      compact(
        i,
        AgentTurn(
          'assistant',
          _truncateToolOutput(turn.text, maxChars: 1800),
          calls: [
            for (final call in turn.calls)
              AgentToolCall(
                id: call.id,
                name: call.name,
                arguments: {
                  for (final arg in call.arguments.entries)
                    if (const {
                          'session_id',
                          'id',
                          'path',
                          'command',
                          'purpose',
                          'kind',
                        }.contains(arg.key) &&
                        arg.value is String)
                      arg.key: _truncateToolOutput(
                        arg.value as String,
                        maxChars: 240,
                      ),
                },
              ),
          ],
        ),
      );
    }
    // Repeated continuations can make even compact pairs exceed the budget.
    // Roll up complete early batches while leaving the latest batch intact.
    var summarized = 0;
    while (size > budget && turns.length > 2) {
      final end = turns.indexWhere((turn) => turn.role == 'assistant', 2);
      if (end < 0) break;
      summarized += turns
          .getRange(1, end)
          .where((turn) => turn.role == 'tool')
          .length;
      for (final value in weights.getRange(1, end)) {
        size -= value;
      }
      turns.removeRange(1, end);
      weights.removeRange(1, end);
      trimmed = true;
    }
    if (summarized > 0) {
      turns.insert(
        1,
        AgentTurn(
          'assistant',
          '$summarized earlier tool results were compacted for space. They may include changes. Verify current state before repeating actions.',
        ),
      );
    }
    if (trimmed) {
      ++_historyRevision;
      historyTrimmed.value = true;
    }
  }
}
