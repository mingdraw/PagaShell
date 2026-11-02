import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/folders/tree_folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/domain/entities/identity_tree_item.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/presentation/components/app_tree_expansion.dart';

import 'support/in_memory_binding.dart';

Finder _row(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Draggable<HostTreeItem> ||
        widget is Draggable<IdentityTreeItem>,
  ),
);

void main() {
  tearDown(Get.reset);

  for (final section in SidebarSection.values) {
    testWidgets('${section.name} 文件夹高度和箭头平滑过渡，收起子项不可交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
      final TreeFolderController folders = switch (section) {
        SidebarSection.services => Get.find<FolderController>(),
        SidebarSection.identities => Get.find<IdentityFolderController>(),
        SidebarSection.gateways => Get.find<GatewayFolderController>(),
      };
      final folder = await folders.create(name: '父目录');
      await folders.create(name: '子目录', parentId: folder.id);
      await folders.create(name: '后续目录');
      await tester.pumpAndSettle();
      final parent = _row('父目录');
      final child = _row('子目录');
      final following = _row('后续目录');
      final arrow = find.descendant(
        of: parent,
        matching: find.byType(RotationTransition),
      );
      final rowSize = tester.getSize(parent);
      expect(tester.getSize(child).width, rowSize.width);
      final expandedY = tester.getTopLeft(following).dy;

      await tester.tap(find.text('父目录'));
      await tester.pump();
      expect(child, findsOneWidget);
      expect(child.hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 70));
      final collapsingY = tester.getTopLeft(following).dy;
      final collapsingAngle = tester
          .widget<RotationTransition>(arrow)
          .turns
          .value;
      expect(collapsingAngle, greaterThan(0));
      expect(collapsingAngle, lessThan(0.25));
      expect(tester.getSize(parent), rowSize);
      await tester.pumpAndSettle();
      final collapsedY = tester.getTopLeft(following).dy;
      expect(collapsingY, greaterThan(collapsedY));
      expect(collapsingY, lessThan(expandedY));
      expect(child, findsNothing);

      await tester.tap(find.text('父目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final expandingY = tester.getTopLeft(following).dy;
      expect(expandingY, greaterThan(collapsedY));
      expect(expandingY, lessThan(expandedY));
      await tester.pumpAndSettle();
      expect(child.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(following).dy, closeTo(expandedY, 0.01));
      expect(tester.getSize(parent), rowSize);

      // 动画未结束时反向切换，最终状态仍与持久化的展开集合一致。
      await tester.tap(find.text('父目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tap(find.text('父目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tap(find.text('父目录'));
      await tester.pumpAndSettle();
      expect(folders.isExpanded(folder.id), isFalse);
      expect(child, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('系统关闭动画时文件夹立即收起并移除内容', (tester) async {
    Widget build(bool expanded) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            AppTreeExpansion(
              key: const ValueKey('expansion'),
              expanded: expanded,
              children: expanded
                  ? const [SizedBox(height: 80, child: Text('子项'))]
                  : const [],
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(build(true));
    expect(find.text('子项'), findsOneWidget);
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(find.text('子项'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('expansion'))).height, 0);
    expect(tester.takeException(), isNull);
  });
}
