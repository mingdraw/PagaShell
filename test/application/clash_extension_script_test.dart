import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/proxy/clash_extension_script.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';

const _gateway = Host(
  id: 'gateway-one',
  name: 'Office',
  hostname: 'private-relay.test',
  identityId: 'private-credential-ref',
  pageClientId: 'private-client-id',
);

void main() {
  test('导出域名/IP 规则，优先域名匹配并保留域名转 IP 网段匹配', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(
        mode: ProxyMode.rule,
        rules: [
          ProxyRule(type: ProxyRuleType.ip, value: '10.20.0.0/16'),
          ProxyRule(type: ProxyRuleType.domainExact, value: ' APP.Internal. '),
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'Corp.Internal.'),
          ProxyRule(type: ProxyRuleType.ip, value: 'fd00:1234::/48'),
          ProxyRule(type: ProxyRuleType.ip, value: '10.20.1.2'),
          ProxyRule(type: ProxyRuleType.ip, value: '2001:db8::1'),
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'corp.internal'),
        ],
      ),
    );
    final name = script.node['name'];
    expect(script.rules, [
      'DOMAIN,app.internal,$name',
      'DOMAIN-SUFFIX,corp.internal,$name',
      'IP-CIDR,10.20.0.0/16,$name',
      'IP-CIDR6,fd00:1234::/48,$name',
      'IP-CIDR,10.20.1.2/32,$name',
      'IP-CIDR6,2001:db8::1/128,$name',
    ]);
    expect(script.source, isNot(contains('no-resolve')));
    expect(script.source, isNot(contains(_gateway.hostname)));
    expect(script.source, isNot(contains(_gateway.identityId!)));
    expect(script.source, isNot(contains(_gateway.pageClientId)));
  });

  test('域名前缀保持字符串前缀及末尾点的语义', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(
        mode: ProxyMode.rule,
        rules: [ProxyRule(type: ProxyRuleType.domainPrefix, value: 'API.')],
      ),
    );
    final rule = script.rules.single.split(',');
    expect(rule.first, 'DOMAIN-REGEX');
    expect(rule[1], startsWith('(?i)^'));
    final prefix = RegExp(rule[1].substring(4), caseSensitive: false);
    expect(prefix.hasMatch('api.private.test'), isTrue);
    expect(prefix.hasMatch('API.private.test'), isTrue);
    expect(prefix.hasMatch('xapi.private.test'), isFalse);
    expect(prefix.hasMatch('api-evil.test'), isFalse);
    expect(prefix.hasMatch('apixprivate.test'), isFalse);
  });

  test('优先 HTTP(S) 当前端口，兼容仅 HTTPS 的旧配置', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(httpPort: 28080, httpsPort: 28443, socks5Enabled: true),
    );
    expect(script.node['type'], 'http');
    expect(script.node['server'], '127.0.0.1');
    expect(script.node['port'], 28080);
    expect(script.node, isNot(contains('tls')));
    final legacy = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(httpEnabled: false, httpsPort: 28443),
    );
    expect(legacy.node['port'], 28443);
  });

  test('仅启用 SOCKS5 时导出当前 TCP SOCKS5 端口', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(
        httpEnabled: false,
        httpsEnabled: false,
        socks5Enabled: true,
        socks5Port: 21080,
      ),
    );
    expect(script.node['type'], 'socks5');
    expect(script.node['port'], 21080);
    expect(script.node['udp'], isFalse);
  });

  test('全局模式只导出网关兜底，不导出规则模式下保存的规则', () {
    const rules = [
      ProxyRule(type: ProxyRuleType.domainSuffix, value: 'corp.internal'),
    ];
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(rules: rules),
    );
    expect(script.mode, ProxyMode.global);
    expect(script.rules, ['MATCH,${script.node['name']}']);
    expect(script.source, isNot(contains('corp.internal')));
    expect(script.source, isNot(contains('config.mode')));
    expect(script.source, isNot(contains('proxy-groups')));
  });

  test('规则模式没有配置规则时只添加节点', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway,
      const ProxyConfig(mode: ProxyMode.rule),
    );
    expect(script.mode, ProxyMode.rule);
    expect(script.rules, isEmpty);
    expect(script.source, isNot(contains('MATCH,')));
  });

  test('节点名可安全嵌入规则，同名网关按 ID 区分', () {
    final script = ClashExtensionScript.fromConfig(
      _gateway.copyWith(name: 'Office, "quotes"\nline\u2028separator'),
      const ProxyConfig(),
    );
    expect(script.node['name'] as String, isNot(contains(',')));
    expect(script.node['name'] as String, isNot(contains('\n')));
    expect(script.source, contains(r'\"quotes\"'));
    expect(script.source, contains(r'\u2028'));
    final other = ClashExtensionScript.fromConfig(
      const Host(id: 'gateway-two', name: 'Office', hostname: 'other.test'),
      const ProxyConfig(),
    );
    expect(
      other.node['name'],
      isNot(
        ClashExtensionScript.fromConfig(
          _gateway,
          const ProxyConfig(),
        ).node['name'],
      ),
    );
  });

  test('无可用监听协议时拒绝生成脚本', () {
    expect(
      () => ClashExtensionScript.fromConfig(
        _gateway,
        const ProxyConfig(httpEnabled: false, httpsEnabled: false),
      ),
      throwsStateError,
    );
  });
}
