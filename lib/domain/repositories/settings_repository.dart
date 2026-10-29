import '../entities/app_theme_mode.dart';
import '../entities/sidebar_state.dart';

abstract interface class SettingsRepository {
  Future<AppThemeMode> readThemeMode();

  Future<void> saveThemeMode(AppThemeMode mode);

  Future<SidebarState> readSidebarState();

  Future<void> saveSidebarState(SidebarState state);
}
