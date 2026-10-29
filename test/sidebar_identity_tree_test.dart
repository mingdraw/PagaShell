import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/application/identities/identity_tree_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity_tree_item.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/identities/identity_manager_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

Finder _row(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byType(Draggable<IdentityTreeItem>),
);

void main() {
  tearDown(Get.reset);
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();
  }

  Future<String> addIdentity(String name, {String? folder}) async =>
      (await Get.find<IdentityController>().saveWithPassword(
        name: name,
        username: 'root',
        password: 'test-secret',
        folderId: folder,
      )).id;

  Future<void> drag(
    WidgetTester tester,
    String from,
    String to, {
    double startFraction = 0.5,
    double targetFraction = 0.5,
  }) async {
    final source = tester.getRect(_row(from));
    final target = tester.getRect(_row(to));
    final gesture = await tester.startGesture(
      Offset(
        tester.getCenter(find.text(from)).dx,
        source.top + source.height * startFraction,
      ),
      kind: ui.PointerDeviceKind.mouse,
    );
    await gesture.moveTo(
      Offset(target.left + 90, target.top + target.height * targetFraction),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  List<String> ids([String? parent]) => Get.find<IdentityTreeController>()
      .childrenOf(parent)
      .map((node) => node.item.id)
      .toList();

  testWidgets('凭证组菜单创建文件夹，文件夹菜单创建子文件夹及凭证', (tester) async {
    await pumpApp(tester);
    await tester.tap(findAppIconButton('凭证组操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(AppTextFormField, '名称'), '凭证目录');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final folders = Get.find<IdentityFolderController>();
    final parent = folders.folders.single;
    expect(Get.find<FolderController>().folders, isEmpty);
    expect(find.byIcon(shadcn.LucideIcons.folderKey), findsOneWidget);

    await tester.tap(find.text('凭证目录'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('新建子文件夹'), findsNothing);
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(AppTextFormField, '名称'), '子目录');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(folders.childrenOf(parent.id).single.name, '子目录');

    await tester.tap(find.text('子目录'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('在此新建凭证'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(AppTextFormField, '名称'), '部署');
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'password',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final identity = Get.find<IdentityController>().identities.single;
    expect(identity.folderId, folders.childrenOf(parent.id).single.id);
    expect(find.text('部署'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('部署'),
        matching: find.byIcon(shadcn.LucideIcons.fileKey),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final after in [false, true]) {
    testWidgets('凭证拖到文件夹${after ? '下' : '上'}边缘排序，抓取偏移不改变落点', (tester) async {
      await pumpApp(tester);
      final a = await addIdentity('a');
      final b = await addIdentity('b');
      final folder = await Get.find<IdentityFolderController>().create(
        name: '目录',
      );
      await tester.pumpAndSettle();
      await drag(
        tester,
        'a',
        '目录',
        startFraction: after ? 0.1 : 0.9,
        targetFraction: after ? 0.95 : 0.05,
      );
      expect(ids(), after ? [b, folder.id, a] : [b, a, folder.id]);
      expect(Get.find<IdentityController>().byId(a)!.folderId, isNull);
    });
  }

  testWidgets('凭证和文件夹可移入文件夹，保留后代并可拖回根级', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<IdentityFolderController>();
    final source = await folders.create(name: '来源');
    final nested = await folders.create(name: '子层', parentId: source.id);
    final leaf = await addIdentity('叶子', folder: nested.id);
    final root = await addIdentity('根凭证');
    final target = await folders.create(name: '目标');
    await tester.pumpAndSettle();
    await drag(tester, '来源', '目标');
    expect(folders.byId(source.id)!.parentId, target.id);
    expect(folders.byId(nested.id)!.parentId, source.id);
    expect(Get.find<IdentityController>().byId(leaf)!.folderId, nested.id);
    await drag(tester, '根凭证', '目标');
    expect(ids(target.id), [source.id, root]);
    expect(folders.isExpanded(target.id), isTrue);
    folders.expanded.add(nested.id);
    await tester.pumpAndSettle();
    await drag(tester, '来源', '子层');
    expect(folders.byId(source.id)!.parentId, target.id);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('来源')),
    );
    await gesture.moveTo(tester.getCenter(find.text('凭证')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ids(), [target.id, source.id]);
    expect(ids(nested.id), [leaf]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('折叠后子项隐藏，主机文件夹不接受凭证，选择器仍列出嵌套凭证', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<IdentityFolderController>();
    final folder = await folders.create(name: '凭证目录');
    final identity = await addIdentity('隐藏凭证', folder: folder.id);
    await Get.find<FolderController>().create(name: '服务目录');
    folders.expanded.add(folder.id);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('隐藏凭证')),
    );
    await gesture.moveTo(tester.getCenter(find.text('服务目录')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(Get.find<IdentityController>().byId(identity)!.folderId, folder.id);
    await tester.tap(find.text('凭证目录'));
    await tester.pumpAndSettle();
    expect(find.text('隐藏凭证'), findsNothing);
    expect(find.byType(Draggable<IdentityTreeItem>), findsOneWidget);
    unawaited(showHostEditDialog(tester.element(find.text('服务'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已有凭证'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<String>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(shadcn.SelectPopup<String>),
        matching: find.text('凭证目录'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐藏凭证（root）'), findsOneWidget);
    await tester.tap(find.text('隐藏凭证（root）'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<shadcn.Select<String>>(find.byType(shadcn.Select<String>))
          .value,
      identity,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除凭证文件夹确认保留内容，编辑保留分组与密码', (tester) async {
    await pumpApp(tester);
    final folder = await Get.find<IdentityFolderController>().create(
      name: '目录',
    );
    final id = await addIdentity('凭证 A', folder: folder.id);
    Get.find<IdentityFolderController>().expanded.add(folder.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('凭证 A'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(AppTextFormField, '名称'), '凭证 B');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final controller = Get.find<IdentityController>();
    expect(controller.byId(id)!.folderId, folder.id);
    expect(await controller.passwordOf(controller.byId(id)!), 'test-secret');
    await tester.tap(find.text('目录'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('其中的子文件夹与凭证会移动到上一级，不会被删除。'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(Get.find<IdentityFolderController>().folders, isEmpty);
    expect(controller.byId(id)!.folderId, isNull);
    expect(await controller.passwordOf(controller.byId(id)!), 'test-secret');
    expect(find.text('凭证 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final viaGateway in [false, true]) {
    testWidgets(
      '${viaGateway ? '凭证管理' : '侧栏'}删除被${viaGateway ? '网关' : '服务'}引用的凭证时提示修改配置',
      (tester) async {
        await pumpApp(tester);
        final id = await addIdentity('共享凭证');
        final hosts = viaGateway
            ? Get.find<GatewayController>()
            : Get.find<HostController>();
        await hosts.save(
          Host(
            id: 'endpoint',
            name: '引用端点',
            hostname: 'endpoint.test',
            identityId: id,
          ),
        );
        await tester.pumpAndSettle();

        if (viaGateway) {
          unawaited(showIdentityManagerDialog(tester.element(find.text('凭证'))));
          await tester.pumpAndSettle();
          await tester.tap(findAppIconButton('删除凭证'));
        } else {
          await tester.tap(find.text('共享凭证'), buttons: kSecondaryButton);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('删除'));
        }
        await tester.pumpAndSettle();
        expect(find.text('将删除此凭证及其保存的密码或私钥。'), findsOneWidget);
        await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '删除'));
        await tester.pumpAndSettle();

        expect(find.text('凭证正在被网关或服务使用，请先修改对应的凭证配置'), findsOneWidget);
        final identities = Get.find<IdentityController>();
        final identity = identities.byId(id)!;
        expect(await identities.passwordOf(identity), 'test-secret');
        expect(hosts.hosts.single.identityId, id);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );
  }

  for (final depth in [0, 2]) {
    for (final isFolder in [false, true]) {
      testWidgets('目录层数 $depth，${isFolder ? '文件夹' : '凭证'}短名称预览保留宽度与位置', (
        tester,
      ) async {
        await pumpApp(tester);
        final folders = Get.find<IdentityFolderController>();
        String? parent;
        for (var i = 0; i < depth; i++) {
          parent = (await folders.create(name: '父级$i', parentId: parent)).id;
        }
        if (isFolder) {
          await folders.create(name: 'a', parentId: parent);
        } else {
          await addIdentity('a', folder: parent);
        }
        if (parent != null) folders.expanded.add(parent);
        await tester.pumpAndSettle();
        final row = _row('a');
        final draggable = tester.widget<Draggable<IdentityTreeItem>>(row);
        final iconData = isFolder
            ? shadcn.LucideIcons.folderKey
            : shadcn.LucideIcons.fileKey;
        final original = [
          tester.getRect(row),
          tester.getRect(find.descendant(of: row, matching: find.text('a'))),
          tester.getRect(
            find.descendant(of: row, matching: find.byIcon(iconData)),
          ),
        ];
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('a')),
          kind: ui.PointerDeviceKind.mouse,
        );
        const movement = Offset(80, 12);
        await gesture.moveBy(movement);
        await tester.pump();
        final preview = find.byWidget(draggable.feedback);
        final actual = [
          tester.getRect(preview),
          tester.getRect(
            find.descendant(of: preview, matching: find.text('a')),
          ),
          tester.getRect(
            find.descendant(of: preview, matching: find.byIcon(iconData)),
          ),
        ];
        for (var i = 0; i < original.length; i++) {
          expect(actual[i].size, original[i].size);
          expect(actual[i].topLeft, original[i].topLeft + movement);
        }
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
