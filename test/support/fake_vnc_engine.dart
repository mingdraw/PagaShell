import 'dart:async';

import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vnc/vnc_engine.dart';

import 'fake_rdp_engine.dart';

class FakeVncSession extends FakeRdpSession implements VncEngineSession {
  final symbols = <(int, bool)>[];
  @override
  Future<void> keySymbol(int keysym, {required bool down}) async {
    symbols.add((keysym, down));
  }
}

class FakeVncEngine implements VncEngine {
  final created = <FakeVncSession>[];
  final attempts = <SshCredentials>[];
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
    attempts.add(credentials);
    gateways.add(gateway);
    cancellation = cancelled;
    if (pending != null) return pending!.future;
    final session = FakeVncSession();
    created.add(session);
    return session;
  }
}
