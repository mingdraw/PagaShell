import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  Future<void> createFolder(WidgetTester tester, String name) async {
    await tester.tap(findAppIconButton('服务组操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(AppTextFormField, '名称'), name);
    await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '确定'));
    await tester.pumpAndSettle();
  }

  testWidgets('新建文件夹后出现在侧边栏且不崩溃', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();

    await createFolder(tester, '生产环境');

    expect(find.text('生产环境'), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.ellipsis), findsOneWidget);

    await tester.tap(find.text('生产环境'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('在此新建服务'), findsOneWidget);
    expect(find.text('新建文件夹'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('生产环境'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(shadcn.LucideIcons.ellipsis));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppTextFormField, '名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同级重复文件夹名被拒绝并就地提示', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();

    await createFolder(tester, '生产环境');
    await createFolder(tester, '生产环境');

    // 对话框未关闭，显示重名错误。
    expect(find.text('同级下已存在同名文件夹'), findsOneWidget);
    expect(find.widgetWithText(shadcn.PrimaryButton, '确定'), findsOneWidget);
    // 侧边栏仍只有一个同名文件夹。
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('生产环境'), findsOneWidget);
  });
}
