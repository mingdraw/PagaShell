import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/proxy_config.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/infrastructure/proxy/desktop_system_proxy.dart';
import 'package:pagashell/infrastructure/proxy/linux_system_proxy.dart';
import 'package:pagashell/infrastructure/storage/application_directories.dart';

const _base = 'org.gnome.system.proxy';

class _Desktop {
  _Desktop({this.kde = false, this.version = '6'}) {
    if (kde) return;
    values.addAll({
      '$_base|mode': "'none'",
      '$_base|autoconfig-url': "'https://old.invalid/proxy.pac'",
      '$_base|ignore-hosts': "['localhost', '10.0.0.0/8']",
      '$_base|use-same-proxy': 'true',
      '$_base.http|use-authentication': 'true',
      for (final protocol in ['http', 'https', 'ftp', 'socks']) ...{
        '$_base.$protocol|host': "'old.invalid'",
        '$_base.$protocol|port': '1234',
      },
    });
  }
  final bool kde;
  final String version;
  final values = <String, String>{};
  final writes = <List<String>>[];
  int reloads = 0;
  String? failKey;
  bool failReload = false, writable = true;

  Future<String?> executable(String name) async =>
      (kde
              ? ['kreadconfig$version', 'kwriteconfig$version', 'dbus-send']
              : ['gsettings'])
          .contains(name)
      ? name
      : null;

  Future<ProcessResult> run(String tool, List<String> args) async {
    var output = '';
    var exit = 0;
    if (tool == 'dbus-send') {
      expect(args, [
        '--session',
        '--type=signal',
        '/KIO/Scheduler',
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
        'string:',
      ]);
      reloads++;
      exit = failReload ? 1 : 0;
    } else if (tool == 'gsettings') {
      switch (args.first) {
        case 'list-schemas':
          output = _base;
        case 'writable':
          output = writable ? 'true' : 'false';
        case 'get':
          output = values['${args[1]}|${args[2]}']!;
          if (output == '[]') output = '@as []';
        case 'set':
          final key = '${args[1]}|${args[2]}';
          writes.add(args);
          if (failKey == key) {
            exit = 1;
          } else {
            values[key] = args[3];
          }
      }
    } else {
      final key = args[args.indexOf('--key') + 1];
      if (tool.startsWith('kreadconfig')) {
        output = values[key] ?? args[args.indexOf('--default') + 1];
      } else {
        writes.add(args);
        if (failKey == key) {
          exit = 1;
        } else if (args.contains('--delete')) {
          values.remove(key);
        } else {
          values[key] = args.last;
        }
      }
    }
    return ProcessResult(0, exit, '$output\n', '');
  }

  DesktopSystemProxy service({Map<String, String>? environment}) =>
      DesktopSystemProxy(
        backend: LinuxSystemProxy(
          run: run,
          executable: executable,
          environment:
              environment ?? {'XDG_CURRENT_DESKTOP': kde ? 'KDE' : 'GNOME'},
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('原生接口只传本地协议端口、所有者，恢复沿用相同所有者', () async {
    const channel = MethodChannel('pagashell/system_proxy_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final lease =
        DesktopSystemProxy(backend: const NativeSystemProxy(channel: channel))
            .createLease(
              const ProxyConfig(
                httpPort: 19080,
                httpsPort: 19080,
                socks5Enabled: true,
                socks5Port: 19081,
              ),
            );
    await lease.enable();
    await lease.restore();
    expect(calls.map((call) => call.method), ['enable', 'restore']);
    final enable = calls.first.arguments as Map<Object?, Object?>;
    expect(enable['httpPort'], 19080);
    expect(enable['httpsPort'], 19080);
    expect(enable['socksPort'], 19081);
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['owner'],
      enable['owner'],
    );
    expect(enable.keys.toSet(), {
      'owner',
      'httpPort',
      'httpsPort',
      'socksPort',
    });
  });

  for (final kind in ['GNOME', 'KDE5', 'KDE6']) {
    test('$kind 设置 HTTP CONNECT/SOCKS5 并恢复原有配置与缺失键', () async {
      final desktop = _Desktop(
        kde: kind != 'GNOME',
        version: kind.endsWith('5') ? '5' : '6',
      );
      final before = Map<String, String>.of(desktop.values);
      final lease = desktop.service().createLease(
        const ProxyConfig(socks5Enabled: true),
      );
      await lease.enable();
      if (desktop.kde) {
        expect(desktop.values['ProxyType'], '1');
        expect(desktop.values['httpsProxy'], 'http://127.0.0.1:18080');
        expect(desktop.values['socksProxy'], 'socks://127.0.0.1:1080');
        expect(desktop.values['ReversedException'], 'false');
      } else {
        expect(desktop.values['$_base|mode'], "'manual'");
        expect(desktop.values['$_base.https|host'], "'127.0.0.1'");
        expect(desktop.values['$_base.socks|port'], '1080');
        expect(desktop.values['$_base|ignore-hosts'], '[]');
        expect(desktop.values['$_base.http|use-authentication'], 'false');
      }
      await lease.restore();
      expect(desktop.values, before);
      if (desktop.kde) expect(desktop.reloads, 2);
      await lease.restore(); // idempotent
    });
  }

  for (final active in ["'manual'", "'auto'"]) {
    test('GNOME 既有 $active 代理冲突不写配置', () async {
      final desktop = _Desktop()..values['$_base|mode'] = active;
      final lease = desktop.service().createLease(const ProxyConfig());
      await expectLater(lease.enable(), throwsA(isA<SystemProxyException>()));
      await lease.restore();
      expect(desktop.writes, isEmpty);
    });
  }

  for (final mode in ['1', '2', '3', '4']) {
    test('KDE 已有静态/PAC/WPAD/环境代理 $mode 不覆盖', () async {
      final desktop = _Desktop(kde: true)..values['ProxyType'] = mode;
      final lease = desktop.service().createLease(const ProxyConfig());
      await expectLater(lease.enable(), throwsA(isA<SystemProxyException>()));
      await lease.restore();
      expect(desktop.writes, isEmpty);
      expect(desktop.values['ProxyType'], mode);
    });
  }

  for (final kde in [false, true]) {
    test('${kde ? 'KDE' : 'GNOME'} 其他应用接管后停止不覆盖其配置', () async {
      final desktop = _Desktop(kde: kde);
      final lease = desktop.service().createLease(const ProxyConfig());
      await lease.enable();
      for (final protocol in ['http', 'https']) {
        desktop.values[kde ? '${protocol}Proxy' : '$_base.$protocol|host'] = kde
            ? 'http://other.invalid:8080'
            : "'other.invalid'";
      }
      final changed = Map<String, String>.of(desktop.values);
      final count = desktop.writes.length;
      await lease.restore();
      expect(desktop.values, changed);
      expect(desktop.writes, hasLength(count));
    });
  }

  for (final kde in [false, true]) {
    test('${kde ? 'KDE' : 'GNOME'} 部分接管仍引用本应用时保持可重试，不修改其他应用', () async {
      final desktop = _Desktop(kde: kde);
      final lease = desktop.service().createLease(const ProxyConfig());
      await lease.enable();
      desktop.values[kde ? 'httpProxy' : '$_base.http|host'] = kde
          ? 'http://other.invalid:8080'
          : "'other.invalid'";
      final changed = Map<String, String>.of(desktop.values);
      final count = desktop.writes.length;
      await expectLater(lease.restore(), throwsA(isA<SystemProxyException>()));
      expect(desktop.values, changed);
      expect(desktop.writes, hasLength(count));
      desktop.values[kde ? 'httpsProxy' : '$_base.https|host'] = kde
          ? 'http://other.invalid:8080'
          : "'other.invalid'";
      await lease.restore();
    });

    test('${kde ? 'KDE' : 'GNOME'} 无关绕过列表变更保留且不会阻止取消本应用代理', () async {
      final desktop = _Desktop(kde: kde);
      final lease = desktop.service().createLease(const ProxyConfig());
      await lease.enable();
      final key = kde ? 'NoProxyFor' : '$_base|ignore-hosts';
      final value = kde ? 'external.invalid' : "['external.invalid']";
      desktop.values[key] = value;
      await lease.restore();
      expect(desktop.values[key], value);
      expect(
        desktop.values[kde ? 'ProxyType' : '$_base|mode'],
        kde ? isNull : "'none'",
      );
    });
  }

  test('GNOME 中途写失败可回滚已写字段，权限不足不写入', () async {
    final desktop = _Desktop()..failKey = '$_base.https|port';
    final before = Map<String, String>.of(desktop.values);
    final service = desktop.service();
    final lease = service.createLease(const ProxyConfig());
    await expectLater(lease.enable(), throwsA(isA<SystemProxyException>()));
    desktop.failKey = null;
    await lease.restore();
    expect(desktop.values, before);
    desktop.writable = false;
    final count = desktop.writes.length;
    final denied = service.createLease(const ProxyConfig());
    await expectLater(denied.enable(), throwsA(isA<SystemProxyException>()));
    await denied.restore();
    expect(desktop.writes, hasLength(count));
  });

  test('KDE 刷新失败保留可重试恢复的句柄', () async {
    final desktop = _Desktop(kde: true);
    final before = Map<String, String>.of(desktop.values);
    final lease = desktop.service().createLease(const ProxyConfig());
    await lease.enable();
    desktop.failReload = true;
    await expectLater(lease.restore(), throwsA(isA<SystemProxyException>()));
    desktop.failReload = false;
    await lease.restore();
    expect(desktop.values, before);
  });

  test('Linux 继承的代理环境变量存在时拒绝自动设置', () async {
    final desktop = _Desktop();
    final lease = desktop
        .service(environment: {'HTTP_PROXY': 'http://other.invalid:8080'})
        .createLease(const ProxyConfig());
    await expectLater(lease.enable(), throwsA(isA<SystemProxyException>()));
    await lease.restore();
    expect(desktop.writes, isEmpty);
  });

  test('非 GNOME/KDE 且无可用接口明确失败，不写环境或系统文件', () async {
    final lease = DesktopSystemProxy(
      backend: LinuxSystemProxy(
        environment: {},
        executable: (_) async => null,
        run: (_, _) => throw StateError('must not run'),
      ),
    ).createLease(const ProxyConfig());
    await expectLater(lease.enable(), throwsA(isA<SystemProxyException>()));
    await lease.restore();
  });

  test('已有沙盒文件沿用原路径，不复制数据库或保险库', () async {
    final temp = await Directory.systemTemp.createTemp(
      'pagashell-legacy-paths-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final legacy = await Directory('${temp.path}/container').create();
    final current = await Directory('${temp.path}/current').create();
    for (final filename in ['pagashell.sqlite', 'credentials.vault']) {
      expect(
        await ApplicationDirectories.preferExisting(legacy, current, filename),
        current,
      );
      await File('${legacy.path}/$filename').writeAsString('test-placeholder');
      expect(
        await ApplicationDirectories.preferExisting(legacy, current, filename),
        legacy,
      );
      expect(File('${current.path}/$filename').existsSync(), isFalse);
    }
  });
}
