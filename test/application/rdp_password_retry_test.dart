import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/fake_rdp_engine.dart';

const _host = Host(
  id: 'windows',
  name: 'Windows',
  hostname: 'windows.test',
  port: 3389,
  username: 'configured-user',
  serviceType: ServiceType.rdp,
);
const _credentials = SshCredentials.password(
  'wrong',
  username: 'selected-user',
);
const _failure = RdpAuthenticationException(
  'RDP NLA 认证失败：Windows 拒绝了登录（STATUS_LOGON_FAILURE / 0xC000006D）',
);

class _NoSsh implements SshEngine {
  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => throw StateError('unexpected SSH');
}

Future<RdpPasswordRequest> _waitForPassword(
  SessionController controller,
) async {
  for (var i = 0; i < 100; i++) {
    final session = controller.sessions.single;
    if (session.phase == SessionPhase.credentialsPending) {
      return session.passwordRequest!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('password prompt did not arrive');
}

void main() {
  test('密码被拒绝后等待输入，使用正确密码连接且后续重试复用本次凭据', () async {
    final engine = FakeRdpEngine(
      authenticationError: (credentials, _) =>
          credentials.password == ' correct ' ? null : _failure,
    );
    final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
    addTearDown(controller.closeAll);
    final opening = controller.open(_host, _credentials);
    final request = await _waitForPassword(controller);
    final id = controller.sessions.single.id;
    expect(request.host, same(_host));
    expect(request.username, 'selected-user');
    expect(
      controller.sessions.single.address,
      'selected-user@windows.test:3389',
    );
    expect(controller.sessions.single.error, _failure.message);
    expect(engine.authentications, 1);
    controller.confirmRdpPassword(id, request: request, password: ' correct ');
    await opening;
    expect(controller.sessions.single.phase, SessionPhase.ready);
    expect(
      controller.sessions.single.address,
      'selected-user@windows.test:3389',
    );
    expect(controller.sessions.single.passwordRequest, isNull);
    expect(controller.sessions.single.error, isNull);
    expect(engine.attempts.map((c) => c.password), ['wrong', ' correct ']);
    expect(engine.attempts.last.username, 'selected-user');
    expect(_credentials.password, 'wrong');
    await controller.desktopFailed(id, '断开');
    expect(
      controller.sessions.single.address,
      'selected-user@windows.test:3389',
    );
    await controller.retry(id);
    expect(engine.attempts.last.password, ' correct ');
    expect(
      controller.sessions.single.address,
      'selected-user@windows.test:3389',
    );
    expect(controller.sessions.single.phase, SessionPhase.ready);
  });

  test('再输错会重新提示，取消后重试先输入且不重发旧密码，迟到的确认无效', () async {
    final engine = FakeRdpEngine(
      authenticationError: (credentials, _) =>
          credentials.password == 'correct' ? null : _failure,
    );
    final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
    addTearDown(controller.closeAll);
    final opening = controller.open(_host, _credentials);
    final first = await _waitForPassword(controller);
    final id = controller.sessions.single.id;
    controller.confirmRdpPassword(id, request: first, password: '');
    expect(controller.sessions.single.phase, SessionPhase.credentialsPending);
    controller.confirmRdpPassword(id, request: first, password: 'still-wrong');
    await Future<void>.delayed(Duration.zero);
    final second = await _waitForPassword(controller);
    expect(second, isNot(same(first)));
    expect(engine.authentications, 2);
    controller.confirmRdpPassword(id, request: first, password: 'correct');
    expect(controller.sessions.single.phase, SessionPhase.credentialsPending);
    controller.confirmRdpPassword(id, request: second);
    await opening;
    expect(controller.sessions.single.phase, SessionPhase.failed);
    final retrying = controller.retry(id);
    final retried = await _waitForPassword(controller);
    expect(engine.authentications, 2);
    controller.confirmRdpPassword(id, request: retried, password: 'correct');
    await retrying;
    expect(engine.authentications, 3);
    expect(controller.sessions.single.phase, SessionPhase.ready);
  });

  for (final dispose in [false, true]) {
    test('${dispose ? '销毁控制器' : '关闭标签'}解除密码等待且不再连接', () async {
      final engine = FakeRdpEngine(authenticationError: (_, _) => _failure);
      final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
      final opening = controller.open(_host, _credentials);
      final request = await _waitForPassword(controller);
      final id = controller.sessions.single.id;
      if (dispose) {
        controller.onClose();
      } else {
        await controller.close(id);
      }
      controller.confirmRdpPassword(id, request: request, password: 'late');
      await opening;
      expect(engine.authentications, 1);
      expect(engine.created, isEmpty);
    });
  }

  test('网络错误保留失败原因，不进入密码输入流程', () async {
    final engine = FakeRdpEngine(
      authenticationError: (_, _) => const SshEngineException('网络不可用'),
    );
    final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
    addTearDown(controller.closeAll);
    await controller.open(_host, _credentials);
    expect(controller.sessions.single.phase, SessionPhase.failed);
    expect(controller.sessions.single.error, '网络不可用');
    expect(controller.sessions.single.passwordRequest, isNull);
  });

  test('通过 SSH 网关的目标密码错误只替换目标凭据', () async {
    const gateway = SshGateway(
      host: Host(id: 'gateway', name: 'Jump', hostname: 'jump.test'),
      credentials: SshCredentials.password(
        'gateway-password',
        username: 'gateway-user',
      ),
    );
    final engine = FakeRdpEngine(
      authenticationError: (credentials, _) =>
          credentials.password == 'correct' ? null : _failure,
    );
    final controller = SessionController(engine: _NoSsh(), rdpEngine: engine);
    addTearDown(controller.closeAll);
    final host = _host.copyWith(gatewayId: gateway.host.id);
    final opening = controller.open(host, _credentials, gateway: gateway);
    final request = await _waitForPassword(controller);
    expect(request.host, same(host));
    controller.confirmRdpPassword(
      controller.sessions.single.id,
      request: request,
      password: 'correct',
    );
    await opening;
    expect(engine.gateways, [same(gateway), same(gateway)]);
    expect(engine.attempts.last.password, 'correct');
    expect(engine.attempts.last.username, 'selected-user');
    expect(controller.sessions.single.phase, SessionPhase.ready);
  });
}
