import 'dart:async';

import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_clipboard.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/rdp/rdp_network_stats.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vnc/vnc_engine.dart';

import 'fake_rdp_engine.dart';

class FakeVncSession extends FakeRdpSession
    implements VncEngineSession, RdpNetworkSession, RdpClipboardSession {
  FakeVncSession() {
    onResize = (_, _) async => false;
  }

  final symbols = <(int, bool)>[];
  final qualityModes = <RdpQualityMode>[];
  final clipboardActiveChanges = <bool>[];
  final clipboardUpdates = <ClipboardContent>[];
  final _networkOutput = StreamController<RdpNetworkStats>.broadcast();
  final _clipboardOutput = StreamController<RdpClipboardEvent>.broadcast();
  RdpNetworkStats? _latestNetworkStats;

  void emitNetworkStats(RdpNetworkStats stats) {
    _latestNetworkStats = stats;
    if (!_networkOutput.isClosed) _networkOutput.add(stats);
  }

  void emitClipboardEvent(RdpClipboardEvent event) {
    if (!_clipboardOutput.isClosed) _clipboardOutput.add(event);
  }

  @override
  RdpNetworkStats? get latestNetworkStats => _latestNetworkStats;

  @override
  Stream<RdpNetworkStats> get networkStats => _networkOutput.stream;

  @override
  Stream<RdpClipboardEvent> get clipboardEvents => _clipboardOutput.stream;

  @override
  Future<void> setClipboardActive(bool active) async {
    clipboardActiveChanges.add(active);
  }

  @override
  Future<void> updateClipboard(ClipboardContent content) async {
    clipboardUpdates.add(content);
  }

  @override
  Future<void> cancelClipboardTransfer() async {}

  @override
  Future<void> setQualityMode(RdpQualityMode mode) async {
    qualityModes.add(mode);
    final current = _latestNetworkStats;
    if (current != null) {
      final tier = switch (mode) {
        RdpQualityMode.high => RdpQualityTier.high,
        RdpQualityMode.balanced => RdpQualityTier.balanced,
        RdpQualityMode.low => RdpQualityTier.low,
        RdpQualityMode.auto => current.qualityTier,
      };
      emitNetworkStats(
        RdpNetworkStats(
          rttMs: current.rttMs,
          throughputKbps: current.throughputKbps,
          bandwidthKbps: current.bandwidthKbps,
          packetLossPermille: current.packetLossPermille,
          fps: current.fps,
          signalLevel: current.signalLevel,
          qualityTier: tier,
          qualityMode: mode,
          transport: current.transport,
        ),
      );
    }
  }

  @override
  Future<void> keySymbol(int keysym, {required bool down}) async {
    symbols.add((keysym, down));
  }

  @override
  Future<void> close() async {
    unawaited(_networkOutput.close());
    unawaited(_clipboardOutput.close());
    await super.close();
  }
}

class FakeVncEngine implements VncEngine {
  FakeVncEngine({this.authenticationError});

  final Object? Function(SshCredentials credentials, Host host)?
  authenticationError;
  final created = <FakeVncSession>[];
  final attempts = <SshCredentials>[];
  final hosts = <Host>[];
  final gateways = <SshGateway?>[];
  Completer<RdpEngineSession>? pending;
  Future<void>? cancellation;

  @override
  Future<RdpEngineSession> connectDesktop(
    Host host,
    SshCredentials credentials, {
    required HostKeyVerifier verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    hosts.add(host);
    attempts.add(credentials);
    gateways.add(gateway);
    cancellation = cancelled;
    if (authenticationError?.call(credentials, host) case final error?) {
      throw error;
    }
    if (pending != null) return pending!.future;
    final session = FakeVncSession();
    created.add(session);
    return session;
  }
}
