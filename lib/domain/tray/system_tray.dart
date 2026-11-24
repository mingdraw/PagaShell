enum SystemTrayMenuItemKind { normal, checkbox, separator, submenu }

/// 跨平台原生系统托盘菜单项快照（不可变）。
class SystemTrayMenuItem {
  const SystemTrayMenuItem({
    this.id,
    this.label = '',
    this.kind = SystemTrayMenuItemKind.normal,
    this.enabled = true,
    this.checked = false,
    this.children = const [],
  });

  const SystemTrayMenuItem.separator()
    : id = null,
      label = '',
      kind = SystemTrayMenuItemKind.separator,
      enabled = false,
      checked = false,
      children = const [];

  const SystemTrayMenuItem.action({
    required String this.id,
    required this.label,
    this.enabled = true,
  }) : kind = SystemTrayMenuItemKind.normal,
       checked = false,
       children = const [];

  const SystemTrayMenuItem.info(this.label)
    : id = null,
      kind = SystemTrayMenuItemKind.normal,
      enabled = false,
      checked = false,
      children = const [];

  const SystemTrayMenuItem.checkbox({
    required String this.id,
    required this.label,
    required this.checked,
    this.enabled = true,
  }) : kind = SystemTrayMenuItemKind.checkbox,
       children = const [];

  const SystemTrayMenuItem.submenu({
    required this.label,
    required this.children,
    this.enabled = true,
  }) : id = null,
       kind = SystemTrayMenuItemKind.submenu,
       checked = false;

  final String? id;
  final String label;
  final SystemTrayMenuItemKind kind;
  final bool enabled;
  final bool checked;
  final List<SystemTrayMenuItem> children;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'label': label,
    'kind': kind.name,
    'enabled': enabled,
    'checked': checked,
    if (children.isNotEmpty)
      'children': [for (final child in children) child.toMap()],
  };

  @override
  bool operator ==(Object other) =>
      other is SystemTrayMenuItem &&
      other.id == id &&
      other.label == label &&
      other.kind == kind &&
      other.enabled == enabled &&
      other.checked == checked &&
      _listEquals(other.children, children);

  @override
  int get hashCode =>
      Object.hash(id, label, kind, enabled, checked, Object.hashAll(children));
}

/// 托盘图标提示文案与上下文菜单快照。
class SystemTrayState {
  const SystemTrayState({required this.tooltip, required this.items});

  final String tooltip;
  final List<SystemTrayMenuItem> items;

  @override
  bool operator ==(Object other) =>
      other is SystemTrayState &&
      other.tooltip == tooltip &&
      _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(tooltip, Object.hashAll(items));
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 桌面系统托盘抽象，便于生产环境对接原生实现并在测试中注入替身。
abstract interface class SystemTray {
  void setEventHandler({
    void Function()? onIconActivated,
    void Function(String itemId)? onMenuItemSelected,
  });

  Future<void> initialize();

  Future<void> update(SystemTrayState state);

  /// 窗口隐藏至后台托盘时通知宿主平台优化后台调度（如 macOS 抑制 App Nap）。
  Future<void> setBackgroundMode(bool active);

  Future<void> dispose();
}
