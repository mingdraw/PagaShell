import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';

import '../support/in_memory_settings_repository.dart';

void main() {
  test('启动恢复根组与三类文件夹，恢复过程不覆盖已保存状态', () async {
    final repository = _DelayedSidebarRepository();
    repository.sidebarState = SidebarState(
      visible: false,
      sections: {
        SidebarSection.services: false,
        SidebarSection.gateways: false,
      },
      folders: {
        SidebarSection.services: {'service-folder'},
        SidebarSection.identities: {'identity-folder'},
        SidebarSection.gateways: {'gateway-folder'},
      },
    );
    final controller = SettingsController(repository: repository);
    final sets = {
      for (final section in SidebarSection.values) section: <String>{}.obs,
    };
    for (final entry in sets.entries) {
      controller.trackSidebarFolders(entry.key, entry.value);
    }
    await controller.ready;
    expect(controller.isLoaded.value, isTrue);
    expect(controller.sidebarState.value.visible, isFalse);
    expect(
      controller.sidebarState.value.isSectionExpanded(SidebarSection.services),
      isFalse,
    );
    expect(
      controller.sidebarState.value.isSectionExpanded(
        SidebarSection.identities,
      ),
      isTrue,
    );
    expect(
      controller.sidebarState.value.isSectionExpanded(SidebarSection.gateways),
      isFalse,
    );
    expect(sets[SidebarSection.services], {'service-folder'});
    expect(sets[SidebarSection.identities], {'identity-folder'});
    expect(sets[SidebarSection.gateways], {'gateway-folder'});
    expect(repository.writes, isEmpty);
    controller.onClose();
  });

  test('快速展开折叠和自动展开保存完整快照，慢写入不会覆盖最新状态', () async {
    final repository = _DelayedSidebarRepository();
    final controller = SettingsController(repository: repository);
    final services = <String>{}.obs;
    final identities = <String>{}.obs;
    final gateways = <String>{}.obs;
    controller.trackSidebarFolders(SidebarSection.services, services);
    controller.trackSidebarFolders(SidebarSection.identities, identities);
    controller.trackSidebarFolders(SidebarSection.gateways, gateways);
    await controller.ready;
    final collapsed = controller.setSidebarSectionExpanded(
      SidebarSection.services,
      false,
    );
    await repository.started.future;
    final hidden = controller.setSidebarVisible(false);
    services.add('outer');
    services.add('inner');
    services.remove('inner');
    identities.add('credentials');
    gateways.add('jump');
    final expanded = controller.setSidebarSectionExpanded(
      SidebarSection.services,
      true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.sidebarState.value.isSectionExpanded(SidebarSection.services),
      isTrue,
    );
    expect(repository.writes, hasLength(1));
    repository.resume.complete();
    await Future.wait([collapsed, hidden, expanded]);
    await controller.sidebarSaved;
    final restored = SettingsController(repository: repository);
    await restored.ready;
    expect(restored.sidebarState.value.visible, isFalse);
    expect(
      restored.sidebarState.value.isSectionExpanded(SidebarSection.services),
      isTrue,
    );
    expect(
      restored.sidebarState.value.expandedFolders(SidebarSection.services),
      {'outer'},
    );
    expect(
      restored.sidebarState.value.expandedFolders(SidebarSection.identities),
      {'credentials'},
    );
    expect(
      restored.sidebarState.value.expandedFolders(SidebarSection.gateways),
      {'jump'},
    );
    controller.onClose();
    restored.onClose();
  });

  test('侧栏读取失败仍加载主题，后续操作能够重新保存显示偏好', () async {
    final repository = _UnreadableSidebarRepository(
      themeMode: AppThemeMode.light,
    );
    final controller = SettingsController(repository: repository);
    await controller.ready;
    expect(controller.themeMode.value, AppThemeMode.light);
    expect(controller.isLoaded.value, isTrue);
    for (final section in SidebarSection.values) {
      expect(controller.sidebarState.value.isSectionExpanded(section), isTrue);
      expect(controller.sidebarState.value.expandedFolders(section), isEmpty);
    }
    await controller.setSidebarSectionExpanded(
      SidebarSection.identities,
      false,
    );
    expect(
      repository.sidebarState.isSectionExpanded(SidebarSection.identities),
      isFalse,
    );
    controller.onClose();
  });

  test('读取失败时仍完成初始化并使用自动模式', () async {
    final controller = SettingsController(repository: _UnreadableRepository());
    await controller.ready;
    expect(controller.isLoaded.value, isTrue);
    expect(controller.themeMode.value, AppThemeMode.system);
  });

  test('保存失败保留当前模式，后续选择仍能保存', () async {
    final repository = _FailingRepository(themeMode: AppThemeMode.light);
    final controller = SettingsController(repository: repository);
    await controller.ready;
    await expectLater(
      controller.setThemeMode(AppThemeMode.dark),
      throwsStateError,
    );
    expect(controller.themeMode.value, AppThemeMode.light);
    expect(repository.themeMode, AppThemeMode.light);
    repository.fail = false;
    await controller.setThemeMode(AppThemeMode.dark);
    expect(controller.themeMode.value, AppThemeMode.dark);
    expect(repository.themeMode, AppThemeMode.dark);
  });

  test('快速连续选择按顺序保存，最终偏好与显示一致', () async {
    final repository = _DelayedSaveRepository();
    final controller = SettingsController(repository: repository);
    await controller.ready;
    final dark = controller.setThemeMode(AppThemeMode.dark);
    final light = controller.setThemeMode(AppThemeMode.light);
    await repository.started.future;
    expect(repository.writes, [AppThemeMode.dark]);
    repository.resume.complete();
    await Future.wait([dark, light]);
    expect(repository.writes, [AppThemeMode.dark, AppThemeMode.light]);
    expect(controller.themeMode.value, AppThemeMode.light);
    expect(repository.themeMode, AppThemeMode.light);
  });
}

class _UnreadableSidebarRepository extends InMemorySettingsRepository {
  _UnreadableSidebarRepository({super.themeMode});

  @override
  Future<SidebarState> readSidebarState() async =>
      throw StateError('read failed');
}

class _DelayedSidebarRepository extends InMemorySettingsRepository {
  final started = Completer<void>();
  final resume = Completer<void>();
  final writes = <SidebarState>[];

  @override
  Future<void> saveSidebarState(SidebarState state) async {
    writes.add(state);
    if (writes.length == 1) {
      started.complete();
      await resume.future;
    }
    await super.saveSidebarState(state);
  }
}

class _UnreadableRepository extends InMemorySettingsRepository {
  @override
  Future<AppThemeMode> readThemeMode() async => throw StateError('read failed');
}

class _FailingRepository extends InMemorySettingsRepository {
  _FailingRepository({super.themeMode});

  bool fail = true;

  @override
  Future<void> saveThemeMode(AppThemeMode mode) async {
    if (fail) throw StateError('write failed');
    await super.saveThemeMode(mode);
  }
}

class _DelayedSaveRepository extends InMemorySettingsRepository {
  final started = Completer<void>();
  final resume = Completer<void>();
  final writes = <AppThemeMode>[];

  @override
  Future<void> saveThemeMode(AppThemeMode mode) async {
    writes.add(mode);
    if (writes.length == 1) {
      started.complete();
      await resume.future;
    }
    await super.saveThemeMode(mode);
  }
}
