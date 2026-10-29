import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/terminal/app_terminal_view.dart';
import 'package:xterm/xterm.dart';

import 'support/shadcn_test_app.dart';

Widget _terminalApp(
  Terminal terminal,
  FocusNode focus, {
  bool active = true,
  GlobalKey? captureKey,
}) => ShadcnTestApp(
  home: Center(
    child: SizedBox(
      width: 640,
      height: 320,
      child: RepaintBoundary(
        key: captureKey,
        child: AppTerminalView(terminal, focusNode: focus, active: active),
      ),
    ),
  ),
);

Future<Terminal> _openTerminal(
  WidgetTester tester, {
  GlobalKey? captureKey,
}) async {
  final terminal = Terminal(maxLines: 1000);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    _terminalApp(terminal, focus, captureKey: captureKey),
  );
  await tester.pumpAndSettle();
  for (var row = 0; row < 200; row++) {
    terminal.write(
      'row-${row.toString().padLeft(3, '0')} abcdefghijklmnop\r\n',
    );
  }
  await tester.pumpAndSettle();
  final state = tester.state<TerminalViewState>(find.byType(TerminalView));
  tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(TerminalView),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .jumpTo(state.renderTerminal.lineHeight * 70);
  await tester.pump();
  return terminal;
}

TerminalController _selection(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

ScrollPosition _scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(TerminalView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Offset _cellPosition(WidgetTester tester, int x, int y) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  return render.localToGlobal(
    render.getOffset(CellOffset(x, y)) +
        Offset(render.cellSize.width / 2, render.lineHeight / 2),
  );
}

Future<(int, int)?> _highlightRows(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  // 在每行文本末尾之后的空白处取样，直接检查实际绘制的灰色选区。
  final sampleX = boundary
      .globalToLocal(
        render.localToGlobal(
          Offset(render.size.width - render.cellSize.width * 5, 0),
        ),
      )
      .dx
      .floor();
  return tester.runAsync<(int, int)?>(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int? first;
      var last = 0;
      for (var y = 0; y < image.height; y++) {
        final offset = (y * image.width + sampleX) * 4;
        if (pixels.getUint8(offset) > 60 &&
            pixels.getUint8(offset + 1) > 60 &&
            pixels.getUint8(offset + 2) > 60) {
          first ??= y;
          last = y;
        }
      }
      return first == null ? null : (first, last);
    } finally {
      image.dispose();
    }
  });
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  testWidgets('滚动后选区高亮跟随文本移动，移出视口后不残留原位置', (tester) async {
    final capture = GlobalKey();
    final terminal = await _openTerminal(tester, captureKey: capture);
    final mouse = await tester.startGesture(
      _cellPosition(tester, 2, 75),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(_cellPosition(tester, terminal.viewWidth - 2, 78));
    await mouse.up();
    await tester.pumpAndSettle();
    final selected = _selection(tester).selection!;
    final before = (await _highlightRows(tester, capture))!;
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final scroll = _scroll(tester);
    final initialScroll = scroll.pixels;
    final delta = render.lineHeight * 2.25;
    scroll.jumpTo(initialScroll + delta);
    await tester.pumpAndSettle();
    final after = (await _highlightRows(tester, capture))!;
    expect(after.$1, closeTo(before.$1 - delta, 1));
    expect(after.$2, closeTo(before.$2 - delta, 1));
    expect(_selection(tester).selection, selected);

    scroll.jumpTo(initialScroll + render.lineHeight * 20);
    await tester.pumpAndSettle();
    expect(await _highlightRows(tester, capture), isNull);
    expect(_selection(tester).selection, selected);
    scroll.jumpTo(initialScroll);
    await tester.pumpAndSettle();
    expect(await _highlightRows(tester, capture), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('按住鼠标滚动时高亮起点跟随文本，末端保留在鼠标位置', (tester) async {
    final capture = GlobalKey();
    final terminal = await _openTerminal(tester, captureKey: capture);
    final mouse = await tester.startGesture(
      _cellPosition(tester, 2, 75),
      kind: PointerDeviceKind.mouse,
    );
    final end = _cellPosition(tester, terminal.viewWidth - 2, 78);
    await mouse.moveTo(end);
    await tester.pumpAndSettle();
    final before = (await _highlightRows(tester, capture))!;
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final scroll = _scroll(tester);
    final initialScroll = scroll.pixels;
    final delta = render.lineHeight * 2.25;
    await tester.sendEventToBinding(
      PointerScrollEvent(position: end, scrollDelta: Offset(0, delta)),
    );
    await tester.pumpAndSettle();
    expect(scroll.pixels, closeTo(initialScroll + delta, .01));
    final after = (await _highlightRows(tester, capture))!;
    expect(after.$1, closeTo(before.$1 - delta, 1));
    expect(after.$2, closeTo(before.$2, render.lineHeight));
    expect(_selection(tester).selection!.begin, const CellOffset(2, 75));
    await mouse.up();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('按住鼠标拖选时滚动并继续拖动，保留文本起点与完整选区', (tester) async {
    final terminal = await _openTerminal(tester);
    final start = _cellPosition(tester, 2, 75);
    final end = _cellPosition(tester, 12, 78);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(end);
    await tester.pump();
    expect(_selection(tester).selection!.begin, const CellOffset(2, 75));
    final originalText = terminal.buffer.getText(_selection(tester).selection!);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: end,
        scrollDelta: Offset(0, _scroll(tester).viewportDimension / 4),
      ),
    );
    await tester.pump();
    expect(
      _scroll(tester).pixels,
      greaterThan(
        70 *
            tester
                .state<TerminalViewState>(find.byType(TerminalView))
                .renderTerminal
                .lineHeight,
      ),
    );
    expect(_selection(tester).selection!.begin, const CellOffset(2, 75));
    expect(_selection(tester).selection!.end.y, greaterThan(78));

    await mouse.moveTo(end + const Offset(8, 0));
    await tester.pump();
    expect(_selection(tester).selection!.begin, const CellOffset(2, 75));
    expect(
      terminal.buffer.getText(_selection(tester).selection!),
      startsWith(originalText),
    );
    await mouse.up();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('松开后的选区经过滚轮和触控板滚动仍保留，可复制完整文本', (tester) async {
    final terminal = await _openTerminal(tester);
    final start = _cellPosition(tester, 2, 75);
    final end = _cellPosition(tester, 12, 78);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(end);
    await mouse.up();
    await tester.pump();
    final selected = _selection(tester).selection!;
    final text = terminal.buffer.getText(selected);
    final before = _scroll(tester).pixels;
    await tester.sendEventToBinding(
      PointerScrollEvent(position: end, scrollDelta: const Offset(0, -160)),
    );
    await tester.pumpAndSettle();
    expect(_scroll(tester).pixels, lessThan(before));
    final wheelOffset = _scroll(tester).pixels;
    final trackpad = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await trackpad.panZoomStart(end);
    await trackpad.panZoomUpdate(end, pan: const Offset(0, -90));
    await trackpad.panZoomEnd();
    await tester.pumpAndSettle();
    expect(_scroll(tester).pixels, greaterThan(wheelOffset));
    expect(_selection(tester).selection, selected);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    Actions.invoke(view.focusNode!.context!, CopySelectionTextIntent.copy);
    await tester.pump();
    expect(copied, text);

    // 单击仍可清除选区；双击仍按单词选择。
    await tester.tapAt(end, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_selection(tester).selection, isNull);
    final word = _cellPosition(
      tester,
      12,
      _scroll(tester).pixels ~/
              tester
                  .state<TerminalViewState>(find.byType(TerminalView))
                  .renderTerminal
                  .lineHeight +
          5,
    );
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      terminal.buffer.getText(_selection(tester).selection!),
      'abcdefghijklmnop',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final upward in [true, false]) {
    testWidgets('拖选到${upward ? '上' : '下'}边缘后自动滚动，松开停止且保留选区', (tester) async {
      final terminal = await _openTerminal(tester);
      final start = _cellPosition(tester, 2, 75);
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(_cellPosition(tester, 10, 77));
      await tester.pump();
      final rect = tester.getRect(find.byType(TerminalView));
      await mouse.moveTo(
        Offset(start.dx + 60, upward ? rect.top + 1 : rect.bottom - 1),
      );
      await tester.pump();
      final before = _scroll(tester).pixels;
      final firstExtent = _selection(tester).selection!.end.y;
      await tester.pump(const Duration(milliseconds: 240));
      if (upward) {
        expect(_scroll(tester).pixels, lessThan(before));
        expect(_selection(tester).selection!.end.y, lessThan(firstExtent));
      } else {
        expect(_scroll(tester).pixels, greaterThan(before));
        expect(_selection(tester).selection!.end.y, greaterThan(firstExtent));
      }
      expect(_selection(tester).selection!.begin, const CellOffset(2, 75));
      await mouse.up();
      await tester.pump();
      final stopped = _scroll(tester).pixels;
      final text = terminal.buffer.getText(_selection(tester).selection!);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_scroll(tester).pixels, stopped);
      expect(terminal.buffer.getText(_selection(tester).selection!), text);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final stop in ['移回中间', '取消手势', '切换页签', '关闭页签']) {
    testWidgets('拖选自动滚动在$stop时停止', (tester) async {
      final terminal = await _openTerminal(tester);
      final start = _cellPosition(tester, 2, 75);
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      final rect = tester.getRect(find.byType(TerminalView));
      // 拖到视口外仍可滚动，不要求鼠标持续移动。
      await mouse.moveTo(Offset(start.dx + 60, rect.bottom + 60));
      await tester.pump();
      final before = _scroll(tester).pixels;
      await tester.pump(const Duration(milliseconds: 160));
      expect(_scroll(tester).pixels, greaterThan(before));
      final position = _scroll(tester);
      final selected = _selection(tester).selection;
      switch (stop) {
        case '移回中间':
          await mouse.moveTo(rect.center);
        case '取消手势':
          await mouse.cancel();
        case '切换页签':
          final view = tester.widget<AppTerminalView>(
            find.byType(AppTerminalView),
          );
          await tester.pumpWidget(
            _terminalApp(terminal, view.focusNode, active: false),
          );
        case '关闭页签':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump();
      final stopped = position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(position.pixels, stopped);
      if (stop == '取消手势' || stop == '切换页签') {
        expect(_selection(tester).selection, selected);
      }
      if (stop != '取消手势') await mouse.up();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Vim 等备用屏幕保留原有滚轮输入，不触发历史缓冲区自动滚动', (tester) async {
    final terminal = await _openTerminal(tester);
    final output = <String>[];
    terminal.onOutput = output.add;
    terminal.write('\x1b[?1049h');
    await tester.pumpAndSettle();
    expect(terminal.isUsingAltBuffer, isTrue);
    final rect = tester.getRect(find.byType(TerminalView));
    final mouse = await tester.startGesture(
      rect.center,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(Offset(rect.center.dx, rect.bottom - 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(output, isEmpty);
    await mouse.up();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: rect.center,
        scrollDelta: const Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(output, isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
