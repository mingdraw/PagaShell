import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/app_theme_mode.dart';
import '../../domain/entities/sidebar_state.dart';
import '../../domain/repositories/settings_repository.dart';

class SettingsController extends GetxController {
  SettingsController({required this._repository});

  final SettingsRepository _repository;
  final themeMode = AppThemeMode.system.obs;
  final sidebarState = SidebarState().obs;
  final isLoaded = false.obs;
  late final Future<void> ready = _load();
  Future<void> _pendingSave = Future<void>.value();
  Future<void> _pendingSidebarSave = Future<void>.value();
  final _sidebarFolders = <SidebarSection, RxSet<String>>{};
  final _sidebarWorkers = <Worker>[];

  /// 当前已排队的显示偏好写入，用于退出或测试时等待落盘。
  Future<void> get sidebarSaved => _pendingSidebarSave;

  @override
  void onInit() {
    super.onInit();
    unawaited(ready);
  }

  Future<void> _load() async {
    try {
      final saved = await _repository.readThemeMode();
      if (!isClosed) themeMode.value = saved;
    } on Object {
      // 偏好读取失败时使用自动模式，仍允许打开应用和重新选择。
    }
    try {
      final saved = await _repository.readSidebarState();
      if (!isClosed) sidebarState.value = saved;
    } on Object {
      // 显示偏好不可读时保留默认布局，不影响主题和启动。
    }
    if (isClosed) return;
    for (final entry in _sidebarFolders.entries) {
      entry.value.assignAll(sidebarState.value.expandedFolders(entry.key));
    }
    isLoaded.value = true;
  }

  /// 追踪共享目录控制器的展开集合，覆盖点击、新建与拖入后的自动展开。
  /// 启动恢复完成前的赋值不会触发写入，避免默认值覆盖已保存的布局。
  void trackSidebarFolders(SidebarSection section, RxSet<String> expanded) {
    _sidebarFolders[section] = expanded;
    if (isLoaded.value) {
      expanded.assignAll(sidebarState.value.expandedFolders(section));
    }
    _sidebarWorkers.add(
      ever(expanded, (_) {
        if (!isLoaded.value) return;
        final next = sidebarState.value.withFolders(section, expanded.toSet());
        unawaited(
          _saveSidebarState(next).catchError((Object _) {
            // 保留当前显示；后续展开/折叠会重新保存完整快照。
          }),
        );
      }),
    );
  }

  Future<void> setSidebarVisible(bool visible) {
    if (sidebarState.value.visible == visible) return _pendingSidebarSave;
    return _saveSidebarState(sidebarState.value.withVisibility(visible));
  }

  Future<void> setSidebarSectionExpanded(
    SidebarSection section,
    bool expanded,
  ) {
    if (sidebarState.value.isSectionExpanded(section) == expanded) {
      return _pendingSidebarSave;
    }
    return _saveSidebarState(sidebarState.value.withSection(section, expanded));
  }

  Future<void> _saveSidebarState(SidebarState state) {
    sidebarState.value = state;
    // 点击立即更新界面，快照按顺序写入，避免快速操作后旧状态覆盖新状态。
    final save = _pendingSidebarSave.then((_) async {
      await ready;
      await _repository.saveSidebarState(state);
    });
    _pendingSidebarSave = save.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return save;
  }

  @override
  void onClose() {
    for (final worker in _sidebarWorkers) {
      worker.dispose();
    }
    super.onClose();
  }

  /// 顺序保存快速连续的选择；保存成功后再应用，失败时保留原模式。
  Future<void> setThemeMode(AppThemeMode mode) {
    final save = _pendingSave.then((_) async {
      await ready;
      if (isClosed || themeMode.value == mode) return;
      await _repository.saveThemeMode(mode);
      if (!isClosed) themeMode.value = mode;
    });
    _pendingSave = save.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return save;
  }
}
