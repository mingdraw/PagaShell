import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/components/app_list_row.dart';
import 'package:pagashell/presentation/sftp/file_browser_pane.dart';

import 'support/shadcn_test_app.dart';

List<FileBrowserEntry> _entries(FileBrowserSide side, [int count = 4]) => [
  for (var index = 0; index < count; index++)
    FileBrowserEntry(
      path: '/${side.name}/${index == 0 ? 'folder' : '$index.txt'}',
      name: index == 0 ? 'folder' : '$index.txt',
      isDir: index == 0,
      size: 100,
    ),
];

class _Fixture {
  _Fixture({int count = 4})
    : local = _entries(FileBrowserSide.local, count),
      remote = _entries(FileBrowserSide.remote, count);

  final List<FileBrowserEntry> local;
  final List<FileBrowserEntry> remote;
  final rebuild = ValueNotifier(0);
  final transfers = <(FileBrowserSide, List<FileBrowserEntry>)>[];
  final drops = <(FileTransferDrag, String)>[];
  bool active = true;
  bool loading = false;
  String? directory;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: ValueListenableBuilder<int>(
          valueListenable: rebuild,
          builder: (context, value, _) => Row(
            children: [
              for (final side in FileBrowserSide.values)
                Expanded(
                  child: FileBrowserPane(
                    key: ValueKey(side),
                    sessionId: 's',
                    side: side,
                    cwd: directory ?? '/${side.name}',
                    entries: side == FileBrowserSide.local ? local : remote,
                    active: active,
                    loading: loading,
                    error: null,
                    onNavigate: (_) {},
                    onRefresh: () {},
                    onOpen: (_) {},
                    onTransfer: (entries) => transfers.add((side, entries)),
                    onDrop: (data, directory) => drops.add((data, directory)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder _pane(FileBrowserSide side) =>
    find.byKey(ValueKey('sftp-${side.name}-pane'));
Finder _list(FileBrowserSide side) =>
    find.byKey(ValueKey('sftp-${side.name}-file-list'));
Finder _box(FileBrowserSide side) =>
    find.byKey(ValueKey('sftp-${side.name}-selection-box'));
Finder _row(FileBrowserSide side, String name) =>
    find.byKey(ValueKey('sftp-${side.name}-row-/${side.name}/$name'));

Set<String> _selected(WidgetTester tester, FileBrowserSide side) => tester
    .widgetList<AppSurfaceAction>(
      find.descendant(of: _pane(side), matching: find.byType(AppSurfaceAction)),
    )
    .where((row) => row.selected)
    .map((row) => (row.key! as ValueKey<String>).value.split('-row-').last)
    .toSet();

ScrollPosition _scroll(WidgetTester tester, FileBrowserSide side) => tester
    .state<ScrollableState>(
      find.descendant(of: _list(side), matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  tearDown(Get.reset);

  for (final side in FileBrowserSide.values) {
    testWidgets('${side.name} 空白处反向画框实时选择文件和目录，收小选框更新高亮且不发起传输', (tester) async {
      final fixture = _Fixture();
      await fixture.open(tester);
      final bounds = tester.getRect(_list(side));
      final mouse = await tester.startGesture(
        bounds.topLeft + const Offset(200, 160),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(bounds.topLeft + const Offset(30, 4));
      await tester.pump();
      expect(_selected(tester, side), {
        '/${side.name}/folder',
        '/${side.name}/1.txt',
        '/${side.name}/2.txt',
        '/${side.name}/3.txt',
      });
      expect(_box(side), findsOneWidget);
      await mouse.moveTo(bounds.topLeft + const Offset(60, 70));
      await tester.pump();
      expect(_selected(tester, side), {
        '/${side.name}/2.txt',
        '/${side.name}/3.txt',
      });
      await mouse.up();
      await tester.pump();
      expect(_box(side), findsNothing);
      expect(_selected(tester, side), {
        '/${side.name}/2.txt',
        '/${side.name}/3.txt',
      });
      expect(fixture.transfers, isEmpty);
      expect(fixture.drops, isEmpty);
      final other = side == FileBrowserSide.local
          ? FileBrowserSide.remote
          : FileBrowserSide.local;
      expect(_selected(tester, other), isEmpty);
      await tester.tap(
        findAppIconButton(side == FileBrowserSide.local ? '上传所选文件' : '下载所选文件'),
      );
      await tester.pump();
      expect(fixture.transfers.single.$1, side);
      expect(fixture.transfers.single.$2.map((entry) => entry.name), [
        '2.txt',
        '3.txt',
      ]);
    });

    testWidgets('${side.name} 左侧空白边缘可正向框选，框选整组之后仍可拖到另一侧传输', (tester) async {
      final fixture = _Fixture();
      await fixture.open(tester);
      final bounds = tester.getRect(_list(side));
      final mouse = await tester.startGesture(
        bounds.topLeft + const Offset(3, 4),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(bounds.topLeft + const Offset(100, 64));
      await tester.pump();
      expect(_selected(tester, side), {
        '/${side.name}/folder',
        '/${side.name}/1.txt',
      });
      await mouse.up();
      await tester.pump();
      final other = side == FileBrowserSide.local
          ? FileBrowserSide.remote
          : FileBrowserSide.local;
      final drag = await tester.startGesture(
        tester.getCenter(_row(side, 'folder')),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
      await drag.moveTo(
        tester.getBottomRight(_list(other)) - const Offset(60, 60),
      );
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(fixture.drops, hasLength(1));
      expect(fixture.drops.single.$1.files.map((entry) => entry.name), [
        'folder',
        '1.txt',
      ]);
      expect(fixture.drops.single.$1.files.first.isDir, isTrue);
      expect(_box(side), findsNothing);
    });
  }

  for (final modifier in [
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.shiftLeft,
  ]) {
    testWidgets('${modifier.keyLabel} 框选在原选择上切换或扩展，再次移动不会重复切换', (tester) async {
      const side = FileBrowserSide.local;
      final fixture = _Fixture();
      await fixture.open(tester);
      await tester.tap(_row(side, '1.txt'));
      await tester.pump();
      await tester.sendKeyDownEvent(modifier);
      final bounds = tester.getRect(_list(side));
      final mouse = await tester.startGesture(
        bounds.topLeft + const Offset(3, 36),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(bounds.topLeft + const Offset(100, 100));
      await tester.pump();
      final expected = modifier == LogicalKeyboardKey.shiftLeft
          ? {'/local/1.txt', '/local/2.txt'}
          : {'/local/2.txt'};
      expect(_selected(tester, side), expected);
      await mouse.moveTo(bounds.topLeft + const Offset(110, 99));
      await tester.pump();
      expect(_selected(tester, side), expected);
      await mouse.up();
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      await tester.tapAt(
        bounds.bottomRight - const Offset(30, 30),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(_selected(tester, side), isEmpty);
    });
  }

  for (final upward in [true, false]) {
    testWidgets('长列表框选到${upward ? '上' : '下'}边缘自动滚动，松开后停止', (tester) async {
      const side = FileBrowserSide.local;
      final fixture = _Fixture(count: 80);
      await fixture.open(tester);
      final position = _scroll(tester, side);
      if (upward) {
        position.jumpTo(500);
        await tester.pump();
      }
      final bounds = tester.getRect(_list(side));
      final mouse = await tester.startGesture(
        bounds.centerLeft + const Offset(3, 0),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(
        Offset(bounds.left + 100, upward ? bounds.top + 1 : bounds.bottom - 1),
      );
      await tester.pump();
      final before = position.pixels;
      final selectedBefore = _selected(tester, side);
      await tester.pump(const Duration(milliseconds: 240));
      expect(position.pixels, upward ? lessThan(before) : greaterThan(before));
      expect(_selected(tester, side), isNot(selectedBefore));
      await mouse.up();
      await tester.pump();
      final stopped = position.pixels;
      final selection = _selected(tester, side);
      await tester.pump(const Duration(milliseconds: 300));
      expect(position.pixels, stopped);
      expect(_selected(tester, side), selection);
      expect(_box(side), findsNothing);
    });
  }

  for (final stop in ['取消指针', 'Escape', '切换标签', '刷新', '切换目录', '关闭面板']) {
    testWidgets('框选与自动滚动在$stop后结束', (tester) async {
      const side = FileBrowserSide.local;
      final fixture = _Fixture(count: 80);
      await fixture.open(tester);
      if (stop == '取消指针') {
        await tester.tap(_row(side, '1.txt'));
        await tester.pump();
      }
      final position = _scroll(tester, side);
      final bounds = tester.getRect(_list(side));
      final mouse = await tester.startGesture(
        bounds.topLeft + const Offset(3, 100),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(bounds.bottomLeft + const Offset(100, -1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(position.pixels, greaterThan(0));
      switch (stop) {
        case '取消指针':
          await mouse.cancel();
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case '切换标签':
          fixture.active = false;
          fixture.rebuild.value++;
        case '刷新':
          fixture.loading = true;
          fixture.rebuild.value++;
        case '切换目录':
          fixture.directory = '/changed';
          fixture.rebuild.value++;
        case '关闭面板':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump();
      final stopped = position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(position.pixels, stopped);
      expect(_box(side), findsNothing);
      if (stop == '取消指针') {
        expect(_selected(tester, side), {'/local/1.txt'});
      }
      if (stop != '取消指针') await mouse.up();
      expect(tester.takeException(), isNull);
    });
  }
}
