import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_known_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_settings_repository.dart';

void main() {
  test('侧栏偏好缺失或损坏时使用默认布局，无效字段不影响其他分组', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftSettingsRepository(db);
    Future<void> defaults() async {
      final state = await repository.readSidebarState();
      expect(state.visible, isTrue);
      for (final section in SidebarSection.values) {
        expect(state.isSectionExpanded(section), isTrue);
        expect(state.expandedFolders(section), isEmpty);
      }
    }

    await defaults();
    for (final value in ['broken', '[]', '{"sections":false,"folders":0}']) {
      await db
          .into(db.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(key: 'sidebar_state', value: value),
          );
      await defaults();
    }
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'sidebar_state',
            value: '{"sections":{"services":false,"identities":"invalid"},"folders":{"services":["valid",5,"valid"],"gateways":false}}',
          ),
        );
    final state = await repository.readSidebarState();
    expect(state.isSectionExpanded(SidebarSection.services), isFalse);
    expect(state.isSectionExpanded(SidebarSection.identities), isTrue);
    expect(state.expandedFolders(SidebarSection.services), {'valid'});
    expect(state.expandedFolders(SidebarSection.gateways), isEmpty);
  });

  test('侧栏布局关闭数据库再打开后恢复，各组同名目录 ID 独立且保留主题', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-sidebar-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final repository = DriftSettingsRepository(db);
    await repository.saveThemeMode(AppThemeMode.dark);
    await repository.saveSidebarState(
      SidebarState(
        visible: false,
        sections: {
          SidebarSection.services: false,
          SidebarSection.identities: true,
          SidebarSection.gateways: false,
        },
        folders: {
          SidebarSection.services: {'same-id', 'nested-id'},
          SidebarSection.identities: {'same-id'},
          SidebarSection.gateways: {},
        },
      ),
    );
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final settings = DriftSettingsRepository(reopened);
    final state = await settings.readSidebarState();
    expect(state.visible, isFalse);
    expect(state.isSectionExpanded(SidebarSection.services), isFalse);
    expect(state.isSectionExpanded(SidebarSection.identities), isTrue);
    expect(state.isSectionExpanded(SidebarSection.gateways), isFalse);
    expect(state.expandedFolders(SidebarSection.services), {
      'same-id',
      'nested-id',
    });
    expect(state.expandedFolders(SidebarSection.identities), {'same-id'});
    expect(state.expandedFolders(SidebarSection.gateways), isEmpty);
    expect(await settings.readThemeMode(), AppThemeMode.dark);
  });

  test('缺失或无效偏好回退自动，三种模式均可覆盖保存', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftSettingsRepository(db);
    expect(await repository.readThemeMode(), AppThemeMode.system);
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: 'theme_mode', value: 'unknown'),
        );
    expect(await repository.readThemeMode(), AppThemeMode.system);
    for (final mode in [
      AppThemeMode.dark,
      AppThemeMode.light,
      AppThemeMode.system,
    ]) {
      await repository.saveThemeMode(mode);
      expect(await repository.readThemeMode(), mode);
    }
    expect(await db.select(db.appSettings).get(), hasLength(1));
  });

  test('版本 2 升级保留主机和指纹，主题选择关闭重开后恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await DriftHostRepository(old)
        .upsert(const Host(id: 'h1', name: 'saved', hostname: 'example.test'));
    const key = SshHostKey(
      hostname: 'example.test',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:preserved',
    );
    await DriftKnownHostRepository(old).trustIfAbsent(key);
    await old.customStatement('DROP TABLE app_settings');
    await old.customStatement('DROP TABLE identity_folders');
    await old.customStatement('ALTER TABLE identities DROP COLUMN folder_id');
    await old.customStatement('ALTER TABLE identities DROP COLUMN sort_order');
    await old.customStatement('ALTER TABLE folders DROP COLUMN is_gateway');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN is_gateway');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN forward_ports_json',
    );
    await old.customStatement('DROP TABLE IF EXISTS forward_folders');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN gateway_type');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN rdp_domain');
    await old.customStatement('ALTER TABLE hosts DROP COLUMN page_client_id');
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN page_server_fingerprint',
    );
    await old.customStatement(
      'ALTER TABLE identities DROP COLUMN service_type',
    );
    await old.customStatement(
      'ALTER TABLE hosts DROP COLUMN proxy_config_json',
    );
    await old.customStatement('PRAGMA user_version = 2');
    await old.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    expect((await DriftHostRepository(upgraded).getAll()).single.name, 'saved');
    expect(
      (await DriftKnownHostRepository(
        upgraded,
      ).find('example.test', 22))?.fingerprint,
      key.fingerprint,
    );
    final repository = DriftSettingsRepository(upgraded);
    expect(await repository.readThemeMode(), AppThemeMode.system);
    await repository.saveThemeMode(AppThemeMode.dark);
    await upgraded.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      await DriftSettingsRepository(reopened).readThemeMode(),
      AppThemeMode.dark,
    );
  });
}
