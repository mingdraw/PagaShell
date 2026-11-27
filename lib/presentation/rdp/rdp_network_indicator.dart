import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/rdp/rdp_engine.dart';
import '../../domain/rdp/rdp_network_stats.dart';
import '../components/app_menu.dart';
import '../theme/app_theme.dart';

/// 四格网络信号强度图标，按信号质量着色。
class RdpSignalIcon extends StatelessWidget {
  const RdpSignalIcon({required this.level, this.size = 14, super.key});

  /// 0 = 检测中, 1 = 较差, 2 = 一般, 3 = 良好, 4 = 极佳。
  final int level;
  final double size;

  static Color colorForLevel(BuildContext context, int level) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return switch (level) {
      >= 3 => StatusColors.ready,
      2 => StatusColors.connecting,
      1 => StatusColors.failed,
      _ => colors.mutedForeground,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final active = colorForLevel(context, level);
    final inactive = colors.mutedForeground.withValues(alpha: 0.28);
    return Semantics(
      label: rdpSignalLabel(level),
      child: CustomPaint(
        size: Size.square(size),
        painter: _SignalBarsPainter(
          level: level.clamp(0, 4),
          activeColor: active,
          inactiveColor: inactive,
        ),
      ),
    );
  }
}

class _SignalBarsPainter extends CustomPainter {
  const _SignalBarsPainter({
    required this.level,
    required this.activeColor,
    required this.inactiveColor,
  });

  final int level;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 4;
    const heights = [0.32, 0.54, 0.77, 1.0];
    final gap = size.width * 0.11;
    final barWidth = (size.width - gap * (bars - 1)) / bars;
    final radius = Radius.circular(barWidth * 0.45);
    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;

    for (var i = 0; i < bars; i++) {
      final h = size.height * heights[i];
      final left = i * (barWidth + gap);
      final top = size.height - h;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, h),
        radius,
      );
      canvas.drawRRect(rect, i < level ? activePaint : inactivePaint);
    }
  }

  @override
  bool shouldRepaint(_SignalBarsPainter oldDelegate) =>
      oldDelegate.level != level ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}

String rdpSignalLabel(int level) => switch (level) {
  4 => '信号极佳'.tr,
  3 => '信号良好'.tr,
  2 => '信号一般'.tr,
  1 => '信号较差'.tr,
  _ => '检测中'.tr,
};

String rdpQualityTierLabel(RdpQualityTier tier) => switch (tier) {
  RdpQualityTier.high => '高画质'.tr,
  RdpQualityTier.balanced => '均衡'.tr,
  RdpQualityTier.low => '流畅'.tr,
};

String rdpQualityModeLabel(RdpQualityMode mode) => switch (mode) {
  RdpQualityMode.auto => '自动'.tr,
  RdpQualityMode.high => '高画质'.tr,
  RdpQualityMode.balanced => '均衡'.tr,
  RdpQualityMode.low => '流畅'.tr,
};

String rdpTransportLabel(RdpTransportKind transport) => switch (transport) {
  RdpTransportKind.tcp => 'TCP',
  RdpTransportKind.udp => 'UDP',
  RdpTransportKind.tunnel => '隧道'.tr,
};

String rdpNetworkTooltip(RdpNetworkStats? stats) {
  if (stats == null) return '正在测量 RDP 网络延迟…'.tr;
  final bandwidth = stats.formattedBandwidth;
  final speedText =
      bandwidth != null &&
          stats.bandwidthKbps != null &&
          stats.bandwidthKbps! > stats.throughputKbps
      ? '${stats.formattedThroughput} / $bandwidth'
      : stats.formattedThroughput;
  final qualityNote = stats.isAutoAdapted
      ? '自动降质稳帧'.tr
      : rdpQualityModeLabel(stats.qualityMode);
  return [
    '@signal · @transport'.trParams({
      'signal': rdpSignalLabel(stats.signalLevel),
      'transport': rdpTransportLabel(stats.transport),
    }),
    '延迟：@latency · 速率：@speed'.trParams({
      'latency': stats.formattedLatency,
      'speed': speedText,
    }),
    '丢包：@loss · 帧率：@fps FPS'.trParams({
      'loss': stats.formattedPacketLoss,
      'fps': '${stats.fps}',
    }),
    '画质：@tier（@mode）'.trParams({
      'tier': rdpQualityTierLabel(stats.qualityTier),
      'mode': qualityNote,
    }),
  ].join('\n');
}

/// RDP 工具栏和全屏固定栏中的网络信号、延迟与自适应画质控件。
class RdpNetworkBadge extends StatelessWidget {
  const RdpNetworkBadge({
    required this.stats,
    required this.onSelectQualityMode,
    this.onMenuVisibilityChanged,
    this.compact = false,
    this.enabled = true,
    super.key,
  });

  final RdpNetworkStats? stats;
  final ValueChanged<RdpQualityMode> onSelectQualityMode;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final bool compact;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final current = stats;
    final level = current?.signalLevel ?? 0;
    final mode = current?.qualityMode ?? RdpQualityMode.auto;
    final tier = current?.qualityTier ?? RdpQualityTier.high;
    final showQualityTag = current != null && tier != RdpQualityTier.high;
    final latencyColor = switch (level) {
      1 => StatusColors.failed,
      2 => StatusColors.connecting,
      _ => colors.foreground,
    };

    return AppMenuButton<RdpQualityMode>(
      key: const ValueKey('rdp-network-badge'),
      enabled: enabled,
      semanticLabel: '网络状态与画质'.tr,
      tooltip: rdpNetworkTooltip(current),
      selectedValue: mode,
      onSelected: onSelectQualityMode,
      onMenuVisibilityChanged: onMenuVisibilityChanged,
      items: [
        (RdpQualityMode.auto, '画质：自动（根据网络稳帧）'.tr),
        (RdpQualityMode.high, '画质：高画质'.tr),
        (RdpQualityMode.balanced, '画质：均衡'.tr),
        (RdpQualityMode.low, '画质：流畅'.tr),
      ],
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RdpSignalIcon(level: level, size: compact ? 13 : 14),
          const SizedBox(width: 5),
          Text(
            current?.formattedLatency ?? '-- ms',
            key: const ValueKey('rdp-network-latency'),
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: latencyColor,
            ),
          ),
          if (showQualityTag) ...[
            const SizedBox(width: 4),
            Text(
              '· ${rdpQualityTierLabel(tier)}',
              key: const ValueKey('rdp-network-quality-tag'),
              style: TextStyle(fontSize: 11, color: colors.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }
}

/// 紧凑型信号与延迟标识，用于窗口标签标题栏。
class RdpCompactNetworkChip extends StatelessWidget {
  const RdpCompactNetworkChip({
    required this.stats,
    this.iconSize = 11,
    this.fontSize = 10.5,
    super.key,
  });

  final RdpNetworkStats stats;
  final double iconSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final textColor = switch (stats.signalLevel) {
      1 => StatusColors.failed,
      2 => StatusColors.connecting,
      _ => colors.mutedForeground,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RdpSignalIcon(level: stats.signalLevel, size: iconSize),
        const SizedBox(width: 3),
        Text(
          stats.compactLatency,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: textColor,
          ),
        ),
      ],
    );
  }
}

/// 标签标题栏中的实时 RDP 信号和延迟订阅组件，避免重建整个标签页。
class RdpTabNetworkIndicator extends StatelessWidget {
  const RdpTabNetworkIndicator({required this.session, super.key});

  final RdpNetworkSession session;

  @override
  Widget build(BuildContext context) => StreamBuilder<RdpNetworkStats>(
    initialData: session.latestNetworkStats,
    stream: session.networkStats,
    builder: (context, snapshot) {
      final stats = snapshot.data;
      if (stats == null || stats.rttMs == null) {
        return const SizedBox.shrink();
      }
      return Padding(
        key: const ValueKey('rdp-tab-network-indicator'),
        padding: const EdgeInsets.only(left: 6),
        child: RdpCompactNetworkChip(stats: stats),
      );
    },
  );
}
