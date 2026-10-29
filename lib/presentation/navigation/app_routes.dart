import 'package:get/get.dart';

import '../shell/shell_page.dart';

abstract final class AppRoutes {
  static const workspace = '/workspace';

  static final pages = <GetPage<dynamic>>[
    GetPage(name: workspace, page: () => const ShellPage()),
  ];
}
