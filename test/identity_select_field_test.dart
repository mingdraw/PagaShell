import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/application/identities/identity_tree_controller.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/entities/identity_tree_item.dart';
import 'package:pagashell/domain/repositories/identity_repository.dart';
import 'package:pagashell/presentation/identities/identity_select_field.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _Harness extends StatefulWidget {
  const _Harness({this.initialValue, super.key});
  final String? initialValue;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final form = GlobalKey<FormState>();
  late String? value = widget.initialValue;
  bool valid = false;
  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdentitySelectField(
              value: value,
              onChanged: (id) => setState(() => value = id),
            ),
            shadcn.PrimaryButton(
              onPressed: () =>
                  setState(() => valid = form.currentState!.validate()),
              child: const Text('验证'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => InMemoryBinding().dependencies());
  tearDown(Get.reset);

  Future<String> addIdentity(String name, {String? folder}) async =>
      (await Get.find<IdentityController>().saveWithPassword(
        name: name,
        username: 'root',
        password: 'test-only',
        folderId: folder,
      )).id;

  Future<GlobalKey<_HarnessState>> pumpField(
    WidgetTester tester, {
    String? selected,
  }) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      ShadcnTestApp(
        home: _Harness(key: key, initialValue: selected),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(shadcn.Select<String>));
    await tester.pumpAndSettle();
  }

  Finder popupText(String text) => find.descendant(
    of: find.byType(shadcn.SelectPopup<String>),
    matching: find.text(text),
  );

  testWidgets('混合顺序、可折叠层级与凭证选择，展开不改变侧栏状态', (tester) async {
    final folders = Get.find<IdentityFolderController>();
    final first = await addIdentity('Z');
    final folder = await folders.create(name: 'A 文件夹');
    final sub = await folders.create(name: '子文件夹', parentId: folder.id);
    final nested = await addIdentity('嵌套', folder: sub.id);
    final last = await addIdentity('A');
    folders.expanded.clear();
    final key = await pumpField(tester);
    await open(tester);
    expect(
      tester.getTopLeft(popupText('Z（root）')).dy,
      lessThan(tester.getTopLeft(popupText('A 文件夹')).dy),
    );
    expect(
      tester.getTopLeft(popupText('A 文件夹')).dy,
      lessThan(tester.getTopLeft(popupText('A（root）')).dy),
    );
    expect(popupText('子文件夹'), findsNothing);
    await tester.tap(popupText('A 文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(shadcn.SelectPopup<String>), findsOneWidget);
    expect(key.currentState!.value, isNull);
    await tester.tap(popupText('子文件夹'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(popupText('嵌套（root）')).dx,
      greaterThan(tester.getTopLeft(popupText('子文件夹')).dx),
    );
    await tester.tap(popupText('嵌套（root）'));
    await tester.pumpAndSettle();
    expect(key.currentState!.value, nested);
    expect(find.byType(shadcn.SelectPopup<String>), findsNothing);
    expect(folders.expanded, isEmpty);
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(key.currentState!.valid, isTrue);
    expect(
      Get.find<IdentityTreeController>()
          .childrenOf(null)
          .map((node) => node.item.id),
      [first, folder.id, last],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新打开自动展开所选路径，选中行有勾，折叠保留选择', (tester) async {
    final folders = Get.find<IdentityFolderController>();
    final parent = await folders.create(name: '父级');
    final sub = await folders.create(name: '子级', parentId: parent.id);
    final selected = await addIdentity('已选', folder: sub.id);
    folders.expanded.clear();
    final key = await pumpField(tester, selected: selected);
    await open(tester);
    final option = find.byKey(ValueKey('identity-option-$selected'));
    expect(option, findsOneWidget);
    expect(
      find.descendant(
        of: option,
        matching: find.byIcon(shadcn.LucideIcons.check),
      ),
      findsOneWidget,
    );
    await tester.tap(popupText('父级'));
    await tester.pumpAndSettle();
    expect(option, findsNothing);
    expect(key.currentState!.value, selected);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await open(tester);
    expect(option, findsOneWidget);
    expect(folders.expanded, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('树实时反映维护的顺序、归属和重命名', (tester) async {
    final folders = Get.find<IdentityFolderController>();
    final f = await folders.create(name: '目录');
    final a = await addIdentity('a');
    final b = await addIdentity('b');
    await pumpField(tester);
    await open(tester);
    final tree = Get.find<IdentityTreeController>();
    await tree.move(
      IdentityTreeItem.identity(b),
      IdentityTreePlacement(
        parentId: null,
        anchor: IdentityTreeItem.folder(f.id),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(popupText('b（root）')).dy,
      lessThan(tester.getTopLeft(popupText('目录')).dy),
    );
    await tree.move(
      IdentityTreeItem.identity(a),
      IdentityTreePlacement(parentId: f.id),
    );
    await tester.pumpAndSettle();
    expect(popupText('a（root）'), findsNothing);
    await tester.tap(popupText('目录'));
    await tester.pumpAndSettle();
    await Get.find<IdentityController>().updateIdentity(
      id: a,
      name: 'renamed',
      username: 'user',
    );
    await tester.pumpAndSettle();
    expect(popupText('renamed（user）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹不可选，未支持的认证类型不可选，已选凭证被删除后必选校验生效', (tester) async {
    await Get.find<IdentityFolderController>().create(name: '空文件夹');
    await Get.find<IdentityRepository>().upsert(
      const Identity(
        id: 'agent',
        name: 'Agent',
        username: 'root',
        authType: AuthType.agent,
      ),
    );
    final selected = await addIdentity('已选');
    final key = await pumpField(tester, selected: selected);
    await Get.find<IdentityController>().remove(selected);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<shadcn.Select<String>>(find.byType(shadcn.Select<String>))
          .value,
      isNull,
    );
    await open(tester);
    expect(find.byType(shadcn.SelectItemButton<String>), findsNothing);
    await tester.tap(popupText('空文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(shadcn.SelectPopup<String>), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(key.currentState!.valid, isFalse);
    expect(find.text('请选择凭证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹可用 Enter 展开，凭证可用 Enter 选择', (tester) async {
    final folder = await Get.find<IdentityFolderController>().create(
      name: '目录',
    );
    final id = await addIdentity('凭证项', folder: folder.id);
    final key = await pumpField(tester);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(popupText('凭证项（root）'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(key.currentState!.value, id);
    expect(find.byType(shadcn.SelectPopup<String>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长树弹层宽度跟随字段，高度受限并可滚动到末尾', (tester) async {
    for (var index = 0; index < 32; index++) {
      await addIdentity('凭证$index');
    }
    final key = await pumpField(tester);
    await open(tester);
    final selectRect = tester.getRect(find.byType(shadcn.Select<String>));
    final popupRect = tester.getRect(find.byType(shadcn.SelectPopup<String>));
    expect(popupRect.width, selectRect.width);
    expect(popupRect.height, lessThan(tester.view.physicalSize.height));
    await tester.scrollUntilVisible(
      popupText('凭证31（root）'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(shadcn.SelectPopup<String>),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(popupText('凭证31（root）'));
    await tester.pumpAndSettle();
    expect(
      Get.find<IdentityController>().byId(key.currentState!.value)!.name,
      '凭证31',
    );
    expect(tester.takeException(), isNull);
  });
}
