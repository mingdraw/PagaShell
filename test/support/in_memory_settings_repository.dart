import 'package:pagashell/domain/entities/app_proxy_settings.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/repositories/settings_repository.dart';
import 'package:pagashell/domain/terminal/quick_command.dart';

class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository({
    this.themeMode = AppThemeMode.system,
    this.languageCode,
    this.automaticUpdates = true,
    this.closeTerminalOnDisconnect = false,
    this.proxySettings = const AppProxySettings(),
    this.customQuickCommandGroups = const [],
    SidebarState? sidebarState,
  }) : sidebarState = sidebarState ?? SidebarState();

  AppThemeMode themeMode;
  String? languageCode;
  bool automaticUpdates;
  bool closeTerminalOnDisconnect;
  AppProxySettings proxySettings;
  List<QuickCommandCategory> customQuickCommandGroups;

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
  Future<String?> readLanguageCode() async => languageCode;

  @override
  Future<void> saveLanguageCode(String code) async => languageCode = code;

  @override
  Future<SidebarState> readSidebarState() async => sidebarState;

  @override
  Future<void> saveSidebarState(SidebarState state) async =>
      sidebarState = state;

  @override
  Future<bool> readCloseTerminalOnDisconnect() async =>
      closeTerminalOnDisconnect;

  @override
  Future<void> saveCloseTerminalOnDisconnect(bool enabled) async =>
      closeTerminalOnDisconnect = enabled;

  @override
  Future<AppProxySettings> readProxySettings() async => proxySettings;

  @override
  Future<void> saveProxySettings(AppProxySettings settings) async =>
      proxySettings = settings;

  @override
  Future<List<QuickCommandCategory>> readCustomQuickCommandGroups() async =>
      List.unmodifiable(customQuickCommandGroups);

  @override
  Future<void> saveCustomQuickCommandGroups(
    List<QuickCommandCategory> groups,
  ) async => customQuickCommandGroups = List.unmodifiable(groups);
}
