part of 'agent_controller.dart';

/// Render deltas at frame-friendly intervals; only final snapshots are saved
/// by the request lifecycle. Preview text never feeds back into tool arguments.
class _AgentTurnPreview {
  _AgentTurnPreview(this.controller, this.generation, this.key);

  final AgentController controller;
  final int generation;
  final String key;
  final _answer = StringBuffer();
  final _reasoning = StringBuffer();
  AgentEntry? _answerEntry;
  AgentEntry? _reasoningEntry;
  Timer? _timer;
  bool _finished = false;
  bool _reasoningDirty = false;
  bool _answerDirty = false;
  static const _previewLimit = 512 * 1024;
  static final _controlChars = RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]');

  void add(String delta, bool reasoning) {
    if (_finished || !controller._live(generation)) return;
    final buffer = reasoning ? _reasoning : _answer;
    final remaining = (reasoning ? 8000 : _previewLimit) - buffer.length;
    if (remaining <= 0) return;
    buffer.write(
      delta.length <= remaining ? delta : delta.substring(0, remaining),
    );
    if (reasoning) {
      _reasoningDirty = true;
    } else {
      _answerDirty = true;
    }
    _timer ??= Timer(const Duration(milliseconds: 45), () {
      _timer = null;
      if (controller._live(generation)) {
        final reasoningText = _reasoningDirty ? _reasoning.toString() : null;
        final answerText = _answerDirty ? _answer.toString() : null;
        _reasoningDirty = false;
        _answerDirty = false;
        _update(reasoningText, answerText, AgentRequestState.running);
      }
    });
  }

  AgentEntry? _finish(
    String reasoning,
    String answer,
    AgentRequestState state,
  ) {
    if (_finished) return _answerEntry;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _reasoningDirty = false;
    _answerDirty = false;
    _update(reasoning, answer, state);
    return _answerEntry;
  }

  AgentEntry? commit(AgentReply reply) =>
      _finish(reply.reasoning, reply.turn.text, AgentRequestState.completed);

  AgentEntry? interrupt(AgentRequestState state) =>
      _finish(_reasoning.toString(), _answer.toString(), state);

  void _update(String? reasoning, String? answer, AgentRequestState state) {
    void apply(AgentEntryKind kind, String text) {
      final existing = kind == AgentEntryKind.reasoning
          ? _reasoningEntry
          : _answerEntry;
      if (existing == null) {
        if (text.isEmpty) return;
        final entry = AgentEntry(kind, text, requestState: state);
        if (kind == AgentEntryKind.reasoning) {
          _reasoningEntry = entry;
        } else {
          _answerEntry = entry;
        }
        controller._addEntry(entry, persist: false);
        return;
      }
      if (text.isNotEmpty) existing._text.value = text;
      if (state != AgentRequestState.running || controller._live(generation)) {
        existing.requestState.value = state;
      }
    }

    if (reasoning != null) {
      final summary = reasoning
          .replaceAll(key, '[redacted]')
          .replaceAll(_controlChars, '');
      apply(
        AgentEntryKind.reasoning,
        summary.length > 8000 ? '${summary.substring(0, 7999)}…' : summary,
      );
    }
    if (answer != null &&
        (state != AgentRequestState.running || controller._live(generation))) {
      apply(AgentEntryKind.assistant, answer);
    }
  }
}
