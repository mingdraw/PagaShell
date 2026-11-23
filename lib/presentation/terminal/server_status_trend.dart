import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../theme/app_theme.dart';

/// Compact live area trend chart for server metrics.
///
/// The latest samples are on the right. The same scale is used for both
/// directions of I/O; internal gaps are kept where a baseline was unavailable,
/// while leading all-null slots (such as the initial Linux CPU delta) are
/// trimmed so the curve uses the full width cleanly.
class ServerStatusTrend extends StatefulWidget {
  const ServerStatusTrend({
    required this.series,
    required this.colors,
    this.upperBound,
    this.peakLabel,
    this.valueFormatter,
    super.key,
  });

  final List<List<double?>> series;
  final List<Color> colors;
  final double? upperBound;
  final String Function(double maximum)? peakLabel;
  final String Function(double value)? valueFormatter;

  @override
  State<ServerStatusTrend> createState() => _ServerStatusTrendState();
}

class _ServerStatusTrendState extends State<ServerStatusTrend> {
  static const _chartHeight = 46.0;
  static const _horizontalPad = 5.0;
  static const _figures = [FontFeature.tabularFigures()];
  int? _hoveredIndex;

  List<List<double?>> _trimmedSeries() {
    if (widget.series.isEmpty) return const [];
    final length = widget.series.first.length;
    var firstValid = 0;
    while (firstValid < length &&
        widget.series.every((line) {
          if (firstValid >= line.length) return true;
          final value = line[firstValid];
          return value == null || !value.isFinite;
        })) {
      firstValid++;
    }
    if (firstValid == 0) return widget.series;
    return [
      for (final line in widget.series)
        firstValid >= line.length
            ? const <double?>[]
            : line.sublist(firstValid),
    ];
  }

  void _updateHover(Offset localPosition, double width, int count) {
    if (count < 2 || width <= _horizontalPad * 2) return;
    final usable = width - _horizontalPad * 2;
    final ratio = ((localPosition.dx - _horizontalPad) / usable).clamp(
      0.0,
      1.0,
    );
    final index = (ratio * (count - 1)).round().clamp(0, count - 1);
    if (index != _hoveredIndex) {
      setState(() => _hoveredIndex = index);
    }
  }

  Widget _hoverReadout(List<List<double?>> series, int index) {
    final format = widget.valueFormatter;
    if (format == null) return _trendTitle();
    final items = <(Color, String)>[];
    for (var i = 0; i < series.length; i++) {
      final line = series[i];
      if (index >= line.length) continue;
      final value = line[index];
      if (value == null || !value.isFinite) continue;
      items.add((widget.colors[i], format(value)));
    }
    if (items.isEmpty) return _trendTitle();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: items[i].$1,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              items[i].$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.terminalForeground,
                fontFeatures: _figures,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _trendTitle() => Text(
    '趋势'.tr,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontSize: 10,
      color: AppTheme.terminalMutedForeground,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final series = _trimmedSeries();
    if (!series.any(
      (line) => line.whereType<double>().where((v) => v.isFinite).length >= 2,
    )) {
      return const SizedBox.shrink();
    }
    final sampleCount = series.first.length;
    final observedMax = series
        .expand(
          (line) => line.whereType<double>().where((value) => value.isFinite),
        )
        .fold<double>(0.0, math.max);
    final scaleMax = widget.upperBound ?? observedMax;
    final activeHover = _hoveredIndex?.clamp(0, sampleCount - 1);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        image: true,
        label: '最近 @count 次采样趋势'.trParams({'count': '$sampleCount'}),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: activeHover == null
                      ? _trendTitle()
                      : _hoverReadout(series, activeHover),
                ),
                if (widget.peakLabel case final label?) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label(observedMax),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppTheme.terminalMutedForeground,
                        fontFeatures: _figures,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            Container(
              height: _chartHeight,
              decoration: BoxDecoration(
                color: AppTheme.terminalControlBackground.withValues(
                  alpha: 0.55,
                ),
                border: Border.all(
                  color: AppTheme.terminalBorder.withValues(alpha: 0.85),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LayoutBuilder(
                  builder: (context, constraints) => MouseRegion(
                    onHover: (event) => _updateHover(
                      event.localPosition,
                      constraints.maxWidth,
                      sampleCount,
                    ),
                    onExit: (_) {
                      if (_hoveredIndex != null) {
                        setState(() => _hoveredIndex = null);
                      }
                    },
                    child: CustomPaint(
                      painter: _TrendPainter(
                        series: series,
                        colors: widget.colors,
                        scaleMax: scaleMax,
                        hoveredIndex: activeHover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.series,
    required this.colors,
    required this.scaleMax,
    required this.hoveredIndex,
  });

  final List<List<double?>> series;
  final List<Color> colors;
  final double scaleMax;
  final int? hoveredIndex;

  static const _leftPad = 5.0;
  static const _rightPad = 6.0;
  static const _topPad = 6.0;
  static const _bottomPad = 4.0;

  double _xFor(int index, int count, double width) {
    final usable = math.max(1.0, width - _leftPad - _rightPad);
    return _leftPad + usable * index / (count - 1);
  }

  double _yFor(double value, double height) {
    final bottom = height - _bottomPad;
    final usable = math.max(1.0, bottom - _topPad);
    final ratio = scaleMax <= 0 ? 0.0 : (value / scaleMax).clamp(0.0, 1.0);
    return bottom - usable * ratio;
  }

  void _paintDashedLine(Canvas canvas, double y, double width) {
    final paint = Paint()
      ..color = AppTheme.terminalBorder.withValues(alpha: 0.85)
      ..strokeWidth = 0.75;
    const dash = 3.0;
    const gap = 3.0;
    var x = _leftPad;
    final end = width - _rightPad;
    while (x < end) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, end), y), paint);
      x += dash + gap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final bottom = size.height - _bottomPad;
    final midY = _topPad + (bottom - _topPad) / 2;

    // Reference guides: 50% dashed midline and subtle bottom baseline.
    _paintDashedLine(canvas, midY, size.width);
    canvas.drawLine(
      Offset(_leftPad, bottom),
      Offset(size.width - _rightPad, bottom),
      Paint()
        ..color = AppTheme.terminalBorder.withValues(alpha: 0.55)
        ..strokeWidth = 0.75,
    );

    final multiSeries = series.length > 1;
    final fillTopAlpha = multiSeries ? 0.20 : 0.28;

    for (var i = 0; i < series.length; i++) {
      final values = series[i];
      if (values.length < 2) continue;
      final color = colors[i];
      final strokePath = Path();
      final fillPath = Path();
      double? segmentStartX;
      double? lastSegmentX;
      Offset? latestPoint;

      void closeSegment() {
        final start = segmentStartX;
        final last = lastSegmentX;
        if (start != null && last != null) {
          fillPath
            ..lineTo(last, bottom)
            ..lineTo(start, bottom)
            ..close();
        }
        segmentStartX = null;
        lastSegmentX = null;
      }

      for (var j = 0; j < values.length; j++) {
        final value = values[j];
        if (value == null || !value.isFinite) {
          closeSegment();
          continue;
        }
        final x = _xFor(j, values.length, size.width);
        final y = _yFor(value, size.height);
        latestPoint = Offset(x, y);
        if (segmentStartX == null) {
          segmentStartX = x;
          strokePath.moveTo(x, y);
          fillPath.moveTo(x, y);
        } else {
          strokePath.lineTo(x, y);
          fillPath.lineTo(x, y);
        }
        lastSegmentX = x;
      }
      closeSegment();

      canvas.drawPath(
        fillPath,
        Paint()
          ..style = PaintingStyle.fill
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: fillTopAlpha),
              color.withValues(alpha: 0.02),
            ],
          ).createShader(Rect.fromLTRB(0, _topPad, size.width, bottom)),
      );
      canvas.drawPath(
        strokePath,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.75
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      // Highlight latest live sample when not hovering another slot.
      if (hoveredIndex == null && latestPoint != null) {
        canvas.drawCircle(
          latestPoint,
          4.0,
          Paint()..color = color.withValues(alpha: 0.24),
        );
        canvas.drawCircle(latestPoint, 2.2, Paint()..color = color);
      }
    }

    if (hoveredIndex case final hover?) {
      final count = series.first.length;
      if (count >= 2 && hover < count) {
        final hoverX = _xFor(hover, count, size.width);
        canvas.drawLine(
          Offset(hoverX, _topPad - 2),
          Offset(hoverX, bottom),
          Paint()
            ..color = AppTheme.terminalMutedForeground.withValues(alpha: 0.5)
            ..strokeWidth = 0.75,
        );
        for (var i = 0; i < series.length; i++) {
          final values = series[i];
          if (hover >= values.length) continue;
          final value = values[hover];
          if (value == null || !value.isFinite) continue;
          final point = Offset(hoverX, _yFor(value, size.height));
          canvas.drawCircle(
            point,
            4.2,
            Paint()..color = colors[i].withValues(alpha: 0.28),
          );
          canvas.drawCircle(point, 2.4, Paint()..color = colors[i]);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) {
    if (oldDelegate.scaleMax != scaleMax ||
        oldDelegate.hoveredIndex != hoveredIndex ||
        !listEquals(oldDelegate.colors, colors) ||
        oldDelegate.series.length != series.length) {
      return true;
    }
    for (var i = 0; i < series.length; i++) {
      if (!listEquals(oldDelegate.series[i], series[i])) return true;
    }
    return false;
  }
}
