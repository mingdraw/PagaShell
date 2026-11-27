import 'dart:math' as math;
import 'dart:ui';

/// 终端几何字形绘制器：Powerline、块元素与制表符。
///
/// 字体中的 Powerline/制表符受字面高度、负左支承与小数像素舍入影响，
/// 容易在背景色块上下露出锯齿、切掉连续箭头尖端或出现行列缝隙。
/// 直接按单元格精确矩形绘制矢量路径，可在任意字号、行高与 DPI 下严丝合缝。
class TerminalCustomGlyphs {
  TerminalCustomGlyphs();

  final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.miter;

  /// 是否由内置矢量绘制接管（单码点单元格，不含组合字符）。
  @pragma('vm:prefer-inline')
  static bool isCustomGlyph(int codepoint) =>
      (codepoint >= 0x2500 && codepoint <= 0x259F) ||
      (codepoint >= 0xE0B0 && codepoint <= 0xE0BF) ||
      codepoint == 0xE0D2 ||
      codepoint == 0xE0D4 ||
      codepoint == 0xE0D6 ||
      codepoint == 0xE0D7;

  /// 实心 Powerline 分隔符：在普通文字之前绘制，既可微幅搭接同色背景消除
  /// 亚像素缝隙，也不会遮挡相邻单元格的文字或图标。
  @pragma('vm:prefer-inline')
  static bool isSolidPowerline(int codepoint) => switch (codepoint) {
    0xE0B0 ||
    0xE0B2 ||
    0xE0B4 ||
    0xE0B6 ||
    0xE0B8 ||
    0xE0BA ||
    0xE0BC ||
    0xE0BE ||
    0xE0D2 ||
    0xE0D4 ||
    0xE0D6 ||
    0xE0D7 => true,
    _ => false,
  };

  /// 平直边在左侧、与前一格背景衔接的实心 Powerline 字形。
  @pragma('vm:prefer-inline')
  static bool isLeftJoiningPowerline(int codepoint) => switch (codepoint) {
    0xE0B0 || 0xE0B4 || 0xE0B8 || 0xE0BC || 0xE0D2 || 0xE0D6 => true,
    _ => false,
  };

  /// 平直边在右侧、与后一格背景衔接的实心 Powerline 字形。
  @pragma('vm:prefer-inline')
  static bool isRightJoiningPowerline(int codepoint) => switch (codepoint) {
    0xE0B2 || 0xE0B6 || 0xE0BA || 0xE0BE || 0xE0D4 || 0xE0D7 => true,
    _ => false,
  };

  /// 绘制实心 Powerline 字形。
  ///
  /// [joinLeft] 与 [joinRight] 允许在相邻单元格背景与前景同色时将平直边微幅
  /// 延伸进相邻单元格背景中，防止 125%/150% 等非整数缩放下的抗锯齿发丝缝。
  void paintSolidPowerline(
    Canvas canvas,
    Rect cell,
    int codepoint,
    Color color, {
    double? joinLeft,
    double? joinRight,
  }) {
    final l = cell.left;
    final t = cell.top;
    final r = cell.right;
    final b = cell.bottom;
    final w = cell.width;
    final h = cell.height;
    final cy = t + h * 0.5;
    final jl = joinLeft ?? l;
    final jr = joinRight ?? r;

    final path = Path();
    switch (codepoint) {
      case 0xE0B0: //  right-pointing solid triangle
        path
          ..moveTo(jl, t)
          ..lineTo(l, t)
          ..lineTo(r, cy)
          ..lineTo(l, b)
          ..lineTo(jl, b)
          ..close();
      case 0xE0B2: //  left-pointing solid triangle
        path
          ..moveTo(jr, t)
          ..lineTo(r, t)
          ..lineTo(l, cy)
          ..lineTo(r, b)
          ..lineTo(jr, b)
          ..close();
      case 0xE0B4: //  right half circle
        path
          ..moveTo(jl, t)
          ..lineTo(l, t)
          ..arcTo(Rect.fromLTRB(l - w, t, r, b), -math.pi / 2, math.pi, false)
          ..lineTo(jl, b)
          ..close();
      case 0xE0B6: //  left half circle
        path
          ..moveTo(jr, b)
          ..lineTo(r, b)
          ..arcTo(Rect.fromLTRB(l, t, r + w, b), math.pi / 2, math.pi, false)
          ..lineTo(jr, t)
          ..close();
      case 0xE0B8: //  lower-left triangle
        path
          ..moveTo(jl, t)
          ..lineTo(l, t)
          ..lineTo(r, b)
          ..lineTo(jl, b)
          ..close();
      case 0xE0BA: //  lower-right triangle
        path
          ..moveTo(jr, t)
          ..lineTo(r, t)
          ..lineTo(l, b)
          ..lineTo(jr, b)
          ..close();
      case 0xE0BC: //  upper-left triangle
        path
          ..moveTo(jl, t)
          ..lineTo(r, t)
          ..lineTo(l, b)
          ..lineTo(jl, b)
          ..close();
      case 0xE0BE: //  upper-right triangle
        path
          ..moveTo(jr, t)
          ..lineTo(l, t)
          ..lineTo(r, b)
          ..lineTo(jr, b)
          ..close();
      case 0xE0D2: //  trapezoid right-cut
        final gap = math.max(0.75, h * 0.04);
        final notchX = l + w * 0.22;
        path
          ..moveTo(jl, t)
          ..lineTo(r, t)
          ..lineTo(notchX, cy - gap)
          ..lineTo(jl, cy - gap)
          ..close()
          ..moveTo(jl, cy + gap)
          ..lineTo(notchX, cy + gap)
          ..lineTo(r, b)
          ..lineTo(jl, b)
          ..close();
      case 0xE0D4: //  trapezoid left-cut
        final gap = math.max(0.75, h * 0.04);
        final notchX = r - w * 0.22;
        path
          ..moveTo(jr, t)
          ..lineTo(l, t)
          ..lineTo(notchX, cy - gap)
          ..lineTo(jr, cy - gap)
          ..close()
          ..moveTo(jr, cy + gap)
          ..lineTo(notchX, cy + gap)
          ..lineTo(l, b)
          ..lineTo(jr, b)
          ..close();
      case 0xE0D6: //  inverse right triangle
        path
          ..moveTo(jl, t)
          ..lineTo(r, t)
          ..lineTo(l, cy)
          ..lineTo(r, b)
          ..lineTo(jl, b)
          ..close();
      case 0xE0D7: //  inverse left triangle
        path
          ..moveTo(jr, t)
          ..lineTo(l, t)
          ..lineTo(r, cy)
          ..lineTo(l, b)
          ..lineTo(jr, b)
          ..close();
      default:
        return;
    }

    _fillPaint
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(path, _fillPaint);
  }

  /// 绘制前景几何字形（细线 Powerline、块元素、制表符；也兼容单格实心 Powerline）。
  void paintGlyph(Canvas canvas, Rect cell, int codepoint, Color color) {
    if (isSolidPowerline(codepoint)) {
      paintSolidPowerline(canvas, cell, codepoint, color);
      return;
    }
    if (codepoint >= 0xE0B0 && codepoint <= 0xE0BF) {
      _paintThinPowerline(canvas, cell, codepoint, color);
      return;
    }
    if (codepoint >= 0x2580 && codepoint <= 0x259F) {
      _paintBlockElement(canvas, cell, codepoint, color);
      return;
    }
    if (codepoint >= 0x2500 && codepoint <= 0x257F) {
      _paintBoxDrawing(canvas, cell, codepoint, color);
    }
  }

  void _paintThinPowerline(
    Canvas canvas,
    Rect cell,
    int codepoint,
    Color color,
  ) {
    final l = cell.left;
    final t = cell.top;
    final r = cell.right;
    final b = cell.bottom;
    final w = cell.width;
    final cy = t + cell.height * 0.5;
    final stroke = _lightStroke(w);
    final half = stroke * 0.5;

    final path = Path();
    switch (codepoint) {
      case 0xE0B1: //  thin right chevron
        path
          ..moveTo(l, t)
          ..lineTo(r - half, cy)
          ..lineTo(l, b);
      case 0xE0B3: //  thin left chevron
        path
          ..moveTo(r, t)
          ..lineTo(l + half, cy)
          ..lineTo(r, b);
      case 0xE0B5: //  thin right half circle
        path.addArc(
          Rect.fromLTRB(l - w + half, t + half, r - half, b - half),
          -math.pi / 2,
          math.pi,
        );
      case 0xE0B7: //  thin left half circle
        path.addArc(
          Rect.fromLTRB(l + half, t + half, r + w - half, b - half),
          math.pi / 2,
          math.pi,
        );
      case 0xE0B9: //  backslash
      case 0xE0BF: //  backslash
        path
          ..moveTo(l, t)
          ..lineTo(r, b);
      case 0xE0BB: //  forward slash
      case 0xE0BD: //  forward slash
        path
          ..moveTo(r, t)
          ..lineTo(l, b);
      default:
        return;
    }

    _strokePaint
      ..color = color
      ..strokeWidth = stroke
      ..isAntiAlias = true;
    canvas
      ..save()
      ..clipRect(cell)
      ..drawPath(path, _strokePaint)
      ..restore();
  }

  void _paintBlockElement(
    Canvas canvas,
    Rect cell,
    int codepoint,
    Color color,
  ) {
    final l = cell.left;
    final t = cell.top;
    final r = cell.right;
    final b = cell.bottom;
    final w = cell.width;
    final h = cell.height;
    final cx = ((l + r) * 0.5).roundToDouble();
    final cy = ((t + b) * 0.5).roundToDouble();

    _fillPaint
      ..color = color
      ..isAntiAlias = false;

    void fill(double left, double top, double right, double bottom) {
      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), _fillPaint);
    }

    if (codepoint == 0x2580) {
      fill(l, t, r, cy);
      return;
    }
    if (codepoint >= 0x2581 && codepoint <= 0x2588) {
      final eighths = codepoint - 0x2580;
      final top = eighths == 8 ? t : (b - h * eighths / 8).roundToDouble();
      fill(l, top, r, b);
      return;
    }
    if (codepoint >= 0x2589 && codepoint <= 0x258F) {
      final eighths = 0x2590 - codepoint;
      final right = (l + w * eighths / 8).roundToDouble();
      fill(l, t, right, b);
      return;
    }
    switch (codepoint) {
      case 0x2590: // ▐ right half
        fill(cx, t, r, b);
      case 0x2591: // ░ light shade
        _fillPaint.color = color.withValues(alpha: color.a * 0.25);
        fill(l, t, r, b);
      case 0x2592: // ▒ medium shade
        _fillPaint.color = color.withValues(alpha: color.a * 0.50);
        fill(l, t, r, b);
      case 0x2593: // ▓ dark shade
        _fillPaint.color = color.withValues(alpha: color.a * 0.75);
        fill(l, t, r, b);
      case 0x2594: // ▔ upper one eighth
        fill(l, t, r, math.max(t + 1, (t + h / 8).roundToDouble()));
      case 0x2595: // ▕ right one eighth
        fill(math.min(r - 1, (r - w / 8).roundToDouble()), t, r, b);
      default:
        final mask = _quadrantMask(codepoint);
        if (mask & 1 != 0) fill(l, t, cx, cy);
        if (mask & 2 != 0) fill(cx, t, r, cy);
        if (mask & 4 != 0) fill(l, cy, cx, b);
        if (mask & 8 != 0) fill(cx, cy, r, b);
    }
  }

  static int _quadrantMask(int codepoint) => switch (codepoint) {
    0x2596 => 4, // ▖ LL
    0x2597 => 8, // ▗ LR
    0x2598 => 1, // ▘ UL
    0x2599 => 1 | 4 | 8, // ▙ UL+LL+LR
    0x259A => 1 | 8, // ▚ UL+LR
    0x259B => 1 | 2 | 4, // ▛ UL+UR+LL
    0x259C => 1 | 2 | 8, // ▜ UL+UR+LR
    0x259D => 2, // ▝ UR
    0x259E => 2 | 4, // ▞ UR+LL
    0x259F => 2 | 4 | 8, // ▟ UR+LL+LR
    _ => 0,
  };

  void _paintBoxDrawing(Canvas canvas, Rect cell, int codepoint, Color color) {
    final l = cell.left;
    final t = cell.top;
    final r = cell.right;
    final b = cell.bottom;
    final w = cell.width;
    final h = cell.height;
    final lw = _lightStroke(w);
    final hw = lw * 2;
    // 线中心对齐像素中点或整数边界，保证单像素线不模糊且相邻格对齐。
    final cx = l + (w * 0.5).floorToDouble() + (lw.isOddInt ? 0.5 : 0.0);
    final cy = t + (h * 0.5).floorToDouble() + (lw.isOddInt ? 0.5 : 0.0);

    final mask = _boxArmTable[codepoint - 0x2500];
    if (mask != 0) {
      _paintBoxArms(canvas, l, t, r, b, cx, cy, lw, hw, w, mask, color);
      return;
    }

    switch (codepoint) {
      // 圆角制表符（Starship 多行提示符常用 ╭─ / ╰─）
      case 0x256D: // ╭ down and right
        _paintArc(canvas, cell, cx, b, cx, cy, r, cy, lw, color);
      case 0x256E: // ╮ down and left
        _paintArc(canvas, cell, cx, b, cx, cy, l, cy, lw, color);
      case 0x256F: // ╯ up and left
        _paintArc(canvas, cell, cx, t, cx, cy, l, cy, lw, color);
      case 0x2570: // ╰ up and right
        _paintArc(canvas, cell, cx, t, cx, cy, r, cy, lw, color);
      // 对角线
      case 0x2571: // ╱
        _paintDiagonal(canvas, cell, r, t, l, b, lw, color);
      case 0x2572: // ╲
        _paintDiagonal(canvas, cell, l, t, r, b, lw, color);
      case 0x2573: // ╳
        _paintDiagonal(canvas, cell, r, t, l, b, lw, color);
        _paintDiagonal(canvas, cell, l, t, r, b, lw, color);
      // 虚线
      case 0x2504: // ┄ light triple dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 3, lw, color, horizontal: true);
      case 0x2505: // ┅ heavy triple dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 3, hw, color, horizontal: true);
      case 0x2506: // ┆ light triple dash vertical
        _paintDashed(canvas, cx, t, cx, b, 3, lw, color, horizontal: false);
      case 0x2507: // ┇ heavy triple dash vertical
        _paintDashed(canvas, cx, t, cx, b, 3, hw, color, horizontal: false);
      case 0x2508: // ┈ light quadruple dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 4, lw, color, horizontal: true);
      case 0x2509: // ┉ heavy quadruple dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 4, hw, color, horizontal: true);
      case 0x250A: // ┊ light quadruple dash vertical
        _paintDashed(canvas, cx, t, cx, b, 4, lw, color, horizontal: false);
      case 0x250B: // ┋ heavy quadruple dash vertical
        _paintDashed(canvas, cx, t, cx, b, 4, hw, color, horizontal: false);
      case 0x254C: // ╌ light double dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 2, lw, color, horizontal: true);
      case 0x254D: // ╍ heavy double dash horizontal
        _paintDashed(canvas, l, cy, r, cy, 2, hw, color, horizontal: true);
      case 0x254E: // ╎ light double dash vertical
        _paintDashed(canvas, cx, t, cx, b, 2, lw, color, horizontal: false);
      case 0x254F: // ╏ heavy double dash vertical
        _paintDashed(canvas, cx, t, cx, b, 2, hw, color, horizontal: false);
    }
  }

  void _paintBoxArms(
    Canvas canvas,
    double l,
    double t,
    double r,
    double b,
    double cx,
    double cy,
    double lw,
    double hw,
    double cellWidth,
    int mask,
    Color color,
  ) {
    final left = mask & 3;
    final right = (mask >> 2) & 3;
    final up = (mask >> 4) & 3;
    final down = (mask >> 6) & 3;

    _fillPaint
      ..color = color
      ..isAntiAlias = false;

    double strokeFor(int style) => style == 2 ? hw : lw;
    final doubleOffset = math.max(lw + 1.0, (cellWidth * 0.22).roundToDouble());

    void hBar(double x0, double x1, double centerY, double thickness) {
      final half = thickness * 0.5;
      canvas.drawRect(
        Rect.fromLTRB(x0, centerY - half, x1, centerY + half),
        _fillPaint,
      );
    }

    void vBar(double centerX, double y0, double y1, double thickness) {
      final half = thickness * 0.5;
      canvas.drawRect(
        Rect.fromLTRB(centerX - half, y0, centerX + half, y1),
        _fillPaint,
      );
    }

    final hasDoubleV = up == 3 || down == 3;
    final hasDoubleH = left == 3 || right == 3;
    final vSpanHalf = hasDoubleV
        ? doubleOffset + lw * 0.5
        : (up == 2 || down == 2
              ? hw * 0.5
              : (up != 0 || down != 0 ? lw * 0.5 : 0.0));
    final hSpanHalf = hasDoubleH
        ? doubleOffset + lw * 0.5
        : (left == 2 || right == 2
              ? hw * 0.5
              : (left != 0 || right != 0 ? lw * 0.5 : 0.0));

    // 左臂
    if (left == 3) {
      final topEnd = up == 3
          ? cx - doubleOffset + lw * 0.5
          : (down == 3 ? cx + doubleOffset + lw * 0.5 : cx + vSpanHalf);
      final botEnd = down == 3
          ? cx - doubleOffset + lw * 0.5
          : (up == 3 ? cx + doubleOffset + lw * 0.5 : cx + vSpanHalf);
      hBar(l, topEnd, cy - doubleOffset, lw);
      hBar(l, botEnd, cy + doubleOffset, lw);
    } else if (left != 0) {
      final end = hasDoubleV && right == 0
          ? cx - doubleOffset + lw * 0.5
          : cx + vSpanHalf;
      hBar(l, end, cy, strokeFor(left));
    }

    // 右臂
    if (right == 3) {
      final topStart = up == 3
          ? cx + doubleOffset - lw * 0.5
          : (down == 3 ? cx - doubleOffset - lw * 0.5 : cx - vSpanHalf);
      final botStart = down == 3
          ? cx + doubleOffset - lw * 0.5
          : (up == 3 ? cx - doubleOffset - lw * 0.5 : cx - vSpanHalf);
      hBar(topStart, r, cy - doubleOffset, lw);
      hBar(botStart, r, cy + doubleOffset, lw);
    } else if (right != 0) {
      final start = hasDoubleV && left == 0
          ? cx + doubleOffset - lw * 0.5
          : cx - vSpanHalf;
      hBar(start, r, cy, strokeFor(right));
    }

    // 上臂
    if (up == 3) {
      final leftEnd = left == 3
          ? cy - doubleOffset + lw * 0.5
          : (right == 3 ? cy + doubleOffset + lw * 0.5 : cy + hSpanHalf);
      final rightEnd = right == 3
          ? cy - doubleOffset + lw * 0.5
          : (left == 3 ? cy + doubleOffset + lw * 0.5 : cy + hSpanHalf);
      vBar(cx - doubleOffset, t, leftEnd, lw);
      vBar(cx + doubleOffset, t, rightEnd, lw);
    } else if (up != 0) {
      final end = hasDoubleH && down == 0
          ? cy - doubleOffset + lw * 0.5
          : cy + hSpanHalf;
      vBar(cx, t, end, strokeFor(up));
    }

    // 下臂
    if (down == 3) {
      final leftStart = left == 3
          ? cy + doubleOffset - lw * 0.5
          : (right == 3 ? cy - doubleOffset - lw * 0.5 : cy - hSpanHalf);
      final rightStart = right == 3
          ? cy + doubleOffset - lw * 0.5
          : (left == 3 ? cy - doubleOffset - lw * 0.5 : cy - hSpanHalf);
      vBar(cx - doubleOffset, leftStart, b, lw);
      vBar(cx + doubleOffset, rightStart, b, lw);
    } else if (down != 0) {
      final start = hasDoubleH && up == 0
          ? cy + doubleOffset - lw * 0.5
          : cy - hSpanHalf;
      vBar(cx, start, b, strokeFor(down));
    }
  }

  void _paintArc(
    Canvas canvas,
    Rect cell,
    double x0,
    double y0,
    double cx,
    double cy,
    double x1,
    double y1,
    double strokeWidth,
    Color color,
  ) {
    final radius = math.min((cx - x1).abs(), (cy - y0).abs());
    final sy = y0 < cy ? cy - radius : cy + radius;
    final ex = x1 < cx ? cx - radius : cx + radius;
    final path = Path()
      ..moveTo(x0, y0)
      ..lineTo(cx, sy)
      ..quadraticBezierTo(cx, cy, ex, cy)
      ..lineTo(x1, y1);
    _strokePaint
      ..color = color
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas
      ..save()
      ..clipRect(cell)
      ..drawPath(path, _strokePaint)
      ..restore();
  }

  void _paintDiagonal(
    Canvas canvas,
    Rect cell,
    double x0,
    double y0,
    double x1,
    double y1,
    double strokeWidth,
    Color color,
  ) {
    _strokePaint
      ..color = color
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas
      ..save()
      ..clipRect(cell)
      ..drawLine(Offset(x0, y0), Offset(x1, y1), _strokePaint)
      ..restore();
  }

  void _paintDashed(
    Canvas canvas,
    double x0,
    double y0,
    double x1,
    double y1,
    int segments,
    double thickness,
    Color color, {
    required bool horizontal,
  }) {
    _fillPaint
      ..color = color
      ..isAntiAlias = false;
    final half = thickness * 0.5;
    if (horizontal) {
      final total = x1 - x0;
      final step = total / segments;
      final dash = math.max(1.0, (step * 0.6).roundToDouble());
      for (var i = 0; i < segments; i++) {
        final start = (x0 + i * step).roundToDouble();
        final end = math.min(x1, start + dash);
        canvas.drawRect(
          Rect.fromLTRB(start, y0 - half, end, y0 + half),
          _fillPaint,
        );
      }
    } else {
      final total = y1 - y0;
      final step = total / segments;
      final dash = math.max(1.0, (step * 0.6).roundToDouble());
      for (var i = 0; i < segments; i++) {
        final start = (y0 + i * step).roundToDouble();
        final end = math.min(y1, start + dash);
        canvas.drawRect(
          Rect.fromLTRB(x0 - half, start, x0 + half, end),
          _fillPaint,
        );
      }
    }
  }

  static double _lightStroke(double cellWidth) =>
      math.max(1.0, (cellWidth / 8).roundToDouble());

  // U+2500..U+257F 每格 8 位：L(0..1), R(2..3), U(4..5), D(6..7)
  // 0=无, 1=细线, 2=粗线, 3=双线；0x00 表示虚线/圆角/对角线特殊字形。
  static const List<int> _boxArmTable = <int>[
    0x05,
    0x0A,
    0x50,
    0xA0,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x44,
    0x48,
    0x84,
    0x88,
    0x41,
    0x42,
    0x81,
    0x82,
    0x14,
    0x18,
    0x24,
    0x28,
    0x11,
    0x12,
    0x21,
    0x22,
    0x54,
    0x58,
    0x64,
    0x94,
    0xA4,
    0x68,
    0x98,
    0xA8,
    0x51,
    0x52,
    0x61,
    0x91,
    0xA1,
    0x62,
    0x92,
    0xA2,
    0x45,
    0x46,
    0x49,
    0x4A,
    0x85,
    0x86,
    0x89,
    0x8A,
    0x15,
    0x16,
    0x19,
    0x1A,
    0x25,
    0x26,
    0x29,
    0x2A,
    0x55,
    0x56,
    0x59,
    0x5A,
    0x65,
    0x95,
    0xA5,
    0x66,
    0x69,
    0x96,
    0x99,
    0x6A,
    0x9A,
    0xA6,
    0xA9,
    0xAA,
    0x00,
    0x00,
    0x00,
    0x00,
    0x0F,
    0xF0,
    0x4C,
    0xC4,
    0xCC,
    0x43,
    0xC1,
    0xC3,
    0x1C,
    0x34,
    0x3C,
    0x13,
    0x31,
    0x33,
    0x5C,
    0xF4,
    0xFC,
    0x53,
    0xF1,
    0xF3,
    0x4F,
    0xC5,
    0xCF,
    0x1F,
    0x35,
    0x3F,
    0x5F,
    0xF5,
    0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x10,
    0x04,
    0x40,
    0x02,
    0x20,
    0x08,
    0x80,
    0x09,
    0x90,
    0x06,
    0x60,
  ];
}

extension on double {
  bool get isOddInt => round().isOdd;
}
