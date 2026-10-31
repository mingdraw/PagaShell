import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/repositories/settings_repository.dart';

class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository({
    this.themeMode = AppThemeMode.system,
    this.automaticUpdates = true,
    SidebarState? sidebarState,
  }) : sidebarState = sidebarState ?? SidebarState();

  AppThemeMode themeMode;
  bool automaticUpdates;

  @override
  Future<bool> readAutomaticUpdates() async => automaticUpdates;

  @override
  Future<void> saveAutomaticUpdates(bool enabled) async =>
      automaticUpdates = enabled;
  SidebarState sidebarState;

  @override
  Future<AppThemeMode> readThemeMode() async => themeMode;

  @override
  Future<void> saveThemeMode(AppThemeMode mode) async => themeMode = mode;

  @override
  Future<SidebarState> readSidebarState() async => sidebarState;

  @override
  Future<void> saveSidebarState(SidebarState state) async =>
      sidebarState = state;
}
