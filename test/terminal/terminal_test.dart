import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

import '../support/native_terminal_frames.dart';

void main() {
  test('Rust 原生帧直接更新显示，不进入 Dart ANSI 解析器', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    var changes = 0;
    terminal.addListener(() => changes++);
    terminal.applyFrame(frames[0]);
    expect((terminal.viewWidth, terminal.viewHeight), (48, 12));
    expect(terminal.buffer.height, 44);
    expect(terminal.buffer.getText(), contains('row-099'));
    expect(terminal.buffer.getText(), isNot(contains('row-000')));
    expect(changes, 1);
  });

  test('光标绝对行跟随 Rust 帧，覆盖回滚、备用屏幕和尺寸变化', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    const positions = [
      (0, 11, 32, 43),
      (0, 11, 32, 43),
      (6, 0, 0, 0),
      (0, 11, 32, 43),
      (0, 9, 32, 41),
      (1, 2, 0, 2),
      (0, 0, 0, 0),
    ];
    for (var i = 0; i < frames.length; i++) {
      terminal.applyFrame(frames[i]);
      final buffer = terminal.buffer;
      expect(
        (
          buffer.cursorX,
          buffer.cursorY,
          buffer.scrollBack,
          buffer.absoluteCursorY,
        ),
        positions[i],
        reason: 'native frame $i',
      );
    }
  });

  test('增量滚动保留行对象和选择锚点，淘汰的行解除绑定', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()..applyFrame(frames[0]);
    addTearDown(terminal.dispose);
    final line = terminal.lines.toList().firstWhere(
      (line) => line.getText().startsWith('row-090'),
    );
    final anchor = line.createAnchor(2);
    final oldIndex = anchor.y;
    final evicted = terminal.lines[0].createAnchor(0);
    terminal.applyFrame(frames[1]);
    expect(anchor.attached, isTrue);
    expect(anchor.line, same(line));
    expect(anchor.y, oldIndex - 1);
    expect(evicted.attached, isFalse);
    expect(terminal.buffer.getText(), contains('row-100'));
    anchor.dispose();
    evicted.dispose();
  });

  test('备用屏幕、组合字符、颜色和键鼠模式来自 Rust，退出后恢复主屏幕', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()
      ..applyFrame(frames[0])
      ..applyFrame(frames[1]);
    addTearDown(terminal.dispose);
    final original = terminal.buffer.getText();
    final output = <String>[];
    terminal.onOutput = output.add;
    terminal.applyFrame(frames[2]);
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(terminal.buffer.height, 12);
    expect(terminal.bracketedPasteMode, isTrue);
    expect(terminal.cursorKeysMode, isTrue);
    expect(terminal.mouseMode, MouseMode.upDownScrollDrag);
    expect(terminal.mouseReportMode, MouseReportMode.sgr);
    expect(terminal.buffer.getText(), contains('中e\u0301 🙂'));
    final cell = CellData.empty();
    terminal.lines[0].getCellData(2, cell);
    expect(cell.text, 'e\u0301');
    expect(cell.foreground, (3 << 25) | 0x123456);
    terminal.paste('中文\nnext');
    terminal.keyInput(TerminalKey.arrowUp);
    expect(output, ['\x1b[200~中文\nnext\x1b[201~', '\x1bOA']);
    terminal.applyFrame(frames[3]);
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.buffer.getText(), original);
    expect(terminal.bracketedPasteMode, isFalse);
    expect(terminal.cursorKeysMode, isFalse);
  });

  test('原生滚动区域内重排行时复用行对象，选择锚点跟随同一文本', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal();
    addTearDown(terminal.dispose);
    for (final frame in frames.take(6)) {
      terminal.applyFrame(frame);
    }
    final line = terminal.lines[0];
    final anchor = line.createAnchor(0);
    expect(line.getText(), 'A');
    terminal.applyFrame(frames[6]);
    expect(terminal.lines[1], same(line));
    expect(anchor.attached, isTrue);
    expect(anchor.y, 1);
    expect(terminal.lines[1].getText(), 'A');
    expect(terminal.lines[2].getText(), 'B');
    expect(terminal.lines[3].getText(), 'C');
    anchor.dispose();
  });

  test('尺寸变化等待 Rust 重排帧，不在 Dart 中重新排版；关闭丢弃迟到帧', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()
      ..applyFrame(frames[0])
      ..applyFrame(frames[1])
      ..applyFrame(frames[2])
      ..applyFrame(frames[3]);
    final resize = <(int, int)>[];
    terminal.onResize = (cols, rows, _, _) => resize.add((cols, rows));
    final content = terminal.buffer.getText();
    terminal.resize(32, 10);
    terminal.resize(32, 10);
    expect(resize, [(32, 10)]);
    expect(terminal.requestedSize, (columns: 32, rows: 10));
    expect((terminal.viewWidth, terminal.viewHeight), (48, 12));
    expect(terminal.buffer.getText(), content);
    terminal.applyFrame(frames[4]);
    expect((terminal.viewWidth, terminal.viewHeight), (32, 10));
    expect(terminal.buffer.getText(), contains('row-100'));
    terminal.dispose();
    terminal.applyFrame(frames[0]);
    expect(terminal.lines.length, 0);
    expect(terminal.onOutput, isNull);
    expect(terminal.onResize, isNull);
  });

  test('释放控制器会解除选区和高亮锚点，存活终端仍可接收帧', () {
    final frames = nativeTerminalFrames();
    final terminal = Terminal()..applyFrame(frames[0]);
    addTearDown(terminal.dispose);
    final controller = TerminalController();
    final base = terminal.buffer.createAnchor(1, 2);
    final extent = terminal.buffer.createAnchor(4, 3);
    controller.setSelection(base, extent);
    final p1 = terminal.buffer.createAnchor(0, 4);
    final p2 = terminal.buffer.createAnchor(5, 5);
    final highlight = controller.highlight(
      p1: p1,
      p2: p2,
      color: TerminalThemes.defaultTheme.selection,
    );
    expect(controller.selection, isNotNull);
    expect(highlight.range, isNotNull);
    controller.dispose();
    controller.dispose();
    highlight.dispose();
    expect([base, extent, p1, p2].every((anchor) => !anchor.attached), isTrue);
    expect(controller.highlights, isEmpty);
    terminal.applyFrame(frames[1]);
    expect(terminal.buffer.getText(), contains('row-100'));
  });
}
