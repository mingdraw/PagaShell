import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:xterm/xterm.dart';

import '../support/in_memory_binding.dart';

class _FakeEngineSession implements SshEngineSession {
  _FakeEngineSession({this.throwOnClose = false});

  final bool throwOnClose;
  bool closed = false;
  int shellStarts = 0;
  final StreamController<String> _output = StreamController<String>();
  final List<String> written = [];
  bool failWrites = false;
  (int, int)? initialSize;
  final List<(int, int)> resized = [];

  @override
  Stream<String> startShell({required int cols, required int rows}) {
    shellStarts++;
    initialSize = (cols, rows);
    return _output.stream;
  }

  @override
  void write(String data) {
    if (failWrites) throw StateError('write failed');
    written.add(data);
  }

  @override
  void resizeTerminal(int width, int height) => resized.add((width, height));

  @override
  Future<List<SftpDirEntry>> listDir(String path) async => const [];

  @override
  Future<String> canonicalize(String path) async => '/home/test';

  @override
  Stream<SftpTransferProgress> download(String remotePath, String localPath) =>
      const Stream.empty();

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) =>
      const Stream.empty();

  @override
  Future<void> createDir(String path) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> remove(String path, {required bool isDir}) async {}

  @override
  Future<void> close() async {
    closed = true;
    unawaited(_output.close());
    if (throwOnClose) throw const SshEngineException('连接已断开');
  }
}

/// 前 [failuresBeforeSuccess] 次 connect 抛错，此后成功。
class _FakeEngine implements SshEngine {
  _FakeEngine({
    this.failuresBeforeSuccess = 0,
    this.throwOnSessionClose = false,
    this.hostKey,
    this.waitForCancellation = false,
  });

  final int failuresBeforeSuccess;
  final bool throwOnSessionClose;
  final SshHostKey? hostKey;
  final bool waitForCancellation;
  int calls = 0;
  int authentications = 0;
  final List<_FakeEngineSession> created = [];
  final List<SshGateway?> gateways = [];
  final List<SshCredentials> logins = [];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    gateways.add(gateway);
    logins.add(credentials);
    if (calls++ < failuresBeforeSuccess) {
      throw const SshEngineException('认证失败');
    }
    if (hostKey != null && !(await verifyHostKey!(hostKey!))) {
      throw const SshEngineException('主机密钥未获信任');
    }
    if (waitForCancellation) {
      await cancelled;
      throw const SshEngineException('连接已取消');
    }
    authentications++;
    final session = _FakeEngineSession(throwOnClose: throwOnSessionClose);
    created.add(session);
    return session;
  }
}

const _host = Host(id: 'h1', name: 'web-01', hostname: '10.0.0.5');
const _credentials = SshCredentials.password('secret');

const _key = SshHostKey(
  hostname: '10.0.0.5',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:original',
);

const _changedKey = SshHostKey(
  hostname: '10.0.0.5',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:changed',
);

class _KnownHosts implements KnownHostRepository {
  SshHostKey? stored;
  bool failToSave = false;
  bool failToRemove = false;
  SshHostKey? trustConflict;
  Completer<void>? removeGate;
  final removed = <SshHostKey>[];

  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async =>
      stored?.protocol == protocol &&
          stored?.hostname.trim().toLowerCase() ==
              hostname.trim().toLowerCase() &&
          stored?.port == port
      ? stored
      : null;

  @override
  Future<bool> trustIfAbsent(SshHostKey key) async {
    if (failToSave) throw StateError('存储不可用');
    if (trustConflict != null) {
      stored = trustConflict;
      return false;
    }
    stored ??= key;
    return stored!.matches(key);
  }

  @override
  Future<bool> removeIfMatches(SshHostKey key) async {
    removed.add(key);
    await removeGate?.future;
    if (failToRemove) throw StateError('存储不可用');
    final current = await find(key.hostname, key.port, protocol: key.protocol);
    if (current == null || !current.matches(key)) return false;
    stored = null;
    return true;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<String> _rejectChangedKey(
  SessionController controller, {
  Host host = _host,
  SshCredentials credentials = _credentials,
  SessionKind kind = SessionKind.terminal,
  SshGateway? gateway,
}) async {
  final opening = controller.open(
    host,
    credentials,
    kind: kind,
    gateway: gateway,
  );
  await _flush();
  final session = controller.sessions.single;
  expect(session.hostKeyReview!.hasChanged, isTrue);
  controller.confirmHostKey(session.id, trust: false);
  return opening;
}

void main() {
  group('SessionController', () {
    test('会话地址使用实际登录用户名，失败重试保留用户名和原服务配置', () async {
      final host = _host.copyWith(username: 'configured', port: 2222);
      for (final kind in [SessionKind.terminal, SessionKind.fileTransfer]) {
        for (final credentials in const [
          SshCredentials.password('password-only', username: 'rocky'),
          SshCredentials.privateKey('test-key-only', username: 'rocky'),
          SshCredentials.password('password-only'),
        ]) {
          final engine = _FakeEngine(failuresBeforeSuccess: 1);
          final controller = SessionController(engine: engine);
          final username = credentials.username ?? host.username;
          final opening = controller.open(host, credentials, kind: kind);
          expect(controller.sessions.single.address, '$username@10.0.0.5:2222');
          final id = await opening;
          expect(controller.sessions.single.phase, SessionPhase.failed);
          expect(controller.sessions.single.address, '$username@10.0.0.5:2222');
          final retrying = controller.retry(id);
          expect(controller.sessions.single.loginUsername, username);
          await retrying;
          expect(controller.sessions.single.phase, SessionPhase.ready);
          expect(controller.sessions.single.address, '$username@10.0.0.5:2222');
          expect(controller.sessions.single.host, same(host));
          expect(host.username, 'configured');
          expect(engine.logins, everyElement(same(credentials)));
          await controller.close(id);
        }
      }
    });

    test('所选网关缺失或不匹配时首次连接和重试均不直连', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final host = _host.copyWith(gatewayId: 'gateway');
      final id = await controller.open(host, _credentials);
      expect(controller.sessions.single.phase, SessionPhase.failed);
      await controller.retry(id);
      expect(engine.calls, 0);
      await controller.close(id);
      await controller.open(
        host,
        _credentials,
        gateway: const SshGateway(host: _host, credentials: _credentials),
      );
      expect(engine.calls, 0);
      await controller.closeActive();
    });

    test('网关传递给终端和文件传输，重试保留网关', () async {
      for (final kind in [SessionKind.terminal, SessionKind.fileTransfer]) {
        final engine = _FakeEngine(failuresBeforeSuccess: 1);
        final controller = SessionController(engine: engine);
        const gateway = SshGateway(
          host: Host(id: 'gateway', name: 'Jump', hostname: 'jump.test'),
          credentials: SshCredentials.password('gateway-only'),
        );
        final id = await controller.open(
          _host.copyWith(gatewayId: 'gateway'),
          _credentials,
          kind: kind,
          gateway: gateway,
        );
        expect(controller.sessions.single.phase, SessionPhase.failed);
        await controller.retry(id);
        expect(engine.gateways, [same(gateway), same(gateway)]);
        expect(controller.sessions.single.phase, SessionPhase.ready);
        expect(
          engine.created.single.shellStarts,
          kind == SessionKind.terminal ? 1 : 0,
        );
        await controller.close(id);
        expect(engine.created.single.closed, isTrue);
      }
    });

    testWidgets('首次确认超时不保存指纹或发送密码', (tester) async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts();
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await tester.pump();
      expect(controller.sessions.single.phase, SessionPhase.hostKeyPending);
      await tester.pump(const Duration(minutes: 2));
      await opening;
      expect(engine.authentications, 0);
      expect(known.stored, isNull);
      expect(controller.sessions.single.phase, SessionPhase.failed);
    });

    test('首次连接确认前不认证，接受后保存指纹并认证', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts();
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();

      final session = controller.sessions.single;
      expect(session.phase, SessionPhase.hostKeyPending);
      expect(session.hostKeyReview?.presented.fingerprint, _key.fingerprint);
      expect(engine.authentications, 0);
      controller.confirmHostKey(session.id, trust: true);
      await opening;

      expect(known.stored?.matches(_key), isTrue);
      expect(engine.authentications, 1);
      expect(controller.sessions.single.phase, SessionPhase.ready);
      await controller.closeActive();
    });

    test('可信指纹一致时直接认证，无需重复确认', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts()..stored = _key;
      final controller = SessionController(engine: engine, knownHosts: known);
      await controller.open(_host, _credentials);

      expect(engine.authentications, 1);
      expect(controller.sessions.single.phase, SessionPhase.ready);
      await controller.closeActive();
    });

    test('指纹变更时即使调用确认也拒绝认证且保留原记录', () async {
      const changed = SshHostKey(
        hostname: '10.0.0.5',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:changed',
      );
      final engine = _FakeEngine(hostKey: changed);
      final known = _KnownHosts()..stored = _key;
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();

      final session = controller.sessions.single;
      expect(session.hostKeyReview!.hasChanged, isTrue);
      controller.confirmHostKey(session.id, trust: true);
      await opening;

      expect(engine.authentications, 0);
      expect(known.stored?.fingerprint, _key.fingerprint);
      expect(controller.sessions.single.phase, SessionPhase.failed);
      expect(controller.sessions.single.error, contains('指纹已变更'));
      expect(controller.sessions.single.hostKeyFailure!.trusted, same(_key));
    });

    test('清除旧指纹后终端和 SFTP 均重新确认，保留类型、凭据及网关', () async {
      const login = SshCredentials.password('target-only', username: 'rocky');
      for (final kind in [SessionKind.terminal, SessionKind.fileTransfer]) {
        final engine = _FakeEngine(hostKey: _changedKey);
        final known = _KnownHosts()..stored = _key;
        final controller = SessionController(engine: engine, knownHosts: known);
        const gateway = SshGateway(
          host: Host(id: 'gateway', name: 'Jump', hostname: 'jump.test'),
          credentials: SshCredentials.password('gateway-only'),
        );
        final id = await _rejectChangedKey(
          controller,
          host: _host.copyWith(gatewayId: 'gateway'),
          credentials: login,
          kind: kind,
          gateway: gateway,
        );
        // 普通重试不删除记录，依旧拒绝变更的指纹。
        final ordinary = controller.retry(id);
        await _flush();
        controller.confirmHostKey(id, trust: false);
        await ordinary;
        expect(known.removed, isEmpty);
        final retrying = controller.clearHostKeyAndRetry(id);
        expect(controller.sessions.single.address, 'rocky@10.0.0.5');
        await _flush();
        expect(known.removed.single, same(_key));
        expect(known.stored, isNull);
        expect(engine.authentications, 0);
        expect(controller.sessions.single.phase, SessionPhase.hostKeyPending);
        expect(controller.sessions.single.hostKeyReview!.hasChanged, isFalse);
        controller.confirmHostKey(id, trust: true);
        await retrying;
        expect(engine.authentications, 1);
        expect(engine.gateways, everyElement(same(gateway)));
        expect(engine.logins, everyElement(same(login)));
        expect(controller.sessions.single.address, 'rocky@10.0.0.5');
        expect(known.stored!.matches(_changedKey), isTrue);
        expect(controller.sessions.single.kind, kind);
        expect(controller.sessions.single.hostKeyFailure, isNull);
        expect(
          engine.created.single.shellStarts,
          kind == SessionKind.terminal ? 1 : 0,
        );
        await controller.close(id);
      }
    });

    test('网关指纹变更清除实际网关端点，重试继续使用网关', () async {
      const gatewayKey = SshHostKey(
        hostname: 'jump.test',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:gateway-old',
      );
      const changedGatewayKey = SshHostKey(
        hostname: 'jump.test',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:gateway-new',
      );
      const gateway = SshGateway(
        host: Host(
          id: 'gateway',
          name: 'Jump',
          hostname: 'jump.test',
          port: 2222,
        ),
        credentials: SshCredentials.password('gateway-only'),
      );
      final engine = _FakeEngine(hostKey: changedGatewayKey);
      final known = _KnownHosts()..stored = gatewayKey;
      final controller = SessionController(engine: engine, knownHosts: known);
      final id = await _rejectChangedKey(
        controller,
        host: _host.copyWith(gatewayId: 'gateway'),
        gateway: gateway,
      );
      final retrying = controller.clearHostKeyAndRetry(id);
      await _flush();
      expect(known.removed.single, same(gatewayKey));
      expect(known.stored, isNull);
      expect(engine.gateways, [same(gateway), same(gateway)]);
      expect(engine.authentications, 0);
      controller.confirmHostKey(id, trust: true);
      await retrying;
      expect(known.stored, same(changedGatewayKey));
      await controller.close(id);
    });

    test('清除失败保留旧记录并显示错误，不开始新连接', () async {
      final engine = _FakeEngine(hostKey: _changedKey);
      final known = _KnownHosts()
        ..stored = _key
        ..failToRemove = true;
      final controller = SessionController(engine: engine, knownHosts: known);
      final id = await _rejectChangedKey(controller);
      await controller.clearHostKeyAndRetry(id);
      expect(known.stored, same(_key));
      expect(engine.calls, 1);
      expect(engine.authentications, 0);
      expect(controller.sessions.single.phase, SessionPhase.failed);
      expect(controller.sessions.single.error, '无法清除主机指纹，请重试');
      expect(controller.sessions.single.hostKeyFailure, isNotNull);
      await controller.close(id);
    });

    test('旧记录已被另一操作更新时不误删，不自动重连', () async {
      final engine = _FakeEngine(hostKey: _changedKey);
      final known = _KnownHosts()..stored = _key;
      final controller = SessionController(engine: engine, knownHosts: known);
      final id = await _rejectChangedKey(controller);
      known.stored = _changedKey;
      await controller.clearHostKeyAndRetry(id);
      expect(known.stored, same(_changedKey));
      expect(engine.calls, 1);
      expect(controller.sessions.single.error, '指纹记录已更新，请重试连接');
      await controller.retry(id);
      expect(engine.authentications, 1);
      await controller.close(id);
    });

    test('旧记录已被清除仍重新核验，拒绝新指纹不保存也不认证', () async {
      final engine = _FakeEngine(hostKey: _changedKey);
      final known = _KnownHosts()..stored = _key;
      final controller = SessionController(engine: engine, knownHosts: known);
      final id = await _rejectChangedKey(controller);
      known.stored = null;
      final retrying = controller.clearHostKeyAndRetry(id);
      await _flush();
      expect(controller.sessions.single.phase, SessionPhase.hostKeyPending);
      controller.confirmHostKey(id, trust: false);
      await retrying;
      expect(known.stored, isNull);
      expect(engine.authentications, 0);
      expect(controller.sessions.single.hostKeyFailure, isNull);
      await controller.close(id);
    });

    test('清除期间重复点击不并发，关闭标签后不会重新连接', () async {
      final engine = _FakeEngine(hostKey: _changedKey);
      final known = _KnownHosts()
        ..stored = _key
        ..removeGate = Completer<void>();
      final controller = SessionController(engine: engine, knownHosts: known);
      final id = await _rejectChangedKey(controller);
      final clearing = controller.clearHostKeyAndRetry(id);
      expect(controller.sessions.single.phase, SessionPhase.reconnecting);
      await controller.clearHostKeyAndRetry(id);
      await controller.retry(id);
      expect(known.removed, hasLength(1));
      await controller.close(id);
      known.removeGate!.complete();
      await clearing;
      expect(controller.sessions, isEmpty);
      expect(engine.calls, 1);
      expect(engine.authentications, 0);
    });

    test('首次信任发生并发冲突时保留冲突记录，提供定向清除信息', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts()..trustConflict = _changedKey;
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      controller.confirmHostKey(controller.sessions.single.id, trust: true);
      final id = await opening;
      expect(engine.authentications, 0);
      expect(controller.sessions.single.error, '可信主机指纹已发生变化，已拒绝连接');
      expect(
        controller.sessions.single.hostKeyFailure!.trusted,
        same(_changedKey),
      );
      expect(known.stored, same(_changedKey));
      await controller.close(id);
    });

    test('取消首次确认不保存指纹也不认证', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts();
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      controller.confirmHostKey(controller.sessions.single.id, trust: false);
      await opening;

      expect(engine.authentications, 0);
      expect(known.stored, isNull);
      expect(controller.sessions.single.phase, SessionPhase.failed);
    });

    test('待确认时关闭标签会结束等待且不认证', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts();
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      await controller.closeActive();
      await opening;

      expect(engine.authentications, 0);
      expect(known.stored, isNull);
      expect(controller.sessions, isEmpty);
    });

    test('可信记录写入失败时不认证', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts()..failToSave = true;
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      controller.confirmHostKey(controller.sessions.single.id, trust: true);
      await opening;

      expect(engine.authentications, 0);
      expect(controller.sessions.single.phase, SessionPhase.failed);
    });

    test('指纹放行后关闭标签仍会取消进行中的连接', () async {
      final engine = _FakeEngine(hostKey: _key, waitForCancellation: true);
      final known = _KnownHosts()..stored = _key;
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      expect(controller.sessions.single.phase, SessionPhase.authenticating);
      await controller.closeActive();
      await opening;
      expect(controller.sessions, isEmpty);
      expect(engine.authentications, 0);
    });

    test('并发首次确认不能覆盖另一个连接保存的密钥', () async {
      final engine = _FakeEngine(hostKey: _key);
      final known = _KnownHosts();
      final controller = SessionController(engine: engine, knownHosts: known);
      final opening = controller.open(_host, _credentials);
      await _flush();
      known.stored = const SshHostKey(
        hostname: '10.0.0.5',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:other',
      );
      controller.confirmHostKey(controller.sessions.single.id, trust: true);
      await opening;

      expect(engine.authentications, 0);
      expect(known.stored?.fingerprint, 'SHA256:other');
      expect(controller.sessions.single.phase, SessionPhase.failed);
    });

    test('未配置可信记录仓库时拒绝真实校验流程', () async {
      final engine = _FakeEngine(hostKey: _key);
      final controller = SessionController(engine: engine);
      await controller.open(_host, _credentials);
      expect(engine.authentications, 0);
      expect(controller.sessions.single.phase, SessionPhase.failed);
    });

    test('连接成功后会话进入 ready、绑定终端并被激活', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);

      final id = await controller.open(_host, _credentials);

      final session = controller.sessions.single;
      expect(session.phase, SessionPhase.ready);
      expect(session.terminal, isNotNull);
      expect(controller.activeSessionId.value, id);
      expect(controller.activeSession?.host, _host);
    });

    test('终端输入被转发到引擎会话', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      await controller.open(_host, _credentials);

      controller.sessions.single.terminal!.onOutput!('ls\n');

      expect(engine.created.single.written, ['ls\n']);
    });

    test('批量命令仅发送到所选 SSH 终端，去重并排除传输和转发', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      addTearDown(controller.onClose);
      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);
      await controller.open(_host, _credentials);
      final transfer = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      final forward = controller.openForward(_host);
      expect(controller.commandSessions.map((s) => s.id), [
        first,
        second,
        controller.sessions[2].id,
      ]);

      final result = controller.sendCommandToSessions([
        first,
        second,
        first,
        transfer,
        forward,
      ], 'pwd');
      expect(result.sent, 2);
      expect(result.skipped, 2);
      expect(result.failed, 0);
      expect(engine.created[0].written, ['pwd\r']);
      expect(engine.created[1].written, ['pwd\r']);
      expect(engine.created[2].written, isEmpty);
      expect(engine.created[3].written, isEmpty);
      expect(controller.activeSessionId.value, forward);
    });

    test('批量多行规范换行但保留缩进和 heredoc，并适配各终端的粘贴模式', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      addTearDown(controller.onClose);
      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);
      controller.sessions[1].terminal!.write('\x1b[?2004h');
      const command = "cat <<'EOF'\r\n  hello\rworld\r\nEOF";
      final result = controller.sendCommandToSessions([first, second], command);
      expect(result.sent, 2);
      expect(engine.created[0].written, ["cat <<'EOF'\r  hello\rworld\rEOF\r"]);
      expect(engine.created[1].written, [
        "\x1b[200~cat <<'EOF'\n  hello\nworld\nEOF\x1b[201~\r",
      ]);
      controller.sendCommandToSessions([first], 'pwd\n');
      expect(engine.created[0].written.last, 'pwd\r');
    });

    test('批量发送前复查连接，跳过关闭与过渡状态且一个失败不影响其他目标', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      addTearDown(controller.onClose);
      final closed = await controller.open(_host, _credentials);
      final unavailable = await controller.open(_host, _credentials);
      final broken = await controller.open(_host, _credentials);
      final ready = await controller.open(_host, _credentials);
      await controller.close(closed);
      engine.created[2].failWrites = true;
      for (final phase in SessionPhase.values.where(
        (phase) => phase != SessionPhase.ready,
      )) {
        controller.sessions[0] = controller.sessions[0].copyWith(phase: phase);
        final result = controller.sendCommandToSessions([
          closed,
          unavailable,
          broken,
          ready,
          'missing',
        ], 'whoami');
        expect(result.sent, 1);
        expect(result.skipped, 3);
        expect(result.failed, 1);
      }
      expect(engine.created[0].written, isEmpty);
      expect(engine.created[1].written, isEmpty);
      expect(engine.created[2].written, isEmpty);
      expect(engine.created[3].written, everyElement('whoami\r'));
    });

    test('空白命令、无目标以及已销毁控制器不写入终端', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final id = await controller.open(_host, _credentials);
      expect(controller.sendCommandToSessions([id], ' \r\n ').sent, 0);
      expect(controller.sendCommandToSessions([], 'pwd').sent, 0);
      controller.onClose();
      expect(controller.sendCommandToSessions([id], 'pwd').sent, 0);
      expect(engine.created.single.written, isEmpty);
    });

    testWidgets('终端首次布局及窗口缩放同步完整视口的行列数', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() {
        Get.reset();
        Get.locale = null;
        Get.fallbackLocale = null;
        Get.clearTranslations();
      });
      final engine = _FakeEngine();
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
      final controller = Get.find<SessionController>();
      await controller.open(_host, _credentials);
      final terminal = controller.sessions.single.terminal!;
      final remote = engine.created.single;
      expect(remote.initialSize, (80, 24));

      final dimensions = <(int, int)>[];
      for (final size in [
        const Size(800, 600),
        const Size(1600, 1000),
        const Size(800, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final view = find.byType(TerminalView);
        final render = tester.state<TerminalViewState>(view).renderTerminal;
        // TerminalView 的外层 padding 已从 render.size 中扣除；渲染器
        // 只再扣除 MediaQuery 的安全区域，避免重复减去内边距。
        final safePadding = MediaQuery.paddingOf(tester.element(view));
        final expected = (
          render.size.width ~/ render.cellSize.width,
          (render.size.height - safePadding.vertical) ~/ render.cellSize.height,
        );
        expect((terminal.viewWidth, terminal.viewHeight), expected);
        expect(remote.resized.last, expected);
        dimensions.add(expected);
      }
      expect(dimensions[1].$1, greaterThan(dimensions[0].$1));
      expect(dimensions[1].$2, greaterThan(dimensions[0].$2));
      expect(dimensions[2], dimensions[0]);
      expect(tester.takeException(), isNull);
      await tester.runAsync(controller.closeActive);
    });

    test('文件传输会话独立连接且不启动 shell，不影响默认终端聚焦策略', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      final session = controller.sessions.single;
      expect(session.kind, SessionKind.fileTransfer);
      expect(session.phase, SessionPhase.ready);
      expect(session.terminal, isNull);
      expect(session.engineSession, isNotNull);
      expect(engine.created.single.shellStarts, 0);
      expect(controller.focusExisting(_host.id), isFalse);
      await controller.closeActive();
      expect(engine.created.single.closed, isTrue);
    });

    test('文件传输连接重试保留标签类型', () async {
      final engine = _FakeEngine(failuresBeforeSuccess: 1);
      final controller = SessionController(engine: engine);
      final id = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      await controller.retry(id);
      expect(controller.sessions.single.kind, SessionKind.fileTransfer);
      expect(controller.sessions.single.phase, SessionPhase.ready);
      expect(engine.created.single.shellStarts, 0);
      await controller.closeActive();
    });

    test('同主机终端退出保留文件传输标签与连接', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      await controller.open(_host, _credentials);
      final transferId = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      expect(engine.created, hasLength(2));
      await engine.created.first._output.close();
      await _flush();
      expect(controller.sessions.single.id, transferId);
      expect(engine.created.last.closed, isFalse);
      await controller.closeActive();
    });

    test('关闭文件传输标签取消该连接的在途任务', () async {
      final engine = _FakeEngine();
      final transfers = TransferController();
      final controller = SessionController(
        engine: engine,
        transfers: transfers,
      );
      final id = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      final task = transfers.startDownload(
        sessionId: id,
        engineSession: engine.created.single,
        remotePath: '/a.txt',
        localPath: '/tmp/a.txt',
      );
      await controller.close(id);
      expect(task.status.value, TransferStatus.cancelled);
      expect(engine.created.single.closed, isTrue);
      transfers.onClose();
    });

    test('引擎抛错时会话进入 failed 并携带原因', () async {
      final controller = SessionController(
        engine: _FakeEngine(failuresBeforeSuccess: 99),
      );

      await controller.open(_host, _credentials);

      final session = controller.sessions.single;
      expect(session.phase, SessionPhase.failed);
      expect(session.error, '认证失败');
    });

    test('failed 会话可以用原凭据 retry 成功', () async {
      final controller = SessionController(
        engine: _FakeEngine(failuresBeforeSuccess: 1),
      );
      final id = await controller.open(_host, _credentials);
      expect(controller.sessions.single.phase, SessionPhase.failed);

      await controller.retry(id);

      expect(controller.sessions.single.phase, SessionPhase.ready);
    });

    test('retry 只对 failed 会话生效', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final id = await controller.open(_host, _credentials);

      await controller.retry(id);

      expect(engine.calls, 1);
    });

    test('远端 shell 结束后自动关闭该标签', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      await controller.open(_host, _credentials);

      await engine.created.single._output.close();
      await Future<void>.delayed(Duration.zero);

      expect(controller.sessions, isEmpty);
      expect(controller.activeSessionId.value, isNull);
    });

    test('激活标签的 shell 断开后自动激活邻位标签', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      const other = Host(id: 'h2', name: 'db-01', hostname: '10.0.0.6');

      final first = await controller.open(_host, _credentials);
      await controller.open(other, _credentials);

      // 断开第二个（当前激活）标签的 shell。
      await engine.created[1]._output.close();
      await Future<void>.delayed(Duration.zero);

      expect(controller.sessions.single.id, first);
      expect(controller.activeSessionId.value, first);
    });

    test('关闭当前激活标签时激活邻位标签，并释放引擎会话', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);

      final first = await controller.open(_host, _credentials);
      final second = await controller.open(
        _host.copyWith(name: 'web-02'),
        _credentials,
      );
      expect(controller.activeSessionId.value, second);

      await controller.close(second);

      expect(controller.sessions.single.id, first);
      expect(controller.activeSessionId.value, first);
      expect(engine.created[1].closed, isTrue);
    });

    test('排序保留当前会话、终端和连接，关闭时按新顺序激活邻项', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);
      final third = await controller.open(_host, _credentials);
      final before = controller.sessions.toList();
      controller.activate(first);

      controller.reorder([third, first, second]);

      expect(controller.sessions, [
        same(before[2]),
        same(before[0]),
        same(before[1]),
      ]);
      expect(controller.activeSessionId.value, first);
      expect(controller.activeSession!.terminal, same(before[0].terminal));
      expect(engine.calls, 3);
      expect(engine.created.every((session) => !session.closed), isTrue);
      await controller.close(first);
      expect(controller.activeSessionId.value, second);
      expect(controller.sessions.map((session) => session.id), [third, second]);
      await controller.closeAll();
    });

    test('旧排序快照忽略已关闭和重复的标签，保留最新会话及新增标签', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);
      final third = await controller.open(_host, _credentials);
      final updated = controller.sessions.last.copyWith(
        host: _host.copyWith(name: 'updated'),
      );
      controller.sessions[2] = updated;
      await controller.close(first);
      final added = await controller.open(_host, _credentials);

      controller.reorder([third, third, first, 'missing', second]);

      expect(controller.sessions.map((session) => session.id), [
        third,
        second,
        added,
      ]);
      expect(controller.sessions.first, same(updated));
      expect(controller.activeSessionId.value, added);
      expect(engine.calls, 4);
      expect(
        engine.created.skip(1).every((session) => !session.closed),
        isTrue,
      );
      await controller.closeAll();
    });

    test('focusExisting：已有标签则聚焦并返回 true，无则返回 false', () async {
      final controller = SessionController(engine: _FakeEngine());
      const other = Host(id: 'h2', name: 'db-01', hostname: '10.0.0.6');

      final first = await controller.open(_host, _credentials);
      await controller.open(other, _credentials);
      expect(controller.activeSessionId.value, isNot(first));

      expect(controller.focusExisting(_host.id), isTrue);
      expect(controller.activeSessionId.value, first);
      expect(controller.focusExisting('h-missing'), isFalse);
    });

    test('同一主机可通过 open 多开会话，findByHost 返回首个', () async {
      final controller = SessionController(engine: _FakeEngine());

      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);

      expect(controller.sessions.length, 2);
      expect(second, isNot(first));
      expect(controller.findByHost(_host.id)?.id, first);
    });

    test('并发 close 同一会话不抛错且标签立即消失', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final id = await controller.open(_host, _credentials);

      // 点击 ✕ 与断线自动关闭可能同时触发。
      final both = Future.wait([controller.close(id), controller.close(id)]);
      // 列表同步移除，无需等待底层清理完成。
      expect(controller.sessions, isEmpty);
      await both;

      expect(engine.created.single.closed, isTrue);
      expect(controller.activeSessionId.value, isNull);
    });

    test('并发关闭多个标签不因索引过期而崩溃', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      const db = Host(id: 'h2', name: 'db-01', hostname: '10.0.0.6');
      const cache = Host(id: 'h3', name: 'redis-01', hostname: '10.0.0.7');

      final a = await controller.open(_host, _credentials);
      final b = await controller.open(db, _credentials);
      final c = await controller.open(cache, _credentials);

      await Future.wait([
        controller.close(a),
        controller.close(b),
        controller.close(c),
      ]);

      expect(controller.sessions, isEmpty);
      expect(controller.activeSessionId.value, isNull);
      expect(engine.created.every((s) => s.closed), isTrue);
    });

    test('引擎侧已断开导致 close 抛错时，标签仍被移除且不上抛', () async {
      final engine = _FakeEngine(throwOnSessionClose: true);
      final controller = SessionController(engine: engine);
      final id = await controller.open(_host, _credentials);

      await controller.close(id); // 不应向调用方抛错。

      expect(controller.sessions, isEmpty);
    });

    test('关闭其他标签保留并激活指定标签，释放其他终端和传输连接', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      await controller.open(_host, _credentials);
      final keep = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      expect(controller.activeSessionId.value, isNot(keep));

      final closing = controller.closeOthers(keep);
      expect(controller.sessions.single.id, keep);
      expect(controller.activeSessionId.value, keep);
      await closing;

      expect(engine.created[0].closed, isTrue);
      expect(engine.created[1].closed, isFalse);
      expect(engine.created[2].closed, isTrue);
      await controller.closeAll();
    });

    test('关闭其他标签时保留项已消失则不关闭任何标签', () async {
      final engine = _FakeEngine();
      final controller = SessionController(engine: engine);
      final first = await controller.open(_host, _credentials);
      final second = await controller.open(_host, _credentials);

      await controller.closeOthers('missing');

      expect(controller.sessions.map((s) => s.id), [first, second]);
      expect(controller.activeSessionId.value, second);
      expect(engine.created.every((s) => !s.closed), isTrue);
      await controller.closeAll();
    });

    test('关闭全部标签取消传输、释放所有连接并清空激活会话，可重复调用', () async {
      final engine = _FakeEngine(throwOnSessionClose: true);
      final transfers = TransferController();
      final controller = SessionController(
        engine: engine,
        transfers: transfers,
      );
      await controller.open(_host, _credentials);
      final transfer = await controller.open(
        _host,
        _credentials,
        kind: SessionKind.fileTransfer,
      );
      await controller.open(_host, _credentials);
      final task = transfers.startDownload(
        sessionId: transfer,
        engineSession: engine.created[1],
        remotePath: '/a.txt',
        localPath: '/tmp/a.txt',
      );

      final closing = controller.closeAll();
      expect(controller.sessions, isEmpty);
      expect(controller.activeSessionId.value, isNull);
      await closing;

      expect(controller.sessions, isEmpty);
      expect(controller.activeSessionId.value, isNull);
      expect(controller.activeSession, isNull);
      expect(task.status.value, TransferStatus.cancelled);
      expect(engine.created.every((s) => s.closed), isTrue);
      await controller.closeAll();
      transfers.onClose();
    });
  });
}
