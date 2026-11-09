/// 水平轴表示左右排列，垂直轴表示上下排列。
enum SessionSplitAxis { horizontal, vertical }

/// 只记录布局和会话 ID，不持有连接或凭据。
sealed class SessionLayout {
  const SessionLayout();

  Iterable<String> get sessionIds;

  SessionLayout split(String target, String added, SessionSplitAxis axis);
  SessionLayout? remove(String sessionId);
}

class SessionPane extends SessionLayout {
  const SessionPane(this.sessionId);
  final String sessionId;

  @override
  Iterable<String> get sessionIds => [sessionId];

  @override
  SessionLayout split(String target, String added, SessionSplitAxis axis) =>
      sessionId == target
      ? SessionSplit(
          id: 'split-$added',
          axis: axis,
          first: this,
          second: SessionPane(added),
        )
      : this;

  @override
  SessionLayout? remove(String id) => sessionId == id ? null : this;

  @override
  bool operator ==(Object other) =>
      other is SessionPane && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

class SessionSplit extends SessionLayout {
  const SessionSplit({
    required this.id,
    required this.axis,
    required this.first,
    required this.second,
  });

  final String id;
  final SessionSplitAxis axis;
  final SessionLayout first;
  final SessionLayout second;

  @override
  Iterable<String> get sessionIds sync* {
    yield* first.sessionIds;
    yield* second.sessionIds;
  }

  @override
  SessionLayout split(String target, String added, SessionSplitAxis axis) {
    final left = first.split(target, added, axis);
    final right = second.split(target, added, axis);
    if (identical(left, first) && identical(right, second)) return this;
    return SessionSplit(id: id, axis: this.axis, first: left, second: right);
  }

  @override
  SessionLayout? remove(String sessionId) {
    final left = first.remove(sessionId);
    final right = second.remove(sessionId);
    if (left == null) return right;
    if (right == null) return left;
    if (identical(left, first) && identical(right, second)) return this;
    return SessionSplit(id: id, axis: axis, first: left, second: right);
  }
}

/// 标签身份独立于其第一个窗格，关闭首个连接后仍保持原标签。
class SessionTab {
  const SessionTab({
    required this.id,
    required this.layout,
    required this.selectedSessionId,
  });

  SessionTab.single(String sessionId)
    : id = sessionId,
      layout = SessionPane(sessionId),
      selectedSessionId = sessionId;

  final String id;
  final SessionLayout layout;
  final String selectedSessionId;
  Iterable<String> get sessionIds => layout.sessionIds;
}
