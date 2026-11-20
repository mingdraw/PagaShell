part of 'session_controller.dart';

/// 存储分屏及独立 ID 的标签；其余单窗格标签从会话列表派生。
class _SessionTabs {
  final _layouts = <String, SessionTab>{}.obs;
  int _nextDetachedTab = 1;

  List<SessionTab> list(Iterable<Session> sessions) {
    final memberships = <String, SessionTab>{
      for (final tab in _layouts.values)
        for (final id in tab.sessionIds) id: tab,
    };
    final added = <String>{};
    return [
      for (final session in sessions)
        if (added.add(memberships[session.id]?.id ?? session.id))
          memberships[session.id] ?? SessionTab.single(session.id),
    ];
  }

  void split(
    SessionTab tab,
    String target,
    String added,
    SessionSplitAxis axis, {
    bool before = false,
  }) {
    _layouts[tab.id] = SessionTab(
      id: tab.id,
      layout: tab.layout.split(target, added, axis, before: before),
      selectedSessionId: added,
    );
  }

  String detach(SessionTab tab, String id) {
    final remaining = _withoutPane(tab, id)!;
    final detached = SessionTab(
      id: 'detached-tab-${_nextDetachedTab++}',
      layout: SessionPane(id),
      selectedSessionId: id,
    );
    _layouts.value = {..._layouts, tab.id: remaining, detached.id: detached};
    return detached.id;
  }

  void activate(String id) {
    for (final tab in _layouts.values.toList()) {
      if (tab.selectedSessionId != id && tab.sessionIds.contains(id)) {
        _layouts[tab.id] = SessionTab(
          id: tab.id,
          layout: tab.layout,
          selectedSessionId: id,
        );
        return;
      }
    }
  }

  void remove(String id) {
    for (final tab in _layouts.values.toList()) {
      if (!tab.sessionIds.contains(id)) continue;
      final remaining = _withoutPane(tab, id);
      if (remaining == null) {
        _layouts.remove(tab.id);
      } else {
        _layouts[tab.id] = remaining;
      }
      return;
    }
  }

  SessionTab? _withoutPane(SessionTab tab, String id) {
    final layout = tab.layout.remove(id);
    if (layout == null) return null;
    var selected = tab.selectedSessionId;
    if (selected == id) {
      final ids = layout.sessionIds.toList();
      final previousIndex = tab.sessionIds.toList().indexOf(id);
      selected = ids[previousIndex.clamp(0, ids.length - 1)];
    }
    return SessionTab(id: tab.id, layout: layout, selectedSessionId: selected);
  }
}
