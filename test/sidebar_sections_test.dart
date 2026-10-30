import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();
  }

  testWidgets('侧边栏只展示「服务」「凭证」「网关」三个内置根组', (tester) async {
    await pumpApp(tester);

    expect(find.text('服务'), findsOneWidget);
    expect(find.text('凭证'), findsOneWidget);
    expect(find.text('网关'), findsOneWidget);
    expect(find.text('端口转发'), findsNothing);
    expect(findAppIconButton('端口转发组操作'), findsNothing);
  });

  testWidgets('内置根组右键菜单只有新建操作，不可重命名/删除', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('服务'), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('新建文件夹'), findsOneWidget);
    expect(find.text('新建端口转换'), findsNothing);
    expect(find.text('重命名'), findsNothing);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('根组图标和服务图标更新，只有文件夹保留三个点，侧栏底部按钮移除', (tester) async {
    await pumpApp(tester);
    await Get.find<HostController>().save(
      const Host(id: 'h', name: 'web', hostname: 'example.test'),
    );
    await Get.find<FolderController>().create(name: '服务目录');
    await Get.find<IdentityFolderController>().create(name: '凭证目录');
    await Get.find<IdentityController>().saveWithPassword(
      name: '凭证项',
      username: 'root',
      password: 'test',
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(shadcn.LucideIcons.server), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.fileTerminal), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.bookKey), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.fileKey), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.folderKey), findsOneWidget);
    expect(find.byIcon(shadcn.LucideIcons.ellipsis), findsNWidgets(2));
    for (final label in ['新建文件夹', '凭证管理', '端口转发（v1.0）', '新建服务  ⌘N']) {
      expect(findAppIconButton(label), findsNothing);
    }
    await tester.tap(find.text('web'), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('文件传输'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(shadcn.MenuButton, '文件传输'),
        matching: find.byIcon(shadcn.LucideIcons.folderOpen),
      ),
      findsOneWidget,
    );
    expect(find.text('端口转发'), findsNothing);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通过「凭证」组菜单新建凭证并显示在组内', (tester) async {
    await pumpApp(tester);

    await tester.tap(findAppIconButton('凭证组操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('新建凭证'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'CI 部署',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '用户名'),
      'deploy',
    );
    await tester.enterText(find.widgetWithText(AppTextFormField, '密码'), 'p@ss');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('CI 部署'), findsOneWidget);
    // 侧边栏只显示凭证名字，不显示用户名副标题。
    expect(find.text('deploy'), findsNothing);
    expect(find.byIcon(shadcn.LucideIcons.ellipsis), findsNothing);

    await tester.tap(find.text('CI 部署'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppTextFormField, '名称'), findsOneWidget);
    expect(find.text('CI 部署'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
