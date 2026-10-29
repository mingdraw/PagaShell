import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pump();
  }

  Future<void> dragTo(WidgetTester tester, Finder from, Finder to) async {
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final (folderDepth, search) in [
    (0, false),
    (1, false),
    (2, false),
    (2, true),
  ]) {
    testWidgets('目录层数 $folderDepth 搜索 $search：短名称拖拽沿用原行尺寸和位置', (tester) async {
      await pumpApp(tester);
      final folders = Get.find<FolderController>();
      final hosts = Get.find<HostController>();
      String? folderId;
      for (var depth = 0; depth < folderDepth; depth++) {
        final folder = await folders.create(
          name: '目录 $depth',
          parentId: folderId,
        );
        folderId = folder.id;
        folders.expanded.add(folder.id);
      }
      await hosts.save(
        Host(
          id: 'short',
          name: 'a',
          hostname: 'example.test',
          folderId: folderId,
        ),
      );
      if (search) hosts.searchQuery.value = 'a';
      await tester.pumpAndSettle();
      final source = find.ancestor(
        of: find.text('a'),
        matching: find.byType(Draggable<HostTreeItem>),
      );
      final draggable = tester.widget<Draggable<HostTreeItem>>(source);
      final sourceText = find.descendant(of: source, matching: find.text('a'));
      final sourceIcon = find.descendant(
        of: source,
        matching: find.byIcon(shadcn.LucideIcons.fileTerminal),
      );
      final sourceRect = tester.getRect(source);
      final textRect = tester.getRect(sourceText);
      final iconRect = tester.getRect(sourceIcon);
      final gesture = await tester.startGesture(
        textRect.center,
        kind: PointerDeviceKind.mouse,
      );
      const movement = Offset(75, 17);
      await gesture.moveBy(movement);
      await tester.pump();
      final feedback = find.byWidget(draggable.feedback);
      final feedbackText = find.descendant(
        of: feedback,
        matching: find.text('a'),
      );
      final feedbackIcon = find.descendant(
        of: feedback,
        matching: find.byIcon(shadcn.LucideIcons.fileTerminal),
      );
      for (final (original, preview) in [
        (sourceRect, tester.getRect(feedback)),
        (textRect, tester.getRect(feedbackText)),
        (iconRect, tester.getRect(feedbackIcon)),
      ]) {
        expect(preview.width, closeTo(original.width, 0.01));
        expect(preview.height, closeTo(original.height, 0.01));
        expect(preview.left, closeTo(original.left + movement.dx, 0.01));
        expect(preview.top, closeTo(original.top + movement.dy, 0.01));
      }
      expect(tester.takeException(), isNull);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(hosts.hosts.single.folderId, folderId);
    });
  }

  testWidgets('拖拽主机到文件夹完成归档并自动展开', (tester) async {
    await pumpApp(tester);
    final folderController = Get.find<FolderController>();
    final hostController = Get.find<HostController>();
    final folder = await folderController.create(name: '生产环境');
    await hostController.save(
      const Host(id: 'h1', name: 'db-01', hostname: '10.0.0.8'),
    );
    await tester.pumpAndSettle();

    await dragTo(tester, find.text('db-01'), find.text('生产环境'));

    expect(hostController.hosts.single.folderId, folder.id);
    expect(folderController.isExpanded(folder.id), isTrue);
    // 主机仍显示在树里（此时位于展开的文件夹下）。
    expect(find.text('db-01'), findsOneWidget);
  });

  testWidgets('目标文件夹内已有同名服务时拒绝拖入', (tester) async {
    await pumpApp(tester);
    final folderController = Get.find<FolderController>();
    final hostController = Get.find<HostController>();
    final folder = await folderController.create(name: '生产环境');
    await hostController.save(
      Host(id: 'h1', name: 'db-01', hostname: '10.0.0.8', folderId: folder.id),
    );
    await hostController.save(
      const Host(id: 'h2', name: 'db-01', hostname: '10.0.0.9'),
    );
    await tester.pumpAndSettle();

    // 文件夹折叠时只有根级的 db-01 可见。
    await dragTo(tester, find.text('db-01'), find.text('生产环境'));

    final rootHost = hostController.hosts.firstWhere((h) => h.id == 'h2');
    expect(rootHost.folderId, isNull);
  });

  testWidgets('拖拽到「主机」组头移回根级', (tester) async {
    await pumpApp(tester);
    final folderController = Get.find<FolderController>();
    final hostController = Get.find<HostController>();
    final folder = await folderController.create(name: '生产环境');
    await hostController.save(
      Host(id: 'h1', name: 'db-01', hostname: '10.0.0.8', folderId: folder.id),
    );
    folderController.expanded.add(folder.id);
    await tester.pumpAndSettle();

    await dragTo(tester, find.text('db-01'), find.text('服务'));

    expect(hostController.hosts.single.folderId, isNull);
  });
}
