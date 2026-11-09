part of 'session_controller.dart';

/// 只存储发生过分屏的标签；普通标签从会话列表派生，保持现有调用兼容。
class _SessionTabs {
  final _splitTabs = <String, SessionTab>{}.obs;

  List<SessionTab> list(Iterable<Session> sessions) {
    final memberships = <String, SessionTab>{
      for (final tab in _splitTabs.values)
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
    SessionSplitAxis axis,
  ) {
    _splitTabs[tab.id] = SessionTab(
      id: tab.id,
      layout: tab.layout.split(target, added, axis),
      selectedSessionId: added,
    );
  }

  void activate(String id) {
    for (final tab in _splitTabs.values.toList()) {
      if (tab.selectedSessionId != id && tab.sessionIds.contains(id)) {
        _splitTabs[tab.id] = SessionTab(
          id: tab.id,
          layout: tab.layout,
          selectedSessionId: id,
        );
        return;
      }
    }
  }

  void remove(String id) {
    for (final tab in _splitTabs.values.toList()) {
      if (!tab.sessionIds.contains(id)) continue;
      final layout = tab.layout.remove(id);
      if (layout == null) {
        _splitTabs.remove(tab.id);
      } else {
        final ids = layout.sessionIds.toList();
        final previousIndex = tab.sessionIds.toList().indexOf(id);
        _splitTabs[tab.id] = SessionTab(
          id: tab.id,
          layout: layout,
          selectedSessionId: tab.selectedSessionId == id
              ? ids[previousIndex.clamp(0, ids.length - 1)]
              : tab.selectedSessionId,
        );
      }
      return;
    }
  }
}
