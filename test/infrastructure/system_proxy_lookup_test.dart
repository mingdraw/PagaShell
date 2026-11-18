import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';
import 'package:pagashell/infrastructure/proxy/desktop_system_proxy_lookup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopSystemProxyLookup', () {
    test('解析环境变量及 no_proxy 绕过规则', () async {
      final lookup = DesktopSystemProxyLookup(
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        executable: (_) async => null,
        environment: const {
          'https_proxy': 'socks5h://user%40corp:p%40ss@127.0.0.1:1080',
          'http_proxy': 'http://127.0.0.1:8080',
          'no_proxy': 'localhost, 127.0.0.1, *.internal.test, .example.org',
        },
      );

      final https = await lookup.resolve(
        Uri.parse('https://api.openai.com/v1'),
      );
      expect(
        https,
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'user@corp',
          password: 'p@ss',
        ),
      );

      final http = await lookup.resolve(Uri.parse('http://example.com'));
      expect(
        http,
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.http,
          host: '127.0.0.1',
          port: 8080,
        ),
      );

      expect(
        await lookup.resolve(Uri.parse('https://api.internal.test/v1')),
        isNull,
      );
      expect(
        await lookup.resolve(Uri.parse('https://sub.example.org/v1')),
        isNull,
      );
      expect(await lookup.resolve(Uri.parse('http://localhost:8000')), isNull);
    });

    test('macOS / Windows 调用原生 resolve 通道并在缺失插件时回退环境变量', () async {
      const channel = MethodChannel('pagashell/system_proxy_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'resolve') {
              return {'protocol': 'socks5', 'host': '127.0.0.1', 'port': 1086};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final nativeLookup = DesktopSystemProxyLookup(
        channel: channel,
        isMacOS: true,
        isWindows: false,
        isLinux: false,
        environment: const {},
      );
      expect(
        await nativeLookup.resolve(Uri.parse('https://api.github.com')),
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.socks5,
          host: '127.0.0.1',
          port: 1086,
        ),
      );

      final missingChannelLookup = DesktopSystemProxyLookup(
        channel: const MethodChannel('pagashell/missing_proxy_test'),
        isMacOS: false,
        isWindows: true,
        isLinux: false,
        environment: const {'HTTPS_PROXY': 'http://127.0.0.1:7890'},
      );
      expect(
        await missingChannelLookup.resolve(Uri.parse('https://api.github.com')),
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.http,
          host: '127.0.0.1',
          port: 7890,
        ),
      );
    });

    test('Linux GNOME gsettings 与 KDE kreadconfig 解析', () async {
      final gnomeLookup = DesktopSystemProxyLookup(
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        environment: const {'XDG_CURRENT_DESKTOP': 'GNOME'},
        executable: (name) async =>
            name == 'gsettings' ? '/usr/bin/gsettings' : null,
        run: (_, args) async {
          final key = args.join(' ');
          return switch (key) {
            'get org.gnome.system.proxy mode' => ProcessResult(
              0,
              0,
              "'manual'\n",
              '',
            ),
            'get org.gnome.system.proxy ignore-hosts' => ProcessResult(
              0,
              0,
              "['localhost', '*.local']\n",
              '',
            ),
            'get org.gnome.system.proxy.https host' => ProcessResult(
              0,
              0,
              "'127.0.0.1'\n",
              '',
            ),
            'get org.gnome.system.proxy.https port' => ProcessResult(
              0,
              0,
              '7890\n',
              '',
            ),
            _ => ProcessResult(0, 0, "''\n", ''),
          };
        },
      );
      expect(
        await gnomeLookup.resolve(Uri.parse('https://api.openai.com')),
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.http,
          host: '127.0.0.1',
          port: 7890,
        ),
      );
      expect(
        await gnomeLookup.resolve(Uri.parse('https://printer.local')),
        isNull,
      );

      final kdeLookup = DesktopSystemProxyLookup(
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        environment: const {'XDG_CURRENT_DESKTOP': 'KDE'},
        executable: (name) async =>
            name == 'kreadconfig6' ? '/usr/bin/kreadconfig6' : null,
        run: (_, args) async {
          final key = args.last;
          return switch (key) {
            'ProxyType' => ProcessResult(0, 0, '1\n', ''),
            'NoProxyFor' => ProcessResult(0, 0, '127.0.0.1,localhost\n', ''),
            'httpsProxy' => ProcessResult(0, 0, '\n', ''),
            'httpProxy' => ProcessResult(0, 0, '\n', ''),
            'socksProxy' => ProcessResult(0, 0, '127.0.0.1 10808\n', ''),
            _ => ProcessResult(0, 0, '\n', ''),
          };
        },
      );
      expect(
        await kdeLookup.resolve(Uri.parse('https://api.github.com')),
        const AppProxyEndpoint(
          protocol: AppProxyProtocol.socks5,
          host: '127.0.0.1',
          port: 10808,
        ),
      );
    });
  });
}
