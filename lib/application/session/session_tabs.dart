part of 'session_controller.dart';

/// 存储分屏及独立 ID 的标签；其余单窗格标签从会话列表派生。
class _SessionTabs {
  final _layouts = <String, SessionTab>{}.obs;
  final _membershipVersion = 0.obs;
  int _cachedVersion = -1;
  List<String> _sessionIds = const [];
  List<SessionTab>? _cached;
  Map<String, SessionTab> _byTab = const {};
  Map<String, SessionTab> _bySession = const {};
  int _nextDetachedTab = 1;

  void updateSessions(List<Session> sessions) {
    if (_sessionIds.length == sessions.length) {
      var index = 0;
      while (index < sessions.length &&
          _sessionIds[index] == sessions[index].id) {
        index++;
      }
      if (index == sessions.length) return;
    }
    _sessionIds = [for (final session in sessions) session.id];
    _membershipVersion.value++;
  }

  List<SessionTab> list() {
    final layouts = _layouts(); // Track selection and split changes in Obx.
    final version = _membershipVersion.value;
    if (_cached case final cached? when _cachedVersion == version) {
      return cached;
    }
    final memberships = <String, SessionTab>{
      for (final tab in layouts.values)
        for (final id in tab.sessionIds) id: tab,
    };
    final added = <String>{};
    _bySession = {};
    _byTab = {};
    for (final id in _sessionIds) {
      final tab = memberships[id] ?? SessionTab.single(id);
      _bySession[id] = tab;
      if (added.add(tab.id)) _byTab[tab.id] = tab;
    }
    _cachedVersion = version;
    return _cached = List.unmodifiable(_byTab.values);
  }

  SessionTab? byId(String id) {
    list();
    return _byTab[id];
  }

  SessionTab? forSession(String? id) {
    list();
    return _bySession[id];
  }

  void split(
    SessionTab tab,
    String target,
    String added,
    SessionSplitAxis axis, {
    bool before = false,
  }) {
    _cached = null;
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
    _cached = null;
    _layouts.value = {..._layouts, tab.id: remaining, detached.id: detached};
    return detached.id;
  }

  void activate(String id) {
    for (final tab in _layouts.values.toList()) {
      if (tab.selectedSessionId != id && tab.sessionIds.contains(id)) {
        _cached = null;
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
      _cached = null;
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
