import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/proxy/proxy_rule_preview.dart';

void main() {
  const network = ProxyRule(type: ProxyRuleType.ip, value: '192.0.2.128/25');
  const ipv6 = ProxyRule(type: ProxyRuleType.ip, value: '2001:db8:8000::/33');
  const exact = ProxyRule(
    type: ProxyRuleType.domainExact,
    value: 'private.test',
  );
  const suffix = ProxyRule(
    type: ProxyRuleType.domainSuffix,
    value: 'internal.test.',
  );
  const prefix = ProxyRule(type: ProxyRuleType.domainPrefix, value: 'api.');
  const config = ProxyConfig(
    mode: ProxyMode.rule,
    rules: [network, ipv6, exact, suffix, prefix],
  );

  test('预览优先匹配域名，保留大小写、根点和标签边界的语义', () {
    expect(previewProxyRules(config, ' PRIVATE.TEST. ').rule, same(exact));
    expect(previewProxyRules(config, 'node.Internal.Test.').rule, same(suffix));
    expect(previewProxyRules(config, 'API.other.test.').rule, same(prefix));
    expect(
      previewProxyRules(config, 'notinternal.test').route,
      ProxyPreviewRoute.needsDns,
    );
    expect(
      previewProxyRules(config, 'api-other.test').route,
      ProxyPreviewRoute.needsDns,
    );
    expect(
      previewProxyRules(config, 'sub.private.test').route,
      ProxyPreviewRoute.needsDns,
    );
  });

  test('预览匹配 IPv4、IPv6 和给定 DNS 结果，未提供结果时不假定直连', () {
    expect(previewProxyRules(config, '192.0.2.128').rule, same(network));
    expect(
      previewProxyRules(config, '192.0.2.127').route,
      ProxyPreviewRoute.direct,
    );
    expect(previewProxyRules(config, '[2001:DB8:8000::11]').rule, same(ipv6));
    expect(
      previewProxyRules(config, '2001:db8:7fff::1').route,
      ProxyPreviewRoute.direct,
    );
    expect(
      previewProxyRules(config, 'site.test').route,
      ProxyPreviewRoute.needsDns,
    );
    expect(
      previewProxyRules(
        config,
        'site.test',
        dnsAddresses: ['192.0.2.1', '2001:db8:9000::1'],
      ).rule,
      same(ipv6),
    );
    expect(
      previewProxyRules(config, 'site.test', dnsAddresses: ['192.0.2.1']).route,
      ProxyPreviewRoute.direct,
    );
    expect(
      () => previewProxyRules(config, 'site.test', dnsAddresses: ['invalid']),
      throwsStateError,
    );
  });

  test('预览与原生代理一致拒绝非标准 CIDR 前缀', () {
    for (final value in ['192.0.2.0/0x10', '192.0.2.0/+16', '192.0.2.0/016']) {
      final draft = ProxyConfig(
        mode: ProxyMode.rule,
        rules: [ProxyRule(type: ProxyRuleType.ip, value: value)],
      );
      expect(() => previewProxyRules(draft, '192.0.2.128'), throwsStateError);
    }
  });
}
