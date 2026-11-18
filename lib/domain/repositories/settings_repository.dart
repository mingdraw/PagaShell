import '../entities/app_proxy_settings.dart';
import '../entities/app_theme_mode.dart';
import '../entities/sidebar_state.dart';

abstract interface class SettingsRepository {
  Future<AppThemeMode> readThemeMode();

  Future<void> saveThemeMode(AppThemeMode mode);

  Future<SidebarState> readSidebarState();

  Future<void> saveSidebarState(SidebarState state);

  Future<bool> readAutomaticUpdates();

  Future<void> saveAutomaticUpdates(bool enabled);

  Future<AppProxySettings> readProxySettings();

  Future<void> saveProxySettings(AppProxySettings settings);
}
