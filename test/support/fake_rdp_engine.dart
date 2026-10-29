import 'dart:async';

import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

class FakeRdpSession implements RdpEngineSession {
  final output = StreamController<RdpFrame>.broadcast();
  final keys = <(int, bool, bool)>[];
  final pointers = <(int, int, int, int)>[];
  final texts = <String>[];
  final resizes = <(int, int)>[];
  Future<bool> Function(int, int)? onResize;
  int closes = 0;
  @override
  Stream<RdpFrame> get frames => output.stream;
  @override
  Future<void> key(
    int scanCode, {
    required bool down,
    bool extended = false,
  }) async {
    keys.add((scanCode, down, extended));
  }

  @override
  Future<void> pointer(int x, int y, int flags, {int wheel = 0}) async {
    pointers.add((x, y, flags, wheel));
  }

  @override
  Future<void> text(String text) async {
    texts.add(text);
  }

  @override
  Future<bool> resize(int width, int height) async {
    resizes.add((width, height));
    return await onResize?.call(width, height) ?? true;
  }

  @override
  Future<void> close() async {
    closes++;
    unawaited(output.close());
  }
}

class FakeRdpEngine implements RdpEngine {
  FakeRdpEngine({this.identity, this.pending, this.authenticationError});
  final SshHostKey? identity;
  final Completer<RdpEngineSession>? pending;
  final Object? Function(SshCredentials, SshGateway?)? authenticationError;
  final created = <FakeRdpSession>[];
  final gateways = <SshGateway?>[];
  final attempts = <SshCredentials>[];
  int authentications = 0;
  Future<void>? cancellation;
  @override
  Future<RdpEngineSession> connectDesktop(
    Host host,
    SshCredentials credentials, {
    required HostKeyVerifier verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    gateways.add(gateway);
    cancellation = cancelled;
    if (identity != null && !await verifyHostKey(identity!)) {
      throw const SshEngineException('RDP 证书未获信任，已取消连接');
    }
    authentications++;
    attempts.add(credentials);
    final error = authenticationError?.call(credentials, gateway);
    if (error != null) throw error;
    if (pending != null) return pending!.future;
    final session = FakeRdpSession();
    created.add(session);
    return session;
  }
}
