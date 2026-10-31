import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_settings_repository.dart';

import '../support/in_memory_settings_repository.dart';

class _FailingSettings extends InMemorySettingsRepository {
  @override
  Future<void> saveAutomaticUpdates(bool enabled) async =>
      throw StateError('fixture write');
}

class _UnreadableSettings extends InMemorySettingsRepository {
  @override
  Future<bool> readAutomaticUpdates() async => throw StateError('fixture read');
}

void main() {
  test('自动更新默认开启，关闭后重建数据库和控制器仍保留', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-updates-setting-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final first = SettingsController(repository: DriftSettingsRepository(db));
    await first.ready;
    expect(first.automaticUpdates.value, isTrue);
    await first.setAutomaticUpdates(false);
    first.onClose();
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final second = SettingsController(
      repository: DriftSettingsRepository(reopened),
    );
    addTearDown(second.onClose);
    await second.ready;
    expect(second.automaticUpdates.value, isFalse);
    await second.setAutomaticUpdates(true);
    expect(
      await DriftSettingsRepository(reopened).readAutomaticUpdates(),
      isTrue,
    );
  });

  test('保存失败保留开关原值，读取失败不启动自动检查', () async {
    final failing = SettingsController(repository: _FailingSettings());
    await failing.ready;
    await expectLater(failing.setAutomaticUpdates(false), throwsStateError);
    expect(failing.automaticUpdates.value, isTrue);
    expect(failing.savingAutomaticUpdates.value, isFalse);
    failing.onClose();
    final unreadable = SettingsController(repository: _UnreadableSettings());
    await unreadable.ready;
    expect(unreadable.automaticUpdates.value, isFalse);
    expect(unreadable.isLoaded.value, isTrue);
    unreadable.onClose();
  });
}
