import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_known_host_repository.dart';

import '../support/fake_rdp_engine.dart';

class _NoSsh implements SshEngine {
  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => throw StateError('RDP must not use SSH');
}

void main() {
  const host = Host(
    id: 'windows',
    name: 'Windows',
    hostname: 'windows.test',
    port: 3389,
    serviceType: ServiceType.rdp,
  );
  const credentials = SshCredentials.password('secret');
  const identity = SshHostKey(
    hostname: 'windows.test',
    port: 3389,
    keyType: 'X.509 SHA-256',
    fingerprint: 'cert1',
    protocol: ServerIdentityProtocol.rdp,
  );

  Future<void> waitForReview(SessionController controller) async {
    for (var i = 0; i < 100; i++) {
      if (controller.sessions.single.phase == SessionPhase.hostKeyPending) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('certificate review did not arrive');
  }

  for (final error in [
    'unknownIssuer',
    'expired',
    'notValidYet',
    'nameMismatch',
    'trustStoreUnavailable',
  ]) {
    test('RDP $error 即使指纹已保存仍等待确认，取消不认证，继续仅本次生效', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final known = DriftKnownHostRepository(db);
      await known.trustIfAbsent(identity);
      final engine = FakeRdpEngine(
        identity: SshHostKey(
          hostname: identity.hostname,
          port: identity.port,
          keyType: identity.keyType,
          fingerprint: identity.fingerprint,
          protocol: ServerIdentityProtocol.rdp,
          certificateError: error,
        ),
      );
      final controller = SessionController(
        engine: _NoSsh(),
        rdpEngine: engine,
        knownHosts: known,
      );
      Future<void> opening = controller.open(host, credentials);
      await waitForReview(controller);
      expect(engine.authentications, 0);
      controller.confirmHostKey(controller.sessions.single.id, trust: false);
      await opening;
      expect(engine.authentications, 0);
      expect(controller.sessions.single.phase, SessionPhase.failed);
      opening = controller.retry(controller.sessions.single.id);
      await waitForReview(controller);
      controller.confirmHostKey(controller.sessions.single.id, trust: true);
      await opening;
      expect(engine.authentications, 1);
      expect(controller.sessions.single.phase, SessionPhase.ready);
      expect(
        (await known.find(
          host.hostname,
          host.port,
          protocol: ServerIdentityProtocol.rdp,
        ))!.fingerprint,
        identity.fingerprint,
      );
      await controller.closeAll();
    });
  }

  test('RDP 证书变化可确认本次连接，不覆盖旧证书；下次仍提示', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final known = DriftKnownHostRepository(db);
    await known.trustIfAbsent(
      const SshHostKey(
        hostname: 'windows.test',
        port: 3389,
        keyType: 'X.509 SHA-256',
        fingerprint: 'old',
        protocol: ServerIdentityProtocol.rdp,
      ),
    );
    final engine = FakeRdpEngine(identity: identity);
    final controller = SessionController(
      engine: _NoSsh(),
      rdpEngine: engine,
      knownHosts: known,
    );
    Future<void> opening = controller.open(host, credentials);
    await waitForReview(controller);
    expect(controller.sessions.single.hostKeyReview!.hasChanged, isTrue);
    expect(engine.authentications, 0);
    controller.confirmHostKey(controller.sessions.single.id, trust: true);
    await opening;
    expect(controller.sessions.single.phase, SessionPhase.ready);
    expect(
      (await known.find(
        host.hostname,
        host.port,
        protocol: ServerIdentityProtocol.rdp,
      ))!.fingerprint,
      'old',
    );
    await controller.closeAll();
    opening = controller.open(host, credentials);
    await waitForReview(controller);
    expect(engine.authentications, 1);
    controller.confirmHostKey(controller.sessions.single.id, trust: false);
    await opening;
    expect(engine.authentications, 1);
    await controller.closeAll();
  });

  test('RDP 服务先确认独立证书，创建桌面且不启动 SSH，断线保留重连入口', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final known = DriftKnownHostRepository(db);
    // Identical endpoint SSH trust must never silently trust its RDP certificate.
    await known.trustIfAbsent(
      const SshHostKey(
        hostname: 'windows.test',
        port: 3389,
        keyType: 'ssh-ed25519',
        fingerprint: 'ssh',
      ),
    );
    final engine = FakeRdpEngine(identity: identity);
    final controller = SessionController(
      engine: _NoSsh(),
      rdpEngine: engine,
      knownHosts: known,
    );
    final opening = controller.open(host, credentials);
    for (
      var i = 0;
      i < 100 &&
          controller.sessions.single.phase != SessionPhase.hostKeyPending;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(engine.authentications, 0);
    expect(controller.sessions.single.hostKeyReview!.presented.isRdp, isTrue);
    controller.confirmHostKey(controller.sessions.single.id, trust: true);
    final id = await opening;
    expect(controller.sessions.single.kind, SessionKind.remoteDesktop);
    expect(controller.sessions.single.phase, SessionPhase.ready);
    expect(controller.sessions.single.terminal, isNull);
    expect(controller.commandSessions, isEmpty);
    await controller.desktopFailed(id, '断开');
    expect(engine.created.first.closes, 1);
    expect(controller.sessions.single.phase, SessionPhase.failed);
    await controller.retry(id);
    expect(engine.authentications, 2);
    expect(controller.sessions.single.phase, SessionPhase.ready);
    await controller.closeAll();
    expect(engine.created.last.closes, 1);
  });

  test('认证等待期间关页签发送取消，迟到的桌面句柄被释放', () async {
    final pending = Completer<RdpEngineSession>();
    final engine = FakeRdpEngine(pending: pending);
    final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
    final opening = controller.open(host, credentials);
    final id = controller.sessions.single.id;
    await controller.close(id);
    await engine.cancellation;
    final late = FakeRdpSession();
    pending.complete(late);
    await opening;
    expect(late.closes, 1);
    expect(controller.sessions, isEmpty);
  });

  test('RDP 服务拒绝 SFTP 和端口转发入口', () async {
    final controller = SessionController(
      engine: _NoSsh(),
      rdpEngine: FakeRdpEngine(),
    );
    await expectLater(
      controller.open(host, credentials, kind: SessionKind.fileTransfer),
      throwsA(isA<SshEngineException>()),
    );
    expect(
      () => controller.openForward(host),
      throwsA(isA<SshEngineException>()),
    );
    expect(controller.sessions, isEmpty);
  });
}
