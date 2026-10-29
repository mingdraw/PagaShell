import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'application/app_binding.dart';
import 'application/settings/settings_controller.dart';
import 'domain/entities/app_theme_mode.dart';
import 'presentation/localization/app_translations.dart';
import 'presentation/navigation/app_routes.dart';
import 'presentation/theme/app_theme.dart';

class PagaShellApp extends StatefulWidget {
  const PagaShellApp({super.key, this.binding, this.platform});

  /// 依赖装配。默认使用持久化的 [AppBinding]；测试可注入内存实现的替身。
  final Bindings? binding;

  /// 默认使用运行平台；组件测试可显式指定目标桌面平台。
  final TargetPlatform? platform;

  @override
  State<PagaShellApp> createState() => _PagaShellAppState();
}

class _PagaShellAppState extends State<PagaShellApp> {
  late final SettingsController _settings;

  @override
  void initState() {
    super.initState();
    Get.locale ??= AppTranslations.defaultLocale;
    Get.fallbackLocale = AppTranslations.defaultLocale;
    Get.addTranslations(AppTranslations().keys);
    Get.addPages(AppRoutes.pages);
    (widget.binding ?? AppBinding()).dependencies();
    _settings = Get.find<SettingsController>();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 首帧使用已保存的模式，避免启动时先显示系统主题再跳变。
      if (!_settings.isLoaded.value) return const SizedBox.shrink();
      return shadcn.ShadcnApp(
        title: 'PagaShell',
        debugShowCheckedModeBanner: false,
        locale: Get.locale ?? AppTranslations.defaultLocale,
        supportedLocales: AppTranslations.supportedLocales,
        themeMode: switch (_settings.themeMode.value) {
          AppThemeMode.system => shadcn.ThemeMode.system,
          AppThemeMode.light => shadcn.ThemeMode.light,
          AppThemeMode.dark => shadcn.ThemeMode.dark,
        },
        theme: widget.platform == null
            ? AppTheme.shadcnLight
            : AppTheme.shadcnLight.copyWith(platform: () => widget.platform!),
        darkTheme: widget.platform == null
            ? AppTheme.shadcnDark
            : AppTheme.shadcnDark.copyWith(platform: () => widget.platform!),
        scaling: shadcn.AdaptiveScaling.desktop,
        navigatorKey: Get.key,
        navigatorObservers: [GetObserver(null, Get.routing)],
        initialRoute: AppRoutes.workspace,
        onGenerateRoute: (settings) {
          final page = AppRoutes.pages.firstWhere(
            (page) => page.name == settings.name,
            orElse: () => AppRoutes.pages.first,
          );
          return GetPageRoute<void>(
            settings: settings,
            routeName: page.name,
            page: page.page,
            binding: page.binding,
            bindings: page.bindings,
            middlewares: page.middlewares,
            transition: Transition.noTransition,
          );
        },
      );
    });
  }
}
