import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/presentation/settings/terminal_settings_section.dart';
import 'package:pagashell/presentation/terminal/app_terminal_view.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/painter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../support/in_memory_settings_repository.dart';
import '../support/shadcn_test_app.dart';

const _red = CellColor.rgb | 0xF38BA8;
const _peach = CellColor.rgb | 0xFAB387;
const _yellow = CellColor.rgb | 0xF9E2AF;
const _lavender = CellColor.rgb | 0xB4BEFE;
const _crust = CellColor.rgb | 0x11111B;

Uint32List _encodeCells(
  int cols,
  List<(int codepoint, int fg, int bg, int flags)> items,
) {
  final cells = Uint32List(cols * 4);
  for (var i = 0; i < items.length && i < cols; i++) {
    final (cp, fg, bg, flags) = items[i];
    final base = i * 4;
    cells[base] = fg;
    cells[base + 1] = bg;
    cells[base + 2] = flags;
    cells[base + 3] = cp | (1 << CellContent.widthShift);
  }
  return cells;
}

Future<({Uint8List rgba, int width, int height})> _renderLineToRgba(
  TerminalPainter painter,
  BufferLine line, {
  required Offset offset,
  required int width,
  required int height,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF000000),
  );
  painter.paintLine(canvas, offset, line);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return (rgba: data.buffer.asUint8List(), width: width, height: height);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

(int r, int g, int b) _pixelAt(
  ({Uint8List rgba, int width, int height}) img,
  int x,
  int y,
) {
  final i = (y * img.width + x) * 4;
  return (img.rgba[i], img.rgba[i + 1], img.rgba[i + 2]);
}

void main() {
  tearDown(Get.reset);

  test('Powerline 矢量字形严格对齐单元格高度且背景不向外溢出 1px', () async {
    const cols = 12;
    // AB -> 测试左圆盖、连续分隔符、右圆盖以及紧跟的默认背景格
    final line = BufferLine.fromFrame(
      TerminalLine(
        id: 1,
        wrapped: false,
        cells: _encodeCells(cols, const [
          (0xE0B6, _red, 0, 0),
          (0x41, _crust, _red, 0),
          (0xE0B4, _red, _peach, 0),
          (0xE0B4, _peach, _yellow, 0),
          (0x42, _crust, _yellow, 0),
          (0xE0B4, _yellow, 0, 0),
          (0x20, 0, 0, 0),
          (0x20, _crust, _lavender, 0),
        ]),
      ),
      cols,
    );

    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(fontSize: 16, fontFamily: 'monospace'),
      textScaler: TextScaler.noScaling,
    );
    addTearDown(painter.dispose);

    const top = 12;
    const left = 10;
    final cellW = painter.cellSize.width;
    final cellH = painter.cellSize.height.toInt();
    expect(painter.cellSize.height, painter.cellSize.height.truncateToDouble());

    final img = await _renderLineToRgba(
      painter,
      line,
      offset: Offset(left.toDouble(), top.toDouble()),
      width: (left + cols * cellW + 16).ceil(),
      height: top + cellH + 12,
    );

    // 单元格正上方一行与正下方一行必须全黑：Powerline 字形不许上下冒出锯齿。
    for (var x = left; x < left + (8 * cellW).ceil(); x++) {
      expect(_pixelAt(img, x, top - 1), (0, 0, 0), reason: 'x=$x 上沿溢出');
      expect(_pixelAt(img, x, top + cellH), (0, 0, 0), reason: 'x=$x 下沿溢出');
    }

    // 第 7 格（_lavender 背景）右侧紧邻默认背景格：不得向右多画 1px。
    final lavenderRightEdge = (left + 8 * cellW).round();
    expect(_pixelAt(img, lavenderRightEdge, top + cellH ~/ 2), (0, 0, 0));

    // 第 0 格左圆盖  中间偏右处应填充红色，第 2 格  左半应填充红色。
    final capX = (left + cellW * 0.7).floor();
    expect(_pixelAt(img, capX, top + cellH ~/ 2).$1, greaterThan(200));

    // 第 3 格连续  中线左侧应保留前一格的 peach（未在尖端被后一格切掉）。
    final secondSepX = (left + 3 * cellW + cellW * 0.4).floor();
    final (r, g, b) = _pixelAt(img, secondSepX, top + cellH ~/ 2);
    expect(r, greaterThan(200));
    expect(g, greaterThan(150));
    expect(b, lessThan(160));
  });

  test('制表符、块元素在单元格内完整绘制，invisible 隐藏前景', () async {
    const cols = 6;
    final line = BufferLine.fromFrame(
      TerminalLine(
        id: 2,
        wrapped: false,
        cells: _encodeCells(cols, const [
          (0x2588, _red, 0, 0), // █ 满块
          (0x2580, _peach, 0, 0), // ▀ 上半块
          (0x256D, _yellow, 0, 0), // ╭ 圆角制表符
          (0x2588, _lavender, 0, CellFlags.invisible), // 隐藏前景
        ]),
      ),
      cols,
    );

    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(fontSize: 14, fontFamily: 'monospace'),
      textScaler: TextScaler.noScaling,
    );
    addTearDown(painter.dispose);

    const top = 8;
    const left = 8;
    final cellW = painter.cellSize.width;
    final cellH = painter.cellSize.height.toInt();

    final img = await _renderLineToRgba(
      painter,
      line,
      offset: Offset(left.toDouble(), top.toDouble()),
      width: (left + cols * cellW + 16).ceil(),
      height: top + cellH + 8,
    );

    // 满块 █ 覆盖上中下全高但不越界。
    final blockX = (left + cellW * 0.5).floor();
    expect(_pixelAt(img, blockX, top).$1, greaterThan(200));
    expect(_pixelAt(img, blockX, top + cellH - 1).$1, greaterThan(200));
    expect(_pixelAt(img, blockX, top - 1), (0, 0, 0));
    expect(_pixelAt(img, blockX, top + cellH), (0, 0, 0));

    // 上半块 ▀ 仅上半填充，下半保持背景黑。
    final halfX = (left + cellW * 1.5).floor();
    expect(_pixelAt(img, halfX, top + 1).$1, greaterThan(200));
    expect(_pixelAt(img, halfX, top + cellH - 1), (0, 0, 0));

    // 圆角 ╭ 不向上下越界。
    final arcStart = (left + 2 * cellW).round();
    final arcEnd = (left + 3 * cellW).round();
    for (var x = arcStart; x < arcEnd; x++) {
      expect(_pixelAt(img, x, top - 1), (0, 0, 0));
      expect(_pixelAt(img, x, top + cellH), (0, 0, 0));
    }

    // invisible 单元格不绘制前景。
    final hiddenX = (left + cellW * 3.5).floor();
    expect(_pixelAt(img, hiddenX, top + cellH ~/ 2), (0, 0, 0));
  });

  test('终端字号 pt 按平台 DPI 换算逻辑像素', () {
    expect(terminalFontSizeToLogicalPixels(13, TargetPlatform.macOS), 13);
    expect(
      terminalFontSizeToLogicalPixels(12, TargetPlatform.windows),
      closeTo(16, 1e-6),
    );
    expect(
      terminalFontSizeToLogicalPixels(12, TargetPlatform.linux),
      closeTo(16, 1e-6),
    );
  });

  testWidgets('终端字号设置使用 pt 单位并兼容快捷键调整出的非预设字号', (tester) async {
    final repo = InMemorySettingsRepository(
      sidebarState: SidebarState(terminalFontSize: 17),
    );
    final settings = Get.put(SettingsController(repository: repo));
    await settings.ready;

    await tester.pumpWidget(
      const ShadcnTestApp(
        home: SizedBox(width: 420, child: TerminalSettingsSection()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('17 pt'), findsOneWidget);
    await tester.tap(find.text('17 pt'));
    await tester.pumpAndSettle();
    expect(find.text('8 pt'), findsOneWidget);
    expect(find.text('13 pt'), findsOneWidget);
    expect(find.text('13 px'), findsNothing);
    await tester.tap(find.text('12 pt').last);
    await tester.pumpAndSettle();
    expect(settings.terminalFontSize.value, 12);
  });

  testWidgets('终端按平台换算 pt 字号并在快捷键缩放提示中展示 pt 单位', (tester) async {
    final repo = InMemorySettingsRepository(
      sidebarState: SidebarState(terminalFontSize: 12),
    );
    final settings = Get.put(SettingsController(repository: repo));
    await settings.ready;
    final terminal = Terminal();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(terminal.dispose);

    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Theme(
          data: AppTheme.shadcnDark.copyWith(
            platform: () => TargetPlatform.windows,
          ),
          child: SizedBox(
            width: 600,
            height: 400,
            child: AppTerminalView(terminal, focusNode: focus, active: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TerminalPane>(find.byType(TerminalPane)).textStyle.fontSize,
      closeTo(16, 1e-6),
    );

    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(settings.terminalFontSize.value, 13);
    expect(find.text('终端字号：13 pt'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });
}
