enum RdpQualityTier {
  high(0),
  balanced(1),
  low(2);

  const RdpQualityTier(this.wireValue);
  final int wireValue;

  static RdpQualityTier fromWire(int value) => switch (value) {
    1 => balanced,
    2 => low,
    _ => high,
  };
}

enum RdpQualityMode {
  auto(0),
  high(1),
  balanced(2),
  low(3);

  const RdpQualityMode(this.wireValue);
  final int wireValue;

  static RdpQualityMode fromWire(int value) => switch (value) {
    1 => high,
    2 => balanced,
    3 => low,
    _ => auto,
  };
}

enum RdpTransportKind {
  tcp(0),
  udp(1),
  tunnel(2);

  const RdpTransportKind(this.wireValue);
  final int wireValue;

  static RdpTransportKind fromWire(int value) => switch (value) {
    1 => udp,
    2 => tunnel,
    _ => tcp,
  };
}

class RdpNetworkStats {
  const RdpNetworkStats({
    this.rttMs,
    this.throughputKbps = 0,
    this.bandwidthKbps,
    this.packetLossPermille,
    this.fps = 0,
    this.signalLevel = 0,
    this.qualityTier = RdpQualityTier.high,
    this.qualityMode = RdpQualityMode.auto,
    this.transport = RdpTransportKind.tcp,
  });

  final int? rttMs;
  final int throughputKbps;
  final int? bandwidthKbps;
  final int? packetLossPermille;
  final int fps;

  /// 0 = measuring, 1 = poor, 2 = fair, 3 = good, 4 = excellent.
  final int signalLevel;
  final RdpQualityTier qualityTier;
  final RdpQualityMode qualityMode;
  final RdpTransportKind transport;

  double? get packetLossPercent =>
      packetLossPermille == null ? null : packetLossPermille! / 10.0;

  bool get isAutoAdapted =>
      qualityMode == RdpQualityMode.auto && qualityTier != RdpQualityTier.high;

  String get formattedLatency => rttMs == null ? '-- ms' : '$rttMs ms';

  String get compactLatency => rttMs == null ? '--' : '${rttMs}ms';

  static String formatKbps(int kbps) {
    if (kbps >= 1000) {
      final mbps = kbps / 1000.0;
      return mbps >= 10
          ? '${mbps.toStringAsFixed(1)} Mbps'
          : '${mbps.toStringAsFixed(2)} Mbps';
    }
    return '$kbps Kbps';
  }

  String get formattedThroughput => formatKbps(throughputKbps);

  String? get formattedBandwidth =>
      bandwidthKbps == null ? null : formatKbps(bandwidthKbps!);

  String get formattedPacketLoss => packetLossPercent == null
      ? '--'
      : '${packetLossPercent!.toStringAsFixed(1)}%';

  @override
  bool operator ==(Object other) =>
      other is RdpNetworkStats &&
      other.rttMs == rttMs &&
      other.throughputKbps == throughputKbps &&
      other.bandwidthKbps == bandwidthKbps &&
      other.packetLossPermille == packetLossPermille &&
      other.fps == fps &&
      other.signalLevel == signalLevel &&
      other.qualityTier == qualityTier &&
      other.qualityMode == qualityMode &&
      other.transport == transport;

  @override
  int get hashCode => Object.hash(
    rttMs,
    throughputKbps,
    bandwidthKbps,
    packetLossPermille,
    fps,
    signalLevel,
    qualityTier,
    qualityMode,
    transport,
  );
}
