import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/hosts/host_tree_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

Finder _row(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byType(Draggable<HostTreeItem>),
);

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDir.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(_captureDir).create(recursive: true);
      await File('$_captureDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final cjk = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (cjk.existsSync()) {
      await (FontLoader(
        'PingFang SC',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  tearDown(Get.reset);

  Future<GlobalKey> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PagaShellApp(
          binding: InMemoryBinding(),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pump();
    return key;
  }

  Future<void> addHost(String name, {String? folder}) =>
      Get.find<HostController>().save(
        Host(
          id: name,
          name: name,
          hostname: '$name.example.test',
          folderId: folder,
        ),
      );

  Future<void> drag(
    WidgetTester tester,
    String from,
    String to, {
    double startFraction = 0.5,
    double targetFraction = 0.5,
  }) async {
    final source = tester.getRect(_row(from));
    final target = tester.getRect(_row(to));
    final x = tester.getCenter(find.text(from)).dx;
    final gesture = await tester.startGesture(
      Offset(x, source.top + source.height * startFraction),
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

  List<String> rootIds() => Get.find<HostTreeController>()
      .childrenOf(null)
      .map((node) => node.item.id)
      .toList();

  testWidgets('文件夹与服务按混合创建顺序展示，新增项位于最后', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<FolderController>();
    await addHost('z-host');
    await folders.create(name: 'a-folder');
    await addHost('a-host');
    await folders.create(name: 'z-folder');
    await tester.pumpAndSettle();
    final positions = [
      'z-host',
      'a-folder',
      'a-host',
      'z-folder',
    ].map((name) => tester.getTopLeft(find.text(name)).dy).toList();
    expect(positions, orderedEquals([...positions]..sort()));
    expect(positions.toSet(), hasLength(4));
  });

  for (final startFraction in [0.15, 0.85]) {
    for (final after in [false, true]) {
      testWidgets('抓取行高度 $startFraction，拖到文件夹${after ? '下' : '上'}边缘按指针位置排序', (
        tester,
      ) async {
        await pumpApp(tester);
        await addHost('a');
        await addHost('b');
        final folder = await Get.find<FolderController>().create(name: '目录');
        await tester.pumpAndSettle();
        await drag(
          tester,
          'a',
          '目录',
          startFraction: startFraction,
          targetFraction: after ? 0.95 : 0.05,
        );
        expect(
          rootIds(),
          after ? ['b', folder.id, 'a'] : ['b', 'a', folder.id],
        );
        expect(
          Get.find<HostController>().hosts
              .firstWhere((host) => host.id == 'a')
              .folderId,
          isNull,
        );
      });
    }
  }

  testWidgets('文件夹可以拖到主机之后，也可以再拖回前面', (tester) async {
    await pumpApp(tester);
    final folder = await Get.find<FolderController>().create(name: '目录');
    await addHost('h1');
    await addHost('h2');
    await tester.pumpAndSettle();
    await drag(tester, '目录', 'h2', targetFraction: 0.95);
    expect(rootIds(), ['h1', 'h2', folder.id]);
    await drag(tester, '目录', 'h1', targetFraction: 0.05);
    expect(rootIds(), [folder.id, 'h1', 'h2']);
  });

  testWidgets('文件夹拖入另一个文件夹保留子树，拖到组头后回到根级末尾', (tester) async {
    final key = await pumpApp(tester);
    final folders = Get.find<FolderController>();
    final source = await folders.create(name: '生产');
    final child = await folders.create(name: '数据库', parentId: source.id);
    await addHost('db', folder: child.id);
    final destination = await folders.create(name: '归档');
    await addHost('app', folder: destination.id);
    await tester.pumpAndSettle();
    await drag(tester, '生产', '归档');
    expect(folders.byId(source.id)?.parentId, destination.id);
    expect(folders.byId(child.id)?.parentId, source.id);
    expect(folders.isExpanded(destination.id), isTrue);
    expect(
      Get.find<HostTreeController>()
          .childrenOf(destination.id)
          .map((node) => node.item.id),
      ['app', source.id],
    );
    folders.expanded.add(child.id);
    await tester.pumpAndSettle();
    expect(find.text('db'), findsOneWidget);
    await _capture(tester, key, 'host-tree-nested');

    final group = tester.getCenter(find.text('服务'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('生产')),
    );
    await gesture.moveTo(group);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(folders.byId(source.id)?.parentId, isNull);
    expect(rootIds(), [destination.id, source.id]);
    expect(folders.byId(child.id)?.parentId, source.id);
    expect(
      Get.find<HostController>().hosts
          .firstWhere((host) => host.id == 'db')
          .folderId,
      child.id,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('拒绝把文件夹放入自身或子文件夹', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<FolderController>();
    final parent = await folders.create(name: '父目录');
    final child = await folders.create(name: '子目录', parentId: parent.id);
    await addHost('root-host');
    await tester.pumpAndSettle();
    await drag(tester, '父目录', '子目录');
    expect(folders.byId(parent.id)?.parentId, isNull);
    expect(folders.byId(child.id)?.parentId, parent.id);
    final origin = tester.getCenter(find.text('父目录'));
    final gesture = await tester.startGesture(origin);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.moveTo(origin);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(folders.byId(parent.id)?.parentId, isNull);
    expect(rootIds(), [parent.id, 'root-host']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹中部因重名无效时，继续移到同一行边缘仍可排序', (tester) async {
    final key = await pumpApp(tester);
    await addHost('db');
    final folders = Get.find<FolderController>();
    final target = await folders.create(name: '目录');
    await Get.find<HostController>().save(
      Host(
        id: 'nested-db',
        name: 'db',
        hostname: 'nested.example.test',
        folderId: target.id,
      ),
    );
    await addHost('last');
    await tester.pumpAndSettle();
    final rect = tester.getRect(_row('目录'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('db')),
    );
    await gesture.moveTo(Offset(rect.left + 90, rect.center.dy));
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + 90, rect.bottom - 2));
    await tester.pump();
    await _capture(tester, key, 'host-tree-reorder-guide');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rootIds(), [target.id, 'db', 'last']);
    expect(
      Get.find<HostController>().hosts
          .firstWhere((host) => host.id == 'db')
          .folderId,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务可以直接插入另一文件夹内现有主机的前面', (tester) async {
    await pumpApp(tester);
    final folder = await Get.find<FolderController>().create(name: '目录');
    await addHost('first', folder: folder.id);
    await addHost('last', folder: folder.id);
    Get.find<FolderController>().expanded.add(folder.id);
    await addHost('root');
    await tester.pumpAndSettle();
    await drag(tester, 'root', 'first', targetFraction: 0.05);
    expect(
      Get.find<HostTreeController>()
          .childrenOf(folder.id)
          .map((node) => node.item.id),
      ['root', 'first', 'last'],
    );
    expect(rootIds(), [folder.id]);
  });

  testWidgets('文件夹点击展开折叠，收起的子项没有拖放目标', (tester) async {
    final key = await pumpApp(tester);
    final folders = Get.find<FolderController>();
    final folder = await folders.create(name: '生产环境');
    await addHost('web-01', folder: folder.id);
    folders.expanded.add(folder.id);
    await tester.pumpAndSettle();
    await _capture(tester, key, 'custom-host-tree');
    await tester.tap(find.text('生产环境'));
    await tester.pumpAndSettle();
    expect(find.text('web-01'), findsNothing);
    expect(find.byType(Draggable<HostTreeItem>), findsOneWidget);
    await tester.tap(find.text('生产环境'));
    await tester.pumpAndSettle();
    expect(find.text('web-01'), findsOneWidget);
    await tester.tap(find.text('生产环境'));
    await tester.pumpAndSettle();
    expect(find.text('web-01'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长主机列表支持滚轮滚动，末尾根组仍可操作', (tester) async {
    await pumpApp(tester);
    final folders = Get.find<FolderController>();
    for (var index = 0; index < 24; index++) {
      await folders.create(name: '目录 $index');
    }
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.text('目录 0')),
        scrollDelta: const Offset(0, 1000),
      ),
    );
    await tester.pumpAndSettle();
    final credentials = tester.getRect(find.text('凭证'));
    expect(credentials.top, greaterThan(44));
    expect(credentials.bottom, lessThan(750));
    expect(tester.takeException(), isNull);
  });

  for (final depth in [0, 2]) {
    testWidgets('目录层数 $depth：文件夹拖拽预览保留原行宽度、缩进和文字位置', (tester) async {
      await pumpApp(tester);
      final folders = Get.find<FolderController>();
      String? parentId;
      for (var index = 0; index < depth; index++) {
        parentId = (await folders.create(
          name: '父级 $index',
          parentId: parentId,
        )).id;
      }
      final source = await folders.create(name: 'a', parentId: parentId);
      await tester.pumpAndSettle();
      final row = _row('a');
      final draggable = tester.widget<Draggable<HostTreeItem>>(row);
      final text = find.descendant(of: row, matching: find.text('a'));
      final icon = find.descendant(
        of: row,
        matching: find.byIcon(shadcn.LucideIcons.folder),
      );
      final originals = [
        tester.getRect(row),
        tester.getRect(text),
        tester.getRect(icon),
      ];
      final gesture = await tester.startGesture(
        tester.getCenter(text),
        kind: ui.PointerDeviceKind.mouse,
      );
      const movement = Offset(80, 12);
      await gesture.moveBy(movement);
      await tester.pump();
      final preview = find.byWidget(draggable.feedback);
      final previews = [
        tester.getRect(preview),
        tester.getRect(find.descendant(of: preview, matching: find.text('a'))),
        tester.getRect(
          find.descendant(
            of: preview,
            matching: find.byIcon(shadcn.LucideIcons.folder),
          ),
        ),
      ];
      for (var index = 0; index < originals.length; index++) {
        expect(previews[index].size, originals[index].size);
        expect(previews[index].topLeft, originals[index].topLeft + movement);
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(folders.byId(source.id)?.parentId, parentId);
      expect(tester.takeException(), isNull);
    });
  }
}
