import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/presentation/settings/quick_commands_settings_section.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  testWidgets('Tree 组件支持按分组展开折叠、全部折叠/展开、拖拽排序及拖入折叠分组', (tester) async {
    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsController(
      repository: InMemorySettingsRepository(),
    );
    Get.put<SettingsController>(settings);
    await settings.ready;

    final groupA = await settings.addQuickCommandGroup('分组 A');
    final groupB = await settings.addQuickCommandGroup('分组 B');
    final groupEmpty = await settings.addQuickCommandGroup('空分组 C');
    final cmd1 = await settings.addQuickCommand(
      groupA.id,
      command: 'echo first',
      summary: '第一条',
    );
    final cmd2 = await settings.addQuickCommand(
      groupA.id,
      command: 'echo second',
      summary: '第二条',
    );
    final cmd3 = await settings.addQuickCommand(
      groupB.id,
      command: 'echo third',
      summary: '第三条',
    );

    await tester.pumpWidget(
      const ShadcnTestApp(
        home: shadcn.Scaffold(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: QuickCommandsSettingsSection(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-quick-commands-tree')),
      findsOneWidget,
    );

    final groupATreeItem = find.byKey(
      ValueKey('settings-quick-group-${groupA.id}'),
    );
    final groupEmptyTreeItem = find.byKey(
      ValueKey('settings-quick-group-${groupEmpty.id}'),
    );
    final cmd1TreeItem = find.byKey(ValueKey('settings-quick-cmd-${cmd1.id}'));

    // 1) 验证指令行拖拽手柄、编辑/删除按钮与指令条同一行垂直居中对齐（不随下方备注下移）。
    final cmd1ChipRect = tester.getRect(
      find.byKey(ValueKey('settings-quick-cmd-chip-${cmd1.id}')),
    );
    final cmd1DragRect = tester.getRect(
      find.byKey(ValueKey('settings-quick-cmd-drag-${cmd1.id}')),
    );
    final cmd1EditRect = tester.getRect(
      find.byKey(ValueKey('settings-quick-cmd-edit-${cmd1.id}')),
    );
    final cmd1DeleteRect = tester.getRect(
      find.byKey(ValueKey('settings-quick-cmd-delete-${cmd1.id}')),
    );
    expect(cmd1DragRect.center.dy, closeTo(cmd1ChipRect.center.dy, 1.5));
    expect(cmd1EditRect.center.dy, closeTo(cmd1ChipRect.center.dy, 1.5));
    expect(cmd1DeleteRect.center.dy, closeTo(cmd1ChipRect.center.dy, 1.5));

    // 2) 点击分组折叠与展开，且 TreeItem 的 FocusOutline 颜色透明、不向内部透传焦点外框。
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));
    final treeItemFocusContext = tester.element(
      find.descendant(
        of: groupATreeItem,
        matching: find.byType(shadcn.TreeItem),
      ),
    );
    expect(
      shadcn.Theme.of(treeItemFocusContext).colorScheme.ring,
      shadcn.Colors.transparent,
    );
    await tester.tap(
      find.descendant(of: groupATreeItem, matching: find.text('分组 A')),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(cmd1TreeItem).height, 0);
    for (final outline in tester.widgetList<shadcn.FocusOutline>(
      find.descendant(
        of: groupATreeItem,
        matching: find.byType(shadcn.FocusOutline),
      ),
    )) {
      expect(outline.focused, isFalse);
    }

    await tester.tap(
      find.descendant(of: groupATreeItem, matching: find.text('分组 A')),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));
    for (final outline in tester.widgetList<shadcn.FocusOutline>(
      find.descendant(
        of: groupATreeItem,
        matching: find.byType(shadcn.FocusOutline),
      ),
    )) {
      expect(outline.focused, isFalse);
    }

    // 2) 全部折叠 / 全部展开按钮。
    final toggleAll = find.byKey(
      const ValueKey('settings-quick-commands-toggle-all'),
    );
    await tester.tap(toggleAll);
    await tester.pumpAndSettle();
    expect(find.text('全部展开'), findsOneWidget);
    expect(tester.getSize(cmd1TreeItem).height, 0);

    await tester.tap(toggleAll);
    await tester.pumpAndSettle();
    expect(find.text('全部折叠'), findsOneWidget);
    expect(tester.getSize(cmd1TreeItem).height, greaterThan(0));

    Future<void> dragBetween(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // 3) 组内拖拽排序指令：cmd1 拖到 cmd2 下半区。
    final cmd1Handle = find.byKey(
      ValueKey('settings-quick-cmd-drag-${cmd1.id}'),
    );
    final cmd2Slot = find.byKey(ValueKey('settings-quick-cmd-slot-${cmd2.id}'));
    final cmd2Rect = tester.getRect(cmd2Slot);
    await dragBetween(
      tester.getCenter(cmd1Handle),
      Offset(cmd2Rect.center.dx, cmd2Rect.bottom - 4),
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupA.id)
          .commands
          .map((c) => c.id)
          .toList(),
      [cmd2.id, cmd1.id],
    );

    // 4) 先折叠空分组 C，再把 groupB 的 cmd3 直接拖到折叠后的分组 C 上，应自动移入并展开。
    await tester.tap(
      find.descendant(of: groupEmptyTreeItem, matching: find.text('空分组 C')),
    );
    await tester.pumpAndSettle();
    final cmd3Handle = find.byKey(
      ValueKey('settings-quick-cmd-drag-${cmd3.id}'),
    );
    await dragBetween(
      tester.getCenter(cmd3Handle),
      tester.getCenter(groupEmptyTreeItem),
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupB.id)
          .commands,
      isEmpty,
    );
    expect(
      settings.customQuickCommandGroups
          .firstWhere((g) => g.id == groupEmpty.id)
          .commands
          .map((c) => c.id)
          .toList(),
      [cmd3.id],
    );
    expect(
      tester
          .getSize(find.byKey(ValueKey('settings-quick-cmd-${cmd3.id}')))
          .height,
      greaterThan(0),
    );

    // 5) 拖拽排序分组：将分组 C 拖到分组 A 上半区置顶。
    final emptyHandle = find.byKey(
      ValueKey('settings-quick-group-drag-${groupEmpty.id}'),
    );
    final groupASlot = find.byKey(
      ValueKey('settings-quick-group-slot-${groupA.id}'),
    );
    final groupARect = tester.getRect(groupASlot);
    await dragBetween(
      tester.getCenter(emptyHandle),
      Offset(groupARect.center.dx, groupARect.top + 6),
    );
    expect(settings.customQuickCommandGroups.map((g) => g.id).toList(), [
      groupEmpty.id,
      groupA.id,
      groupB.id,
    ]);
    expect(tester.takeException(), isNull);
  });
}
