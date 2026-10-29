import 'dart:math' as math;

/// A single remote monitor, in pixels; matches MS-RDPEDISP and our image budget.
class RdpResolution {
  const RdpResolution(this.width, this.height);
  final int width;
  final int height;

  static const presets = [
    RdpResolution(1024, 768),
    RdpResolution(1280, 720),
    RdpResolution(1280, 800),
    RdpResolution(1366, 768),
    RdpResolution(1600, 900),
    RdpResolution(1920, 1080),
    RdpResolution(1920, 1200),
    RdpResolution(2560, 1440),
    RdpResolution(2560, 1600),
    RdpResolution(3840, 2160),
  ];

  /// Logical window pixels keep automatic mode readable on high DPI monitors.
  factory RdpResolution.fromViewport(double width, double height) {
    var w = width.floor().clamp(200, 8192);
    var h = height.floor().clamp(200, 8192);
    if (w * h > 16777216) {
      final ratio = math.sqrt(16777216 / (w * h));
      w = (w * ratio).floor().clamp(200, 8192);
      h = (h * ratio).floor().clamp(200, 8192);
    }
    return RdpResolution(w - w % 2, h);
  }

  String get label => '$width × $height';
  @override
  bool operator ==(Object other) =>
      other is RdpResolution && width == other.width && height == other.height;
  @override
  int get hashCode => Object.hash(width, height);
}
