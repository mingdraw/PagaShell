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
  static const _previewLimit = 512 * 1024;

  void add(String delta, bool reasoning) {
    if (!controller._live(generation)) return;
    final buffer = reasoning ? _reasoning : _answer;
    final remaining = (reasoning ? 8000 : _previewLimit) - buffer.length;
    if (remaining <= 0) return;
    buffer.write(
      delta.length <= remaining ? delta : delta.substring(0, remaining),
    );
    _timer ??= Timer(const Duration(milliseconds: 45), () {
      _timer = null;
      _update(_reasoning.toString(), _answer.toString());
    });
  }

  void close() {
    _timer?.cancel();
    _update(_reasoning.toString(), _answer.toString());
  }

  void commit(AgentReply reply) => _update(reply.reasoning, reply.turn.text);

  void _update(String reasoning, String answer) {
    if (!controller._live(generation)) return;
    var refresh = false;
    AgentEntry? apply(AgentEntryKind kind, String text, AgentEntry? existing) {
      if (text.isEmpty) return existing;
      if (existing == null) {
        final entry = AgentEntry(kind, text);
        controller._addEntry(entry, persist: false);
        return entry;
      }
      if (existing.text != text) {
        existing._text = text;
        refresh = true;
      }
      return existing;
    }

    final summary = reasoning
        .replaceAll(key, '[redacted]')
        .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');
    _reasoningEntry = apply(
      AgentEntryKind.reasoning,
      summary.length > 8000 ? '${summary.substring(0, 7999)}…' : summary,
      _reasoningEntry,
    );
    _answerEntry = apply(AgentEntryKind.assistant, answer, _answerEntry);
    if (refresh) controller.entries.refresh();
  }
}
