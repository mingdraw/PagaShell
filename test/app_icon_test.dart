import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  for (final (label, theme) in [
    ('浅色', AppTheme.shadcnLight),
    ('深色', AppTheme.shadcnDark),
  ]) {
    testWidgets('$label主题下全部 SVG 图标在紧凑尺寸中正常渲染', (tester) async {
      await tester.pumpWidget(
        ShadcnTestApp(
          theme: theme,
          home: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final icon in AppIcons.values) AppIcon(icon, size: 16),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Iconify), findsNWidgets(AppIcons.values.length));
      for (final icon in tester.widgetList<Iconify>(find.byType(Iconify))) {
        expect(icon.color, theme.colorScheme.foreground);
        expect(icon.size, 16);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('SVG 图标继承 IconTheme 并合并前景透明度', (tester) async {
    const color = Color(0xFF336699);
    await tester.pumpWidget(
      const ShadcnTestApp(
        home: Center(
          child: IconTheme(
            data: IconThemeData(size: 18, color: color, opacity: 0.4),
            child: AppIcon(AppIcons.server),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final icon = tester.widget<Iconify>(find.byType(Iconify));
    expect(icon.size, 18);
    expect(icon.color, color.withValues(alpha: 0.4));
    expect(tester.getSize(find.byType(Iconify)), const Size.square(18));
    expect(tester.takeException(), isNull);
  });

  for (final icon in [AppIcons.panelLeftClose, AppIcons.statusCpu]) {
    testWidgets('${icon.name} 保留图形与透明背景', (tester) async {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        ShadcnTestApp(
          home: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: AppIcon(icon, size: 24, color: const Color(0xFF000000)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var visiblePixels = 0;
          var transparentPixels = 0;
          for (var i = 3; i < rgba.lengthInBytes; i += 4) {
            if (rgba.getUint8(i) == 0) {
              transparentPixels++;
            } else {
              visiblePixels++;
            }
          }
          expect(visiblePixels, greaterThan(0));
          expect(transparentPixels, greaterThan(0));
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窗口按钮的紧约束不拉伸 SVG 且保留无障碍名称', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        const ShadcnTestApp(
          home: Center(
            child: SizedBox(
              width: 44,
              height: 36,
              child: AppIcon(
                AppIcons.x,
                size: 15,
                color: shadcn.Colors.red,
                semanticLabel: '关闭窗口',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Iconify)), const Size.square(15));
      expect(
        tester.getCenter(find.byType(Iconify)),
        tester.getCenter(find.byType(AppIcon)),
      );
      expect(find.bySemanticsLabel('关闭窗口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
