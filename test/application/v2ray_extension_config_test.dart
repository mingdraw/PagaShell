import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/proxy/v2ray_extension_config.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';

const _gateway = Host(
  id: 'office',
  name: 'Office',
  hostname: 'private-gateway.example',
  identityId: 'private-credential-ref',
  pageClientId: 'private-client-id',
);
const _tag = 'pagashell-office';

typedef _Json = Map<String, Object?>;

_Json _decode(String source) => jsonDecode(source) as _Json;

List<_Json> _rules(_Json config) =>
    ((config['routing'] as _Json)['rules'] as List<Object?>).cast<_Json>();

const _existing = <String, Object?>{
  'log': {'loglevel': 'warning'},
  'dns': {
    'servers': ['localhost'],
  },
  'inbounds': [
    {'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks'},
  ],
  'outbounds': [
    {'tag': 'original', 'protocol': 'freedom'},
    {'tag': 'block', 'protocol': 'blackhole'},
  ],
  'routing': {
    'domainStrategy': 'IPIfNonMatch',
    'rules': [
      {
        'type': 'field',
        'domain': ['domain:ads.example'],
        'outboundTag': 'block',
      },
      {'type': 'field', 'port': '0-65535', 'outboundTag': 'original'},
    ],
  },
};

void main() {
  test('导出本机 HTTP 出站，域名优先，IPv4/IPv6 单独成规则', () {
    final export = V2RayExtensionConfig(
      _gateway,
      const ProxyConfig(
        mode: ProxyMode.rule,
        httpPort: 28080,
        socks5Enabled: true,
        rules: [
          ProxyRule(type: ProxyRuleType.ip, value: '10.20.1.2'),
          ProxyRule(type: ProxyRuleType.domainExact, value: ' APP.Internal. '),
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'Corp.Internal.'),
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'corp.internal'),
          ProxyRule(type: ProxyRuleType.domainPrefix, value: 'API.'),
          ProxyRule(type: ProxyRuleType.ip, value: 'fd00:1234::/48'),
          ProxyRule(type: ProxyRuleType.ip, value: '2001:db8::1'),
        ],
      ),
    );
    final config = _decode(export.source);
    expect(config['outbounds'], [
      {'tag': 'direct', 'protocol': 'freedom'},
      {
        'tag': _tag,
        'protocol': 'http',
        'settings': {
          'servers': [
            {'address': '127.0.0.1', 'port': 28080},
          ],
        },
      },
    ]);
    expect((config['routing'] as _Json)['domainStrategy'], 'IPOnDemand');
    expect(_rules(config), [
      {
        'type': 'field',
        'network': 'tcp',
        'domain': [
          'full:app.internal',
          'domain:corp.internal',
          r'regexp:(?i)^api\.',
        ],
        'outboundTag': _tag,
      },
      {
        'type': 'field',
        'network': 'tcp',
        'ip': ['10.20.1.2/32', 'fd00:1234::/48', '2001:db8::1/128'],
        'outboundTag': _tag,
      },
    ]);
    expect(export.source, isNot(contains(_gateway.hostname)));
    expect(export.source, isNot(contains(_gateway.identityId!)));
    expect(export.source, isNot(contains(_gateway.pageClientId)));
  });

  test('仅 SOCKS5 时导出 SOCKS 出站，独立配置避开活动监听端口', () {
    final export = V2RayExtensionConfig(
      _gateway,
      const ProxyConfig(
        httpEnabled: false,
        httpsEnabled: false,
        socks5Enabled: true,
        socks5Port: 10808,
      ),
    );
    final config = _decode(export.source);
    expect(config['inbounds'], [
      {
        'tag': 'socks',
        'listen': '127.0.0.1',
        'port': 10810,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': false},
      },
      {'tag': 'http', 'listen': '127.0.0.1', 'port': 10811, 'protocol': 'http'},
    ]);
    expect((config['outbounds'] as List<Object?>).last, {
      'tag': _tag,
      'protocol': 'socks',
      'settings': {
        'servers': [
          {'address': '127.0.0.1', 'port': 10808},
        ],
      },
    });
    expect(_rules(config), [
      {'type': 'field', 'network': 'tcp', 'outboundTag': _tag},
    ]);
  });

  test('规则模式保留原有出站、DNS 和默认路由，允许重复合并', () {
    final export = V2RayExtensionConfig(
      _gateway,
      const ProxyConfig(
        mode: ProxyMode.rule,
        rules: [
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'corp.internal'),
        ],
      ),
    );
    final output = export.mergeInto(jsonEncode(_existing));
    final merged = _decode(output);
    expect(merged['inbounds'], _existing['inbounds']);
    expect(merged['dns'], _existing['dns']);
    expect(
      (merged['outbounds'] as List<Object?>).take(2),
      _existing['outbounds'],
    );
    expect(_rules(merged).first['outboundTag'], _tag);
    expect(_rules(merged).skip(1), _rules(_existing));
    expect((merged['routing'] as _Json)['domainStrategy'], 'IPIfNonMatch');
    expect(export.mergeInto(output), output);

    final noRules = V2RayExtensionConfig(
      _gateway,
      const ProxyConfig(mode: ProxyMode.rule),
    );
    expect(_rules(_decode(noRules.mergeInto(output))), _rules(_existing));
  });

  test('全局模式保留具体规则，TCP 兜底排在原有全端口兜底之前', () {
    final export = V2RayExtensionConfig(
      _gateway,
      const ProxyConfig(
        rules: [
          ProxyRule(type: ProxyRuleType.domainSuffix, value: 'stale.internal'),
        ],
      ),
    );
    final merged = export.mergeInto(jsonEncode(_existing));
    expect(_rules(_decode(merged)), [
      _rules(_existing).first,
      {'type': 'field', 'network': 'tcp', 'outboundTag': _tag},
      _rules(_existing).last,
    ]);
    expect(merged, isNot(contains('stale.internal')));
    expect(export.mergeInto(merged), merged);
  });

  test('拒绝不同格式的 JSON、路由脚本和监听端口冲突', () {
    final export = V2RayExtensionConfig(_gateway, const ProxyConfig());
    expect(
      () => export.mergeInto(
        '''{"inbounds":[{"type":"mixed"}],"outbounds":[{"type":"direct"}]}''',
      ),
      throwsA(isA<V2RayConfigException>()),
    );
    expect(
      () => export.mergeInto(
        jsonEncode({
          ..._existing,
          'routing': {'script': 'route.lua'},
        }),
      ),
      throwsA(isA<V2RayConfigException>()),
    );
    expect(
      () => export.mergeInto(
        jsonEncode({
          ..._existing,
          'inbounds': [
            {'listen': '127.0.0.1', 'port': '18079-18081', 'protocol': 'socks'},
          ],
        }),
      ),
      throwsA(
        isA<V2RayConfigException>().having(
          (error) => error.port,
          'port',
          18080,
        ),
      ),
    );
  });
}
