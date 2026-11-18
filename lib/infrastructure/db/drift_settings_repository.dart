import 'dart:convert';

import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/entities/app_theme_mode.dart';
import '../../domain/entities/sidebar_state.dart';
import '../../domain/repositories/settings_repository.dart';
import 'app_database.dart';

class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._db);

  final AppDatabase _db;
  static const _themeModeKey = 'theme_mode';
  static const _sidebarStateKey = 'sidebar_state';
  static const _automaticUpdatesKey = 'automatic_updates';
  static const _proxySettingsKey = 'proxy_settings';

  @override
  Future<bool> readAutomaticUpdates() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_automaticUpdatesKey))).getSingleOrNull();
    return row == null || row.value == 'true';
  }

  @override
  Future<void> saveAutomaticUpdates(bool enabled) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: _automaticUpdatesKey,
          value: enabled.toString(),
        ),
      );

  @override
  Future<AppThemeMode> readThemeMode() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_themeModeKey))).getSingleOrNull();
    return AppThemeMode.values.firstWhere(
      (mode) => mode.name == row?.value,
      orElse: () => AppThemeMode.system,
    );
  }

  @override
  Future<void> saveThemeMode(AppThemeMode mode) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: _themeModeKey, value: mode.name),
      );

  @override
  Future<SidebarState> readSidebarState() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_sidebarStateKey))).getSingleOrNull();
    if (row == null) return SidebarState();
    try {
      final Object? decoded = jsonDecode(row.value);
      if (decoded is! Map<String, dynamic>) return SidebarState();
      final sections = decoded['sections'];
      final folders = decoded['folders'];
      final recentHosts = decoded['recentHosts'];
      final width = decoded['width'];
      final terminalFontSize = decoded['terminalFontSize'];
      return SidebarState(
        visible: decoded['visible'] is bool ? decoded['visible'] as bool : true,
        width: width is num ? width.toDouble() : SidebarState.defaultWidth,
        terminalFontSize: terminalFontSize is num
            ? terminalFontSize.toDouble()
            : SidebarState.defaultTerminalFontSize,
        sections: {
          for (final section in SidebarSection.values)
            if (sections is Map<String, dynamic> &&
                sections[section.name] is bool)
              section: sections[section.name] as bool,
        },
        folders: {
          for (final section in SidebarSection.values)
            if (folders is Map<String, dynamic> &&
                folders[section.name] is List)
              section: (folders[section.name] as List<dynamic>)
                  .whereType<String>()
                  .toSet(),
        },
        recentHostIds: recentHosts is List
            ? recentHosts.whereType<String>().toList()
            : const [],
      );
    } on FormatException {
      return SidebarState();
    }
  }

  @override
  Future<void> saveSidebarState(SidebarState state) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: _sidebarStateKey,
          value: jsonEncode({
            'visible': state.visible,
            'width': state.width,
            'terminalFontSize': state.terminalFontSize,
            'sections': {
              for (final entry in state.sections.entries)
                entry.key.name: entry.value,
            },
            'folders': {
              for (final entry in state.folders.entries)
                entry.key.name: entry.value.toList(),
            },
            'recentHosts': state.recentHostIds,
          }),
        ),
      );

  @override
  Future<AppProxySettings> readProxySettings() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_proxySettingsKey))).getSingleOrNull();
    if (row == null) return const AppProxySettings();
    final Object? decoded = jsonDecode(row.value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid proxy settings');
    }
    final modeName = decoded['mode'];
    final protocolName = decoded['protocol'];
    final mode = AppProxyMode.values
        .where((value) => value.name == modeName)
        .firstOrNull;
    final protocol = AppProxyProtocol.values
        .where((value) => value.name == protocolName)
        .firstOrNull;
    if (mode == null || protocol == null) {
      throw const FormatException('Invalid proxy settings');
    }
    return AppProxySettings(
      mode: mode,
      protocol: protocol,
      address: decoded['address'] is String ? decoded['address'] as String : '',
      username: decoded['username'] is String
          ? decoded['username'] as String
          : '',
      passwordSecretRef: decoded['passwordSecretRef'] is String
          ? decoded['passwordSecretRef'] as String
          : '',
      pendingSecretDeletes: decoded['pendingSecretDeletes'] is List
          ? (decoded['pendingSecretDeletes'] as List<dynamic>)
                .whereType<String>()
                .toList()
          : const [],
    );
  }

  @override
  Future<void> saveProxySettings(AppProxySettings settings) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: _proxySettingsKey,
          value: jsonEncode({
            'mode': settings.mode.name,
            'protocol': settings.protocol.name,
            'address': settings.address,
            'username': settings.username,
            'passwordSecretRef': settings.passwordSecretRef,
            'pendingSecretDeletes': settings.pendingSecretDeletes,
          }),
        ),
      );
}
