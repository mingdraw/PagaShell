import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/custom_glyphs.dart';
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

  /// 共享的固定支撑线段落样式，与 [_textStyle] / [_textScaler] 同步更新。
  late ParagraphStyle _paragraphStyle = _textStyle.toParagraphStyle(
    _textScaler,
  );

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
  /// 背景矩形关闭抗锯齿并共享取整列边界，消除相邻色块发丝缝且不再向外多画 1px。
  final _backgroundPaint = Paint()..isAntiAlias = false;
  final _decorationPaint = Paint()..strokeWidth = 1;
  final _customGlyphs = TerminalCustomGlyphs();

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    ParagraphCache.release(_textStyle, _textScaler);
    _textStyle = value;
    _paragraphStyle = _textStyle.toParagraphStyle(_textScaler);
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
    _paragraphStyle = _textStyle.toParagraphStyle(_textScaler);
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
    final builder = ParagraphBuilder(_paragraphStyle);
    builder.pushStyle(textStyle.getTextStyle(textScaler: _textScaler));
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(const ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height.ceilToDouble(),
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _paragraphStyle = _textStyle.toParagraphStyle(_textScaler);
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

  @pragma('vm:prefer-inline')
  double _colX(double baseDx, int col) =>
      (baseDx + col * _cellSize.width).roundToDouble();

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  ///
  /// 分三遍绘制：
  /// 1. 合并相邻同色背景为共享边界的精确矩形（无 1px 越界、无发丝缝）；
  /// 2. 实心 Powerline 分隔符在文字之前绘制，既可微幅搭接同色背景消除非整数
  ///    DPI 接缝，又绝不会切掉连续分隔符尖端或遮挡相邻单元格文字；
  /// 3. 普通文字、图标与制表符/块元素逐格绘制，保持严格单元格对齐。
  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    final cellHeight = _cellSize.height;

    final hasSolidPowerline = _paintLineBackground(
      canvas,
      offset,
      line,
      cellData,
    );
    if (hasSolidPowerline) {
      _paintSolidPowerlineRuns(canvas, offset, line, cellData);
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final span = charWidth == 2 ? 2 : 1;
      final charCode = cellData.content & CellContent.codepointMask;
      final isSolidPowerline =
          cellData.text == null &&
          span == 1 &&
          TerminalCustomGlyphs.isSolidPowerline(charCode);
      if (isSolidPowerline) {
        _paintCellDecorations(
          canvas,
          Rect.fromLTRB(
            _colX(offset.dx, i),
            offset.dy,
            _colX(offset.dx, i + 1),
            offset.dy + cellHeight,
          ),
          cellData,
        );
      } else {
        final cellRect = Rect.fromLTRB(
          _colX(offset.dx, i),
          offset.dy,
          _colX(offset.dx, i + span),
          offset.dy + cellHeight,
        );
        _paintCellForeground(
          canvas,
          offset.translate(i * cellWidth, 0),
          cellRect,
          cellData,
        );
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  /// 返回该行是否包含实心 Powerline 字形，普通输出行可零开销跳过第二遍扫描。
  bool _paintLineBackground(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    CellData cellData,
  ) {
    Color? runColor;
    var runStart = 0;
    var runEnd = 0;
    var hasSolidPowerline = false;

    void flush() {
      final color = runColor;
      if (color == null) return;
      _backgroundPaint.color = color;
      canvas.drawRect(
        Rect.fromLTRB(
          _colX(offset.dx, runStart),
          offset.dy,
          _colX(offset.dx, runEnd),
          offset.dy + _cellSize.height,
        ),
        _backgroundPaint,
      );
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final span = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
      if (!hasSolidPowerline &&
          span == 1 &&
          cellData.text == null &&
          TerminalCustomGlyphs.isSolidPowerline(
            cellData.content & CellContent.codepointMask,
          )) {
        hasSolidPowerline = true;
      }
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
    return hasSolidPowerline;
  }

  void _paintSolidPowerlineRuns(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    CellData cellData,
  ) {
    final neighbor = CellData.empty();
    final top = offset.dy;
    final bottom = offset.dy + _cellSize.height;

    // 左衔接字形（    等）从右向左绘制：右侧字形先向左侧同色背景微幅搭接，
    // 再由左侧字形的尖端/圆弧覆盖在其上，既消除接缝又绝不切尖。
    for (var i = line.length - 1; i >= 0; i--) {
      line.getCellData(i, cellData);
      if (cellData.text != null ||
          cellData.flags & CellFlags.invisible != 0 ||
          cellData.content >> CellContent.widthShift == 2) {
        continue;
      }
      final cp = cellData.content & CellContent.codepointMask;
      if (!TerminalCustomGlyphs.isLeftJoiningPowerline(cp)) continue;
      final fg = _effectiveForegroundArgb(cellData);
      final left = _colX(offset.dx, i);
      final right = _colX(offset.dx, i + 1);
      double? joinLeft;
      if (i > 0) {
        line.getCellData(i - 1, neighbor);
        if (cellBackgroundColor(neighbor)?.toARGB32() == fg) {
          joinLeft = left - 0.5;
        }
      }
      _customGlyphs.paintSolidPowerline(
        canvas,
        Rect.fromLTRB(left, top, right, bottom),
        cp,
        Color(fg),
        joinLeft: joinLeft,
      );
    }

    // 右衔接字形（    等）从左向右绘制，对称处理。
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      if (cellData.text != null ||
          cellData.flags & CellFlags.invisible != 0 ||
          cellData.content >> CellContent.widthShift == 2) {
        continue;
      }
      final cp = cellData.content & CellContent.codepointMask;
      if (!TerminalCustomGlyphs.isRightJoiningPowerline(cp)) continue;
      final fg = _effectiveForegroundArgb(cellData);
      final left = _colX(offset.dx, i);
      final right = _colX(offset.dx, i + 1);
      double? joinRight;
      if (i + 1 < line.length) {
        line.getCellData(i + 1, neighbor);
        if (cellBackgroundColor(neighbor)?.toARGB32() == fg) {
          joinRight = right + 0.5;
        }
      }
      _customGlyphs.paintSolidPowerline(
        canvas,
        Rect.fromLTRB(left, top, right, bottom),
        cp,
        Color(fg),
        joinRight: joinRight,
      );
    }
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
    final span = cellData.content >> CellContent.widthShift == 2 ? 2 : 1;
    final left = offset.dx.roundToDouble();
    final right = (offset.dx + _cellSize.width * span).roundToDouble();
    _paintCellForeground(
      canvas,
      offset,
      Rect.fromLTRB(left, offset.dy, right, offset.dy + _cellSize.height),
      cellData,
    );
  }

  @pragma('vm:prefer-inline')
  int _effectiveForegroundArgb(CellData cellData) {
    final cellFlags = cellData.flags;
    var color = cellFlags & CellFlags.inverse == 0
        ? _colorValue(cellData.foreground, _theme.foreground)
        : _colorValue(cellData.background, _theme.background);
    if (cellFlags & CellFlags.faint != 0) {
      color = (color & 0x00FFFFFF) | 0x80000000;
    }
    return color;
  }

  void _paintCellDecorations(Canvas canvas, Rect cellRect, CellData cellData) {
    final cellFlags = cellData.flags;
    if (cellFlags & CellFlags.invisible != 0) return;
    final hasUnderline = cellFlags & CellFlags.underline != 0;
    final hasStrike = cellFlags & CellFlags.strikethrough != 0;
    if (!hasUnderline && !hasStrike) return;
    final paint = _decorationPaint
      ..color = Color(_effectiveForegroundArgb(cellData))
      ..style = PaintingStyle.stroke;
    if (hasUnderline) {
      final y = cellRect.bottom - 1;
      canvas.drawLine(
        Offset(cellRect.left, y),
        Offset(cellRect.right, y),
        paint,
      );
    }
    if (hasStrike) {
      final y = cellRect.top + cellRect.height * 0.5;
      canvas.drawLine(
        Offset(cellRect.left, y),
        Offset(cellRect.right, y),
        paint,
      );
    }
  }

  void _paintCellForeground(
    Canvas canvas,
    Offset offset,
    Rect cellRect,
    CellData cellData,
  ) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cellFlags = cellData.flags;
    if (cellFlags & CellFlags.invisible != 0) return;

    final color = _effectiveForegroundArgb(cellData);
    final cluster = cellData.text;
    final isSingleWidth = cellData.content >> CellContent.widthShift != 2;
    if (cluster == null &&
        isSingleWidth &&
        TerminalCustomGlyphs.isCustomGlyph(charCode)) {
      _customGlyphs.paintGlyph(canvas, cellRect, charCode, Color(color));
      _paintCellDecorations(canvas, cellRect, cellData);
      return;
    }

    final styleFlags =
        (cellFlags & CellFlags.bold != 0 ? ParagraphCache.bold : 0) |
        (cellFlags & CellFlags.italic != 0 ? ParagraphCache.italic : 0) |
        (cellFlags & CellFlags.underline != 0 ? ParagraphCache.underline : 0) |
        (cellFlags & CellFlags.strikethrough != 0
            ? ParagraphCache.strikethrough
            : 0);

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
        strikethrough: styleFlags & ParagraphCache.strikethrough != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = cluster ?? String.fromCharCode(charCode);
      if ((styleFlags &
                  (ParagraphCache.underline | ParagraphCache.strikethrough)) !=
              0 &&
          charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      final laidOut = ParagraphCache.layout(
        char,
        style,
        _textScaler,
        paragraphStyle: _paragraphStyle,
      );
      paragraph = cluster == null
          ? _paragraphCache.putGlyph(glyphKey, laidOut)
          : _paragraphCache.putCluster(cluster, clusterStyle, laidOut);
    }

    final dy = ((_cellSize.height - paragraph.height) * 0.5).clamp(
      0.0,
      _cellSize.height,
    );
    canvas.drawParagraph(paragraph, offset.translate(0, dy));
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
    final left = offset.dx.roundToDouble();
    final right = (offset.dx + _cellSize.width * widthScale).roundToDouble();
    canvas.drawRect(
      Rect.fromLTRB(left, offset.dy, right, offset.dy + _cellSize.height),
      paint,
    );
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
