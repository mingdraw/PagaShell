import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';

void main() {
  const host = Host(
    id: 'h1',
    name: 'web-01',
    hostname: '10.0.0.5',
    username: 'deploy',
    tags: ['prod'],
  );

  group('Host', () {
    test('默认端口 22 时地址不显示端口', () {
      expect(host.address, 'deploy@10.0.0.5');
    });

    test('非默认端口显示在地址中', () {
      expect(host.copyWith(port: 2222).address, 'deploy@10.0.0.5:2222');
    });

    test('searchText 覆盖名称、地址、用户名与标签', () {
      expect(host.searchText, contains('web-01'));
      expect(host.searchText, contains('10.0.0.5'));
      expect(host.searchText, contains('deploy'));
      expect(host.searchText, contains('prod'));
    });

    test('copyWith 不改变 id，相等性按 id 判断', () {
      final renamed = host.copyWith(name: 'renamed');
      expect(renamed.id, host.id);
      expect(renamed, equals(host));
    });

    test('copyWith 可绑定与显式清除凭证', () {
      final bound = host.copyWith(identityId: 'idn-1');
      expect(bound.identityId, 'idn-1');
      // 不传参数时保持原值。
      expect(bound.copyWith(name: 'x').identityId, 'idn-1');
      // 显式传 null 清除绑定。
      expect(bound.copyWith(identityId: null).identityId, isNull);
    });
  });
}
