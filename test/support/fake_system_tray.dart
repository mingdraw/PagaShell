import 'package:pagashell/domain/tray/system_tray.dart';

/// 系统托盘内存替身，供单测和组件测试记录状态更新与模拟托盘点击事件。
class FakeSystemTray implements SystemTray {
  final calls = <String>[];
  final states = <SystemTrayState>[];
  final backgroundModes = <bool>[];
  bool initialized = false;
  bool disposed = false;

  void Function()? _onIconActivated;
  void Function(String itemId)? _onMenuItemSelected;

  SystemTrayState? get latestState => states.isEmpty ? null : states.last;

  void emitIconActivated() {
    _onIconActivated?.call();
  }

  void emitMenuItemSelected(String itemId) {
    _onMenuItemSelected?.call(itemId);
  }

  @override
  void setEventHandler({
    void Function()? onIconActivated,
    void Function(String itemId)? onMenuItemSelected,
  }) {
    _onIconActivated = onIconActivated;
    _onMenuItemSelected = onMenuItemSelected;
  }

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    initialized = true;
  }

  @override
  Future<void> update(SystemTrayState state) async {
    calls.add('update');
    states.add(state);
  }

  @override
  Future<void> setBackgroundMode(bool active) async {
    calls.add('setBackgroundMode:$active');
    backgroundModes.add(active);
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
  }
}
