import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

import '../support/shadcn_test_app.dart';

const _columns = 20;
const _rows = 5;
const _red = CellColor.rgb | 0xFF0000;

TerminalLine _line(int id, String text, {int background = 0, int cells = 0}) {
  final data = Uint32List(_columns * 4);
  for (var i = 0; i < _columns; i++) {
    final char = i < text.length ? text.codeUnitAt(i) : 0;
    data[i * 4 + 1] = i < cells ? background : 0;
    data[i * 4 + 3] = char | (1 << CellContent.widthShift);
  }
  return TerminalLine(id: id, wrapped: false, cells: data);
}

TerminalFrame _frame({
  required List<TerminalLine> lines,
  int keepRows = _rows,
  List<int> appendRows = const [],
  int cursorX = 0,
}) => TerminalFrame(
  columns: _columns,
  rows: _rows,
  alternate: false,
  cursorX: cursorX,
  cursorY: 0,
  modes: 0,
  cursorBlink: false,
  trimFront: 0,
  keepRows: keepRows,
  appendRows: appendRows,
  lines: lines,
);

void main() {
  testWidgets('只重新录制内容变化的行，光标移动复用全部行', (tester) async {
    final terminal = Terminal()
      ..applyFrame(
        _frame(
          keepRows: 0,
          appendRows: [for (var id = 1; id <= _rows; id++) id],
          lines: [for (var id = 1; id <= _rows; id++) _line(id, 'row-$id')],
        ),
      );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(terminal.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: TerminalView(terminal, focusNode: focus),
          ),
        ),
      ),
    );
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    expect(render.cachedLinePictureCount, _rows);
    final recorded = render.linePictureRecordCount;

    terminal.applyFrame(_frame(lines: [_line(3, 'changed')]));
    await tester.pump();
    expect(render.linePictureRecordCount, recorded + 1);
    expect(terminal.lines[2].getText(), startsWith('changed'));

    terminal.applyFrame(_frame(lines: const [], cursorX: 4));
    await tester.pump();
    expect(render.linePictureRecordCount, recorded + 1);
    expect(render.cachedLinePictureCount, _rows);
  });

  testWidgets('合并绘制的同色背景覆盖整段单元格', (tester) async {
    final terminal = Terminal()
      ..applyFrame(
        _frame(
          keepRows: 0,
          appendRows: [1],
          lines: [_line(1, '', background: _red, cells: 10)],
        ),
      );
    final focus = FocusNode();
    final capture = GlobalKey();
    addTearDown(focus.dispose);
    addTearDown(terminal.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 400,
              height: 120,
              child: TerminalView(
                terminal,
                focusNode: focus,
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final cell = render.cellSize;
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;

    final (inside, outside) = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int red(double x) {
          final i = ((cell.height / 2).floor() * image.width + x.floor()) * 4;
          return pixels.getUint8(i);
        }

        // 第 2–9 格（避开光标所在的第 0 格）在红色背景内，第 12 格之后不在。
        return (
          [for (var c = 2; c < 10; c++) red((c + .5) * cell.width)],
          red(12.5 * cell.width),
        );
      } finally {
        image.dispose();
      }
    }))!;
    expect(inside, everyElement(greaterThan(200)));
    expect(outside, lessThan(100));
  });

  testWidgets('传入等价的非 const TerminalStyle 重建时复用已录制的行缓存', (tester) async {
    final terminal = Terminal()
      ..applyFrame(
        _frame(
          keepRows: 0,
          appendRows: [for (var id = 1; id <= _rows; id++) id],
          lines: [for (var id = 1; id <= _rows; id++) _line(id, 'row-$id')],
        ),
      );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(terminal.dispose);

    Widget buildView(double fontSize) => ShadcnTestApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 300,
          child: TerminalView(
            terminal,
            focusNode: focus,
            textStyle: TerminalStyle(
              fontSize: fontSize,
              fontFamily: 'FiraCode Nerd Font Mono',
              fontFamilyFallback: List<String>.of(['Menlo', 'monospace']),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildView(14));
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final recorded = render.linePictureRecordCount;

    await tester.pumpWidget(buildView(14));
    await tester.pump();
    expect(render.linePictureRecordCount, recorded);
  });

  test('Buffer.applyFrame 直接复用新帧 cells 且 getText 正确提取宽字符与组合字符', () {
    final cells = Uint32List(_columns * 4);
    // "A中🙂é" -> col 0: 'A'(w1), col 1: '中'(w2), col 3: 🙂(w2), col 5: cluster 'e\u0301'(w1)
    cells[0 * 4 + 3] = 0x41 | (1 << CellContent.widthShift);
    cells[1 * 4 + 3] = 0x4E2D | (2 << CellContent.widthShift);
    cells[3 * 4 + 3] = 0x1F642 | (2 << CellContent.widthShift);
    cells[5 * 4 + 3] = 0x65 | (1 << CellContent.widthShift);
    final frameLine = TerminalLine(
      id: 9,
      wrapped: false,
      cells: cells,
      clusters: const {5: 'e\u0301'},
    );
    final terminal = Terminal()
      ..applyFrame(
        _frame(keepRows: 0, appendRows: const [9], lines: [frameLine]),
      );
    addTearDown(terminal.dispose);

    final row = terminal.lines[0];
    expect(identical(row.data, cells), isTrue);
    expect(row.version, 1);
    expect(row.getText(), 'A中🙂e\u0301');
    expect(row.getText(0, 3), 'A中');
    expect(row.getText(1, 5), '中🙂');
  });
}
