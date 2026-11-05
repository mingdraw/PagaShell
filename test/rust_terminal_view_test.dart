import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/presentation/terminal/app_terminal_view.dart';

import 'support/fixture_terminal.dart';

import 'support/native_terminal_frames.dart';
import 'support/shadcn_test_app.dart';

Offset _cell(WidgetTester tester, int x, int y) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  return render.localToGlobal(
    render.getOffset(CellOffset(x, y)) +
        Offset(render.cellSize.width / 2, render.lineHeight / 2),
  );
}

Future<(int, int)> _paintedRows(
  WidgetTester tester,
  GlobalKey key, {
  int column = 40,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  final x = boundary
      .globalToLocal(
        render.localToGlobal(Offset(render.cellSize.width * column, 0)),
      )
      .dx
      .floor();
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int? first;
      var last = 0;
      for (var y = 0; y < image.height; y++) {
        final i = (y * image.width + x) * 4;
        if (pixels.getUint8(i) > 60 &&
            pixels.getUint8(i + 1) > 60 &&
            pixels.getUint8(i + 2) > 60) {
          first ??= y;
          last = y;
        }
      }
      expect(first, isNotNull);
      return (first!, last);
    } finally {
      image.dispose();
    }
  }))!;
}

void _moveCursor(Terminal terminal, int column, int row) {
  terminal.applyFrame(
    TerminalFrame(
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
      alternate: terminal.isUsingAltBuffer,
      cursorX: column,
      cursorY: row,
      modes: 1,
      cursorBlink: false,
      trimFront: 0,
      keepRows: terminal.buffer.height,
      appendRows: const [],
      lines: const [],
    ),
  );
}

void main() {
  testWidgets('Rust 光标绘制在命令所在行，随视口滚动并切换备用屏幕', (tester) async {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()..applyFrame(frames[0]);
    final focus = FocusNode();
    final capture = GlobalKey();
    addTearDown(focus.dispose);
    _moveCursor(terminal, 40, 4);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 640,
            height: 240,
            child: RepaintBoundary(
              key: capture,
              child: AppTerminalView(terminal, focusNode: focus, active: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    ScrollPosition scrollPosition() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    Future<void> expectCursorAt(int column, int absoluteRow) async {
      final expected = render.getOffset(CellOffset(column, absoluteRow));
      expect(render.cursorOffset.dy, closeTo(expected.dy, .01));
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final top = boundary.globalToLocal(render.localToGlobal(expected)).dy;
      final painted = await _paintedRows(tester, capture, column: column);
      expect(painted.$1, closeTo(top, 1));
      expect(painted.$2, closeTo(top + render.lineHeight - 1, 1));
    }

    expect(focus.hasFocus, isTrue);
    await expectCursorAt(40, 36);
    final scroll = scrollPosition();
    scroll.jumpTo(scroll.pixels - render.lineHeight * 2);
    await tester.pumpAndSettle();
    await expectCursorAt(40, 36);

    terminal.applyFrame(frames[2]);
    _moveCursor(terminal, 20, 3);
    await tester.pumpAndSettle();
    await expectCursorAt(20, 3);

    terminal.applyFrame(frames[3]);
    _moveCursor(terminal, 40, 4);
    await tester.pumpAndSettle();
    final restoredScroll = scrollPosition();
    restoredScroll.jumpTo(restoredScroll.maxScrollExtent);
    await tester.pumpAndSettle();
    await expectCursorAt(40, 36);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    terminal.dispose();
  });

  testWidgets('Rust 帧的选区高亮随视口和原生回滚移动，复制仍取对应文本', (tester) async {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()..applyFrame(frames[0]);
    final focus = FocusNode();
    final capture = GlobalKey();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 640,
            height: 320,
            child: RepaintBoundary(
              key: capture,
              child: AppTerminalView(terminal, focusNode: focus, active: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    scroll.jumpTo(state.renderTerminal.lineHeight * 20);
    await tester.pump();
    final mouse = await tester.startGesture(
      _cell(tester, 2, 25),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(_cell(tester, 46, 28));
    await mouse.up();
    await tester.pumpAndSettle();
    final selection = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller!;
    final text = terminal.buffer.getText(selection.selection!);
    final before = await _paintedRows(tester, capture);
    scroll.jumpTo(scroll.pixels + state.renderTerminal.lineHeight * 2);
    await tester.pumpAndSettle();
    final scrolled = await _paintedRows(tester, capture);
    expect(scrolled.$1, lessThan(before.$1));
    expect(terminal.buffer.getText(selection.selection!), text);
    terminal.applyFrame(frames[1]);
    await tester.pumpAndSettle();
    final updated = await _paintedRows(tester, capture);
    expect(updated.$1, lessThan(scrolled.$1));
    expect(terminal.buffer.getText(selection.selection!), text);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    terminal.dispose();
  });
}
