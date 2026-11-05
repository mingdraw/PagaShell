import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/render.dart';

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
    bool visible = true,
  }) => tester.pumpWidget(
    ShadcnTestApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: 300,
          child: TickerMode(
            enabled: visible,
            child: TerminalView(terminal, focusNode: focus),
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
}
