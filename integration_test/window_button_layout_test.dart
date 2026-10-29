import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS 原生窗口按钮在初次显示和缩放后垂直居中', (tester) async {
    await tester.pumpWidget(const shadcn.ShadcnApp(home: SizedBox()));
    await windowManager.ensureInitialized();
    const channel = MethodChannel('pagashell/window');
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await channel.invokeMethod<void>('setTitleBarHeight', {
      'height': AppTheme.windowHeaderHeight,
    });

    final originalSize = await windowManager.getSize();
    try {
      for (final size in [const Size(1200, 760), const Size(1000, 640)]) {
        await windowManager.setSize(size);
        await tester.pumpAndSettle();
        final centers = await channel.invokeListMethod<double>(
          'getWindowButtonCenters',
        );
        expect(centers, hasLength(3));
        expect(
          centers,
          everyElement(closeTo(AppTheme.windowHeaderHeight / 2, 0.5)),
          reason: '窗口大小 $size 下三个按钮的中心应与顶部标签栏中心重合',
        );
      }
    } finally {
      await windowManager.setSize(originalSize);
    }
  }, skip: !Platform.isMacOS);
}
