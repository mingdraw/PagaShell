import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/render.dart';

import '../support/fixture_terminal.dart' show TerminalFrameFixture;
import '../support/native_terminal_frames.dart';
import '../support/shadcn_test_app.dart';

void main() {
  late Terminal terminal;
  late List<(int, int)> resizes;
  late FocusNode focus;

  setUp(() {
    resizes = [];
    terminal = Terminal()
      ..onResize = (cols, rows, _, _) => resizes.add((cols, rows));
    focus = FocusNode();
  });

  tearDown(() {
    terminal.dispose();
    focus.dispose();
  });

  Future<void> pumpTerminal(
    WidgetTester tester, {
    required double width,
    double height = 300,
    bool visible = true,
    ScrollController? scrollController,
    Key? captureKey,
  }) => tester.pumpWidget(
    ShadcnTestApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: captureKey,
          child: SizedBox(
            width: width,
            height: height,
            child: TickerMode(
              enabled: visible,
              child: TerminalView(
                terminal,
                focusNode: focus,
                scrollController: scrollController,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  int columns(WidgetTester tester) {
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    return render.size.width ~/ render.cellSize.width;
  }

  testWidgets('连续调宽首次立即同步，间隔内的变化合并为最后一次', (tester) async {
    await pumpTerminal(tester, width: 600);
    expect(resizes, hasLength(1));
    expect(resizes.single.$1, columns(tester));

    // 模拟侧边栏动画：间隔内宽度逐帧变化。
    for (final width in [580.0, 560.0, 540.0, 520.0]) {
      await pumpTerminal(tester, width: width);
    }
    expect(resizes, hasLength(1));

    await tester.pump(RenderTerminal.resizeInterval);
    expect(resizes, hasLength(2));
    expect(resizes.last.$1, columns(tester));

    // 冷却结束后再无变化，不会补发。
    await tester.pump(RenderTerminal.resizeInterval * 2);
    expect(resizes, hasLength(2));
  });

  testWidgets('后台标签暂缓同步尺寸，回到前台时补发最新尺寸', (tester) async {
    await pumpTerminal(tester, width: 600);
    expect(resizes, hasLength(1));
    await tester.pump(RenderTerminal.resizeInterval);

    await pumpTerminal(tester, width: 600, visible: false);
    await pumpTerminal(tester, width: 400, visible: false);
    await tester.pump(RenderTerminal.resizeInterval * 2);
    expect(resizes, hasLength(1));

    await pumpTerminal(tester, width: 400);
    expect(resizes, hasLength(2));
    expect(resizes.last.$1, columns(tester));
  });

  testWidgets('首次挂载在后台也立即同步初始尺寸', (tester) async {
    await pumpTerminal(tester, width: 600, visible: false);
    expect(resizes, hasLength(1));
    expect(resizes.single.$1, columns(tester));
  });

  testWidgets('连续调高及迟到尺寸帧保持贴底首行完整，最终网格与视口一致', (tester) async {
    final source = TerminalFrameFixture()
      ..writeText(List.generate(100, (i) => 'line $i\r\n').join());
    terminal.applyFrame(source.snapshot());
    final pending = <TerminalFrame>[];
    terminal.onResize = (cols, rows, _, _) {
      resizes.add((cols, rows));
      source.resize(cols, rows);
      pending.add(source.snapshot());
    };
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pumpTerminal(tester, width: 600, scrollController: scroll);
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final lineHeight = render.lineHeight;

    void expectWholeTopRow() {
      final first = render.getCellOffset(Offset.zero);
      expect(render.getOffset(CellOffset(0, first.y)).dy, closeTo(0, .001));
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, .001));
    }

    expectWholeTopRow();
    for (final rows in [15, 18, 11, 16]) {
      await pumpTerminal(
        tester,
        width: 600,
        height: rows * lineHeight + lineHeight * .4,
        scrollController: scroll,
      );
      expectWholeTopRow();
    }
    // 新尺寸已请求，但 Rust 的旧尺寸帧仍可能在途中。
    await tester.pump(RenderTerminal.resizeInterval);
    expect(pending, hasLength(2));
    terminal.applyFrame(pending.removeAt(0));
    await tester.pump();
    expectWholeTopRow();
    terminal.applyFrame(pending.removeAt(0));
    await tester.pump();
    expectWholeTopRow();
    expect(terminal.viewHeight, 16);
    expect(terminal.requestedSize.rows, 16);
    final top = render.getOffset(CellOffset(0, terminal.buffer.scrollBack));
    expect(top.dy, closeTo(0, .001));
    expect(
      render.cursorOffset.dy + lineHeight,
      lessThanOrEqualTo(render.size.height),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('回看历史时连续调高并应用尺寸帧保留原滚动位置', (tester) async {
    final source = TerminalFrameFixture()
      ..writeText(List.generate(100, (i) => 'line $i\r\n').join());
    terminal.applyFrame(source.snapshot());
    final pending = <TerminalFrame>[];
    terminal.onResize = (cols, rows, _, _) {
      source.resize(cols, rows);
      pending.add(source.snapshot());
    };
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pumpTerminal(tester, width: 600, scrollController: scroll);
    terminal.applyFrame(pending.removeAt(0));
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final offset = render.lineHeight * 20.3;
    scroll.jumpTo(offset);
    await tester.pump();
    final top = render.getCellOffset(Offset.zero);
    final topPosition = render.getOffset(top);
    for (final height in [220.0, 320.0, 260.0]) {
      await pumpTerminal(
        tester,
        width: 600,
        height: height,
        scrollController: scroll,
      );
      await tester.pump(RenderTerminal.resizeInterval);
      while (pending.isNotEmpty) {
        terminal.applyFrame(pending.removeAt(0));
        await tester.pump();
      }
      expect(scroll.offset, closeTo(offset, .001));
      expect(render.getCellOffset(Offset.zero), top);
      expect(render.getOffset(top), topPosition);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('短内容原生帧在连续缩放及等待尺寸帧时提示符持续可见', (tester) async {
    final frames = nativeTerminalFrames(
      path: 'test/fixtures/native_terminal_resize_frames.json',
    );
    terminal.applyFrame(frames.first);
    final capture = GlobalKey();
    await pumpTerminal(tester, width: 600, height: 500, captureKey: capture);
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final cell = render.cellSize;

    Future<void> expectPromptVisible() async {
      final header = render.getOffset(const CellOffset(0, 0));
      expect(header.dy, closeTo(0, .001));
      expect(render.cursorOffset.dy, closeTo(cell.height, .001));
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final greenPixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var green = 0;
          for (var i = 0; i < pixels.lengthInBytes; i += 4) {
            final r = pixels.getUint8(i);
            final g = pixels.getUint8(i + 1);
            final b = pixels.getUint8(i + 2);
            if (g > 80 && g > r + 40 && g > b + 40) green++;
          }
          return green;
        } finally {
          image.dispose();
        }
      });
      expect(greenPixels, greaterThan(10), reason: '原生绿色提示符不能在 resize 帧途中消失');
    }

    await expectPromptVisible();
    for (final frame in frames.skip(1)) {
      // 布局已经变小，当前收到的仍是旧高度帧；中途还可能反向拖动。
      for (final extraRows in [2.4, .4]) {
        await pumpTerminal(
          tester,
          width: (frame.columns + .4) * cell.width,
          height: (frame.rows + extraRows) * cell.height,
          captureKey: capture,
        );
        await tester.pump(const Duration(milliseconds: 40));
        await expectPromptVisible();
      }
      await tester.pump(RenderTerminal.resizeInterval);
      terminal.applyFrame(frame);
      await tester.pump();
      await expectPromptVisible();
      expect(terminal.buffer.scrollBack, 0);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
