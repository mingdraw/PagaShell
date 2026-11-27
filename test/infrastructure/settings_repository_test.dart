import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';
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
        width: 320,
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
        recentHostIds: const ['host-2', 'host-1'],
      ),
    );
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final settings = DriftSettingsRepository(reopened);
    final state = await settings.readSidebarState();
    expect(state.visible, isFalse);
    expect(state.width, 320);
    expect(state.isSectionExpanded(SidebarSection.services), isFalse);
    expect(state.isSectionExpanded(SidebarSection.identities), isTrue);
    expect(state.isSectionExpanded(SidebarSection.gateways), isFalse);
    expect(state.expandedFolders(SidebarSection.services), {
      'same-id',
      'nested-id',
    });
    expect(state.expandedFolders(SidebarSection.identities), {'same-id'});
    expect(state.expandedFolders(SidebarSection.gateways), isEmpty);
    expect(state.recentHostIds, ['host-2', 'host-1']);
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

  test('终端断开行为默认保留窗格，保存的选择重开数据库后恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-terminal-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final repository = DriftSettingsRepository(db);
    try {
      expect(await repository.readCloseTerminalOnDisconnect(), isFalse);
      await repository.saveCloseTerminalOnDisconnect(true);
    } finally {
      await db.close();
    }

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final settings = DriftSettingsRepository(reopened);
    expect(await settings.readCloseTerminalOnDisconnect(), isTrue);
    await settings.saveCloseTerminalOnDisconnect(false);
    expect(await settings.readCloseTerminalOnDisconnect(), isFalse);
  });

  test('关闭最小化到托盘默认关闭，保存的选择重开数据库后恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pagashell-tray-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final repository = DriftSettingsRepository(db);
    try {
      expect(await repository.readMinimizeToTrayOnClose(), isFalse);
      await repository.saveMinimizeToTrayOnClose(true);
    } finally {
      await db.close();
    }

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final settings = DriftSettingsRepository(reopened);
    expect(await settings.readMinimizeToTrayOnClose(), isTrue);
    await settings.saveMinimizeToTrayOnClose(false);
    expect(await settings.readMinimizeToTrayOnClose(), isFalse);
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
    await old.customStatement('ALTER TABLE identities DROP COLUMN rdp_domain');
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

  test('代理设置默认自动，支持持久化且损坏配置抛出异常', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftSettingsRepository(db);
    final initial = await repository.readProxySettings();
    expect(initial.mode, AppProxyMode.auto);
    expect(initial.protocol, AppProxyProtocol.http);

    const saved = AppProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.socks5,
      address: '127.0.0.1:1080',
      username: 'alice',
      passwordSecretRef: 'proxy-auth-1',
      pendingSecretDeletes: ['old-ref'],
    );
    await repository.saveProxySettings(saved);
    final loaded = await repository.readProxySettings();
    expect(loaded.mode, AppProxyMode.manual);
    expect(loaded.protocol, AppProxyProtocol.socks5);
    expect(loaded.address, '127.0.0.1:1080');
    expect(loaded.username, 'alice');
    expect(loaded.passwordSecretRef, 'proxy-auth-1');
    expect(loaded.pendingSecretDeletes, ['old-ref']);

    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: 'proxy_settings', value: 'broken'),
        );
    await expectLater(repository.readProxySettings(), throwsFormatException);
  });

  test('终端字号按 pt 持久化，旧版无单位配置按平台平滑迁移', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 旧版未写入 terminalFontSizeUnit（原为逻辑像素）：
    // macOS 1:1 保留；Windows/Linux 从 96 DPI 逻辑像素换算为最近的 pt。
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'sidebar_state',
            value: '{"terminalFontSize":16}',
          ),
        );
    final macLegacy = await DriftSettingsRepository(
      db,
      isMacOS: true,
    ).readSidebarState();
    final winLegacy = await DriftSettingsRepository(
      db,
      isMacOS: false,
    ).readSidebarState();
    expect(macLegacy.terminalFontSize, 16);
    expect(winLegacy.terminalFontSize, 12);

    // 新版写入带 unit='pt' 后，各平台原样读取 pt 值。
    final writer = DriftSettingsRepository(db, isMacOS: false);
    await writer.saveSidebarState(SidebarState(terminalFontSize: 14));
    expect(
      (await DriftSettingsRepository(
        db,
        isMacOS: true,
      ).readSidebarState()).terminalFontSize,
      14,
    );
    expect(
      (await DriftSettingsRepository(
        db,
        isMacOS: false,
      ).readSidebarState()).terminalFontSize,
      14,
    );
  });
}
