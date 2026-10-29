import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/navigation/app_notice.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  testWidgets('提示条显示时仍能返回对话框结果且不退出根页面', (tester) async {
    bool? result;
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: shadcn.OutlineButton(
            child: const Text('确认'),
            onPressed: () async {
              result = await AppNavigation.dialog<bool>(
                AppDialog(
                  title: const Text('操作确认'),
                  content: const Text('确认继续'),
                  actions: [
                    shadcn.OutlineButton(
                      onPressed: () => AppNavigation.closeDialog(result: true),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    AppNotice.error('测试提示');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(Get.isDialogOpen, isTrue);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('操作确认'), findsNothing);
    expect(find.text('确认'), findsOneWidget);
    // shadcn Toast 的自动关闭与弹窗路由互不影响。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
