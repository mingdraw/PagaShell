import 'dart:convert';

import '../../domain/entities/app_theme_mode.dart';
import '../../domain/entities/sidebar_state.dart';
import '../../domain/repositories/settings_repository.dart';
import 'app_database.dart';

class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._db);

  final AppDatabase _db;
  static const _themeModeKey = 'theme_mode';
  static const _sidebarStateKey = 'sidebar_state';

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
      return SidebarState(
        visible: decoded['visible'] is bool ? decoded['visible'] as bool : true,
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
            'sections': {
              for (final entry in state.sections.entries)
                entry.key.name: entry.value,
            },
            'folders': {
              for (final entry in state.folders.entries)
                entry.key.name: entry.value.toList(),
            },
          }),
        ),
      );
}
