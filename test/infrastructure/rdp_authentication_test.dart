import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/rust_ssh_engine.dart';
import 'package:pagashell/src/rust/api/desktop.dart';
import 'package:pagashell/src/rust/frb_generated.dart';

class _RdpApi extends RustLibApi {
  String? username;
  String? domain;
  int authentications = 0;
  int disconnects = 0;

  @override
  Future<DesktopHandshake> crateApiDesktopDesktopHandshake({
    required String host,
    required int port,
    int? sshGatewayId,
  }) async => const DesktopHandshake(sessionId: 1, fingerprint: 'test-cert');

  @override
  Future<void> crateApiDesktopDesktopAuthenticate({
    required int sessionId,
    required String expectedFingerprint,
    required String username,
    required String password,
    required String domain,
  }) async {
    authentications++;
    this.username = username;
    this.domain = domain;
  }

  @override
  Future<void> crateApiDesktopDesktopDisconnect({
    required int sessionId,
  }) async {
    disconnects++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late _RdpApi api;
  setUp(() {
    api = _RdpApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  const host = Host(
    id: 'rdp',
    name: 'Windows',
    hostname: 'windows.test',
    port: 3389,
    username: 'host-user',
    serviceType: ServiceType.rdp,
    rdpDomain: 'HOST-CORP',
  );

  test('RDP 原生认证采用凭证的用户名和域', () async {
    final session = await const RustRdpEngine().connectDesktop(
      host,
      const SshCredentials.password(
        'test-password',
        username: 'administrator',
        rdpDomain: 'CREDENTIAL-CORP',
      ),
      verifyHostKey: (_) async => true,
    );
    expect(api.username, 'administrator');
    expect(api.domain, 'CREDENTIAL-CORP');
    await session.close();
    expect(api.disconnects, 1);
  });

  test('旧凭证未设置域时沿用服务域，直接账号密码保持原配置', () async {
    for (final credentials in const [
      SshCredentials.password('test-password', username: 'legacy-user'),
      SshCredentials.password('test-password'),
    ]) {
      final session = await const RustRdpEngine().connectDesktop(
        host,
        credentials,
        verifyHostKey: (_) async => true,
      );
      expect(api.domain, 'HOST-CORP');
      expect(api.username, credentials.username ?? 'host-user');
      await session.close();
    }
  });

  test('证书未确认时不发送凭证和域', () async {
    await expectLater(
      const RustRdpEngine().connectDesktop(
        host,
        const SshCredentials.password('test-password', rdpDomain: 'CORP'),
        verifyHostKey: (_) async => false,
      ),
      throwsA(isA<SshEngineException>()),
    );
    expect(api.authentications, 0);
    expect(api.disconnects, 1);
  });
}
