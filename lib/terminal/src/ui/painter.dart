import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/palette_builder.dart';
import 'package:pagashell/terminal/src/ui/paragraph_cache.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required this._theme,
    required this._textStyle,
    required this._textScaler,
  }) : _paragraphCache = ParagraphCache.acquire(_textStyle, _textScaler);

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// [_colorPalette] 的 ARGB32 值，字形缓存键直接用整数颜色，命中时不分配 Color。
  late var _paletteValues = _argbValues(_colorPalette);

  static List<int> _argbValues(List<Color> colors) =>
      List<int>.generate(colors.length, (i) => colors[i].toARGB32());

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// 已排版字形，按 [_textStyle] 与 [_textScaler] 在终端之间共享。
  /// 构造时即取得引用，尚未绘制的终端也能与释放操作成对。
  ParagraphCache _paragraphCache;

  /// 释放共享的字形缓存引用。
  void dispose() {
    ParagraphCache.release(_textStyle, _textScaler);
  }

  /// 绘制配置版本：样式、缩放、主题或系统字体变化时递增，
  /// 调用方据此丢弃按行录制的绘制结果。
  int get generation => _generation;
  int _generation = 0;

  /// 背景、光标与高亮绘制复用 Paint，避免逐格、逐帧分配。
  final _backgroundPaint = Paint();
  final _decorationPaint = Paint()..strokeWidth = 1;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    ParagraphCache.release(_textStyle, _textScaler);
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache = ParagraphCache.acquire(_textStyle, _textScaler);
    _generation++;
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    ParagraphCache.release(_textStyle, _textScaler);
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache = ParagraphCache.acquire(_textStyle, _textScaler);
    _generation++;
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paletteValues = _argbValues(_colorPalette);
    _generation++;
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(textStyle.getTextStyle(textScaler: _textScaler));
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    ParagraphCache.clearAll();
    _generation++;
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = _decorationPaint..color = _theme.cursor;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, 0),
          Offset(offset.dx, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset = offset.translate(
      length * _cellSize.width,
      _cellSize.height,
    );

    final paint = _decorationPaint
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRect(Rect.fromPoints(offset, endOffset), paint);
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  ///
  /// 先画背景再画字形：相邻同色背景合并为一个矩形，字形仍逐格绘制以保持
  /// 与单元格对齐（字体前进宽度、CJK 与后备字体不一定等于格宽）。
  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    _paintLineBackground(canvas, offset, line, cellData);

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      paintCellForeground(canvas, offset.translate(i * cellWidth, 0), cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  void _paintLineBackground(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    CellData cellData,
  ) {
    Color? runColor;
    var runStart = 0;
    var runEnd = 0;

    void flush() {
      final color = runColor;
      if (color == null) return;
      _backgroundPaint.color = color;
      // 多画 1px，避免相邻矩形之间因小数格宽出现缝隙。
      canvas.drawRect(
        Rect.fromLTWH(
          offset.dx + runStart * _cellSize.width,
          offset.dy,
          (runEnd - runStart) * _cellSize.width + 1,
          _cellSize.height,
        ),
        _backgroundPaint,
      );
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final span = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
      final color = cellBackgroundColor(cellData);
      if (color != runColor || i != runEnd) {
        flush();
        runColor = color;
        runStart = i;
      }
      runEnd = i + span;
      i += span - 1;
    }
    flush();
  }

  /// The effective background color of a cell, or `null` when the cell uses
  /// the default background and nothing needs to be painted.
  @pragma('vm:prefer-inline')
  Color? cellBackgroundColor(CellData cellData) {
    if (cellData.flags & CellFlags.inverse != 0) {
      return resolveForegroundColor(cellData.foreground);
    }
    if (cellData.background & CellColor.typeMask == CellColor.normal) {
      return null;
    }
    return resolveBackgroundColor(cellData.background);
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cellFlags = cellData.flags;
    var color = cellFlags & CellFlags.inverse == 0
        ? _colorValue(cellData.foreground, _theme.foreground)
        : _colorValue(cellData.background, _theme.background);
    if (cellFlags & CellFlags.faint != 0) {
      color = (color & 0x00FFFFFF) | 0x80000000;
    }
    final styleFlags =
        (cellFlags & CellFlags.bold != 0 ? ParagraphCache.bold : 0) |
        (cellFlags & CellFlags.italic != 0 ? ParagraphCache.italic : 0) |
        (cellFlags & CellFlags.underline != 0 ? ParagraphCache.underline : 0);

    final cluster = cellData.text;
    final glyphKey = ParagraphCache.glyphKey(
      cellData.content,
      color,
      styleFlags,
    );
    final clusterStyle = ParagraphCache.clusterStyle(color, styleFlags);
    var paragraph = cluster == null
        ? _paragraphCache.glyph(glyphKey)
        : _paragraphCache.cluster(cluster, clusterStyle);

    if (paragraph == null) {
      final style = _textStyle.toTextStyle(
        color: Color(color),
        bold: styleFlags & ParagraphCache.bold != 0,
        italic: styleFlags & ParagraphCache.italic != 0,
        underline: styleFlags & ParagraphCache.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = cluster ?? String.fromCharCode(charCode);
      if (styleFlags & ParagraphCache.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      final laidOut = ParagraphCache.layout(char, style, _textScaler);
      paragraph = cluster == null
          ? _paragraphCache.putGlyph(glyphKey, laidOut)
          : _paragraphCache.putCluster(cluster, clusterStyle, laidOut);
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    final color = cellBackgroundColor(cellData);
    if (color == null) return;

    final paint = _backgroundPaint..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// ARGB32 value of [cellColor]; [fallback] is used for the default color.
  @pragma('vm:prefer-inline')
  int _colorValue(int cellColor, Color fallback) {
    final colorValue = cellColor & CellColor.valueMask;
    switch (cellColor & CellColor.typeMask) {
      case CellColor.normal:
        return fallback.toARGB32();
      case CellColor.named:
      case CellColor.palette:
        return _paletteValues[colorValue];
      default:
        return colorValue | 0xFF000000;
    }
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
