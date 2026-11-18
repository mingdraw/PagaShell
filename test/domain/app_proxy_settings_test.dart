import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';

void main() {
  group('AppProxySettings.validateAddress / parseAddress', () {
    test('接受 IPv4、域名和带方括号的 IPv6 地址与端口', () {
      final ipv4 = AppProxySettings.parseAddress(
        ' 127.0.0.1:7890 ',
        AppProxyProtocol.http,
      );
      expect(ipv4, isNotNull);
      expect(ipv4!.host, '127.0.0.1');
      expect(ipv4.port, 7890);
      expect(ipv4.address, '127.0.0.1:7890');

      final domain = AppProxySettings.parseAddress(
        'proxy.corp.local:8443',
        AppProxyProtocol.https,
        username: 'alice',
        password: 'secret',
      );
      expect(domain, isNotNull);
      expect(domain!.protocol, AppProxyProtocol.https);
      expect(domain.host, 'proxy.corp.local');
      expect(domain.port, 8443);
      expect(domain.hasCredentials, isTrue);

      final ipv6 = AppProxySettings.parseAddress(
        '[::1]:1080',
        AppProxyProtocol.socks5,
      );
      expect(ipv6, isNotNull);
      expect(ipv6!.host, '::1');
      expect(ipv6.port, 1080);
      expect(ipv6.address, '[::1]:1080');
    });

    test('拒绝空值、缺省端口、越界端口、协议前缀和未加括号的 IPv6', () {
      expect(AppProxySettings.validateAddress(''), '必填');
      expect(
        AppProxySettings.validateAddress('127.0.0.1'),
        '请填写包含端口的代理地址，例如 127.0.0.1:7890',
      );
      expect(
        AppProxySettings.validateAddress('127.0.0.1:0'),
        '请填写有效的端口（1-65535）',
      );
      expect(
        AppProxySettings.validateAddress('127.0.0.1:65536'),
        '请填写有效的端口（1-65535）',
      );
      expect(
        AppProxySettings.validateAddress('http://127.0.0.1:7890'),
        '请填写主机与端口，例如 127.0.0.1:7890',
      );
      expect(
        AppProxySettings.validateAddress('user:pass@127.0.0.1:7890'),
        '请填写主机与端口，例如 127.0.0.1:7890',
      );
      expect(
        AppProxySettings.validateAddress('::1:1080'),
        'IPv6 地址请使用方括号，例如 [::1]:1080',
      );
      expect(AppProxySettings.validateAddress('[not-ipv6]:1080'), '请填写有效的代理地址');
      expect(
        AppProxySettings.parseAddress('127.0.0.1', AppProxyProtocol.http),
        isNull,
      );
    });

    test('拒绝用户名或密码中的控制字符', () {
      expect(AppProxySettings.validateCredential('alice'), isNull);
      expect(
        AppProxySettings.validateCredential('alice\nbob'),
        '用户名或密码不能包含换行或控制字符',
      );
      expect(
        AppProxySettings.validateCredential('pass\r'),
        '用户名或密码不能包含换行或控制字符',
      );
    });
  });
}
