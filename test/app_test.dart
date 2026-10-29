import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/navigation/app_routes.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';

void main() {
  // 应用启动会向 GetX 全局容器注册依赖，测试间必须重置。
  tearDown(Get.reset);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();
  }

  testWidgets('应用壳渲染欢迎页与空主机侧边栏', (tester) async {
    await pumpApp(tester);
    expect(find.text('PagaShell'), findsNothing);
    expect(find.text('本地工作区'), findsOneWidget);
    expect(find.text('还没有服务'), findsOneWidget);
    expect(find.widgetWithText(shadcn.OutlineButton, '新建服务'), findsOneWidget);
    expect(Get.currentRoute, AppRoutes.workspace);
  });

  testWidgets('通过对话框新建服务后出现在侧边栏', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '新建服务'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      '10.0.0.8',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'db-01',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('db-01'), findsOneWidget);
    // 侧边栏只显示名字，不显示地址等副标题。
    expect(find.text('root@10.0.0.8'), findsNothing);
  });

  testWidgets('服务对话框无文件夹选择，「账号密码」方式密码入密文存储', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '新建服务'));
    await tester.pumpAndSettle();

    // 不再提供文件夹选择；登录方式二选一。
    expect(find.text('文件夹'), findsNothing);
    expect(find.text('账号密码'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    expect(find.text('已有凭证'), findsNothing);

    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      '10.0.0.9',
    );
    await tester.enterText(find.widgetWithText(AppTextFormField, '密码'), 'p@ss');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final controller = Get.find<HostController>();
    final host = controller.hosts.single;
    expect(host.identityId, isNull);
    expect(await controller.passwordOf(host.id), 'p@ss');
  });

  testWidgets('「已有凭证」方式必须选择凭证才能保存', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '新建服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已有凭证'));
    await tester.pumpAndSettle();

    expect(find.text('还没有凭证，可在侧边栏「凭证」组新建'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      '10.0.0.9',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 校验拦截：对话框未关闭，未生成主机。
    expect(find.text('请选择凭证'), findsOneWidget);
    expect(Get.find<HostController>().hosts, isEmpty);
  });
}
