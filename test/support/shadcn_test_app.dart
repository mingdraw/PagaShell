import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

/// 与生产应用相同的纯 shadcn 宿主；测试自行装配需要的依赖。
class ShadcnTestApp extends StatefulWidget {
  const ShadcnTestApp({required this.home, this.locale, this.theme, super.key});
  final Widget home;
  final Locale? locale;
  final shadcn.ThemeData? theme;

  @override
  State<ShadcnTestApp> createState() => _ShadcnTestAppState();
}

class _ShadcnTestAppState extends State<ShadcnTestApp> {
  @override
  void initState() {
    super.initState();
    Get.addTranslations(AppTranslations().keys);
    Get.locale = widget.locale ?? AppTranslations.defaultLocale;
    Get.fallbackLocale = AppTranslations.defaultLocale;
  }

  @override
  Widget build(BuildContext context) => shadcn.ShadcnApp(
    navigatorKey: Get.key,
    navigatorObservers: [GetObserver(null, Get.routing)],
    locale: widget.locale ?? Get.locale,
    supportedLocales: AppTranslations.supportedLocales,
    theme: (widget.theme ?? AppTheme.shadcnDark).copyWith(
      platform: () => TargetPlatform.macOS,
    ),
    themeMode: shadcn.ThemeMode.dark,
    scaling: shadcn.AdaptiveScaling.desktop,
    home: widget.home,
  );
}

Finder findAppIconButton(String label) => find.byWidgetPredicate(
  (widget) => widget is AppIconButton && widget.semanticLabel == label,
);
