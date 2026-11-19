import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// The latest samples are on the right. The same scale is used for both
/// directions of I/O; gaps are kept where a baseline was unavailable.
class ServerStatusTrend extends StatelessWidget {
  const ServerStatusTrend({
    required this.series,
    required this.colors,
    this.upperBound,
    super.key,
  });

  final List<List<double?>> series;
  final List<Color> colors;
  final double? upperBound;

  @override
  Widget build(BuildContext context) {
    if (!series.any((line) => line.whereType<double>().length >= 2)) {
      return const SizedBox.shrink();
    }
    final maximum =
        upperBound ??
        series
            .expand((line) => line.whereType<double>())
            .fold<double>(0.0, math.max);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        image: true,
        label: '最近 @count 次采样趋势'.trParams({'count': '${series.first.length}'}),
        child: SizedBox(
          height: 24,
          child: CustomPaint(
            painter: _TrendPainter(series, colors, math.max(maximum, 0.001)),
          ),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(this.series, this.colors, this.maximum);

  final List<List<double?>> series;
  final List<Color> colors;
  final double maximum;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < series.length; i++) {
      final values = series[i];
      if (values.length < 2) continue;
      final path = Path();
      var connected = false;
      for (var j = 0; j < values.length; j++) {
        final value = values[j];
        if (value == null || !value.isFinite) {
          connected = false;
          continue;
        }
        final x = size.width * j / (values.length - 1);
        final y =
            size.height - 1 - (size.height - 2) * (value / maximum).clamp(0, 1);
        if (connected) {
          path.lineTo(x, y);
        } else {
          path.moveTo(x, y);
        }
        connected = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.maximum != maximum ||
      !listEquals(oldDelegate.colors, colors) ||
      !listEquals(oldDelegate.series, series);
}
