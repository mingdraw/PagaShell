import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/network/app_proxy_resolver.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_proxy_settings.dart';
import 'package:pagashell/domain/proxy/system_proxy_lookup.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/in_memory_settings_repository.dart';

class _FakeSystemLookup implements SystemProxyLookup {
  _FakeSystemLookup(this.endpoint);
  AppProxyEndpoint? endpoint;
  int calls = 0;

  @override
  Future<AppProxyEndpoint?> resolve(Uri target) async {
    calls++;
    return endpoint;
  }
}

class _TestHttpProxy {
  _TestHttpProxy._(this._server, {this.expectedAuth});

  final ServerSocket _server;
  final String? expectedAuth;
  int requests = 0;

  int get port => _server.port;

  static Future<_TestHttpProxy> start({String? expectedAuth}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _TestHttpProxy._(server, expectedAuth: expectedAuth);
    server.listen(proxy._handle);
    return proxy;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final iterator = StreamIterator(client);
    final buf = <int>[];
    Socket? target;
    try {
      while (true) {
        final idx = _findHeaderEnd(buf);
        if (idx >= 0) break;
        if (!await iterator.moveNext()) return;
        buf.addAll(iterator.current);
      }
      final idx = _findHeaderEnd(buf);
      final headerBytes = buf.sublist(0, idx);
      final leftover = buf.sublist(idx + 4);
      final lines = latin1.decode(headerBytes).split('\r\n');
      final parts = lines.first.split(' ');
      final method = parts[0].toUpperCase();
      final rawTarget = parts[1];
      if (expectedAuth != null) {
        final authHeader = lines
            .where((l) => l.toLowerCase().startsWith('proxy-authorization:'))
            .firstOrNull;
        final value = authHeader?.split(':').skip(1).join(':').trim();
        if (value != 'Basic ${base64Encode(utf8.encode(expectedAuth!))}') {
          client.add(
            ascii.encode(
              'HTTP/1.1 407 Proxy Authentication Required\r\n'
              'Proxy-Authenticate: Basic realm="test"\r\n'
              'Connection: close\r\n\r\n',
            ),
          );
          await client.close();
          return;
        }
      }
      requests++;
      final uri = Uri.parse(rawTarget);
      target = await Socket.connect(uri.host, uri.hasPort ? uri.port : 80);
      final originPath =
          '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      final out = StringBuffer()..write('$method $originPath ${parts[2]}\r\n');
      for (final line in lines.skip(1)) {
        final lower = line.toLowerCase();
        if (lower.startsWith('proxy-authorization:') ||
            lower.startsWith('proxy-connection:')) {
          continue;
        }
        out.write('$line\r\n');
      }
      out.write('\r\n');
      target.add(latin1.encode(out.toString()));
      if (leftover.isNotEmpty) target.add(Uint8List.fromList(leftover));
      await target.flush();

      await Future.wait([
        () async {
          while (await iterator.moveNext()) {
            target!.add(iterator.current);
          }
          await target!.close();
        }(),
        target.cast<List<int>>().pipe(client),
      ]);
    } on Object {
      // 测试清理期间忽略连接关闭异常。
    } finally {
      await iterator.cancel();
      client.destroy();
      target?.destroy();
    }
  }

  static int _findHeaderEnd(List<int> data) {
    for (var i = 0; i <= data.length - 4; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

class _TestSocks5Proxy {
  _TestSocks5Proxy._(this._server, {this.username, this.password});

  final ServerSocket _server;
  final String? username;
  final String? password;
  int requests = 0;

  int get port => _server.port;

  static Future<_TestSocks5Proxy> start({
    String? username,
    String? password,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _TestSocks5Proxy._(
      server,
      username: username,
      password: password,
    );
    server.listen(proxy._handle);
    return proxy;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final iterator = StreamIterator(client);
    final buf = <int>[];
    Socket? target;
    Future<List<int>?> readExact(int count) async {
      while (buf.length < count) {
        if (!await iterator.moveNext()) return null;
        buf.addAll(iterator.current);
      }
      final out = buf.sublist(0, count);
      buf.removeRange(0, count);
      return out;
    }

    try {
      final header = await readExact(2);
      if (header == null || header[0] != 0x05) return;
      final methods = await readExact(header[1]);
      if (methods == null) return;
      final needsAuth = username != null;
      if (needsAuth) {
        if (!methods.contains(0x02)) {
          client.add(const [0x05, 0xff]);
          return;
        }
        client.add(const [0x05, 0x02]);
        final ver = await readExact(2);
        if (ver == null || ver[0] != 0x01) return;
        final uBytes = await readExact(ver[1]);
        final pLen = await readExact(1);
        if (uBytes == null || pLen == null) return;
        final pBytes = await readExact(pLen[0]);
        if (pBytes == null) return;
        if (utf8.decode(uBytes) != username ||
            utf8.decode(pBytes) != (password ?? '')) {
          client.add(const [0x01, 0x01]);
          return;
        }
        client.add(const [0x01, 0x00]);
      } else {
        client.add(const [0x05, 0x00]);
      }

      final req = await readExact(4);
      if (req == null || req[0] != 0x05 || req[1] != 0x01) return;
      late final String host;
      switch (req[3]) {
        case 0x01:
          final addr = await readExact(4);
          if (addr == null) return;
          host = InternetAddress.fromRawAddress(Uint8List.fromList(addr))
              .address;
        case 0x03:
          final len = await readExact(1);
          if (len == null) return;
          final name = await readExact(len[0]);
          if (name == null) return;
          host = utf8.decode(name);
        case 0x04:
          final addr = await readExact(16);
          if (addr == null) return;
          host = InternetAddress.fromRawAddress(Uint8List.fromList(addr))
              .address;
        default:
          return;
      }
      final portBytes = await readExact(2);
      if (portBytes == null) return;
      final targetPort = (portBytes[0] << 8) | portBytes[1];

      requests++;
      target = await Socket.connect(host, targetPort);
      client.add(const [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]);
      if (buf.isNotEmpty) {
        target.add(Uint8List.fromList(buf));
        buf.clear();
      }
      await Future.wait([
        () async {
          while (await iterator.moveNext()) {
            target!.add(iterator.current);
          }
          await target!.close();
        }(),
        target.cast<List<int>>().pipe(client),
      ]);
    } on Object {
      // 测试清理期间忽略连接关闭异常。
    } finally {
      await iterator.cancel();
      client.destroy();
      target?.destroy();
    }
  }
}

void main() {
  test('AppConnect 按代理模式切换：自动、关闭、手动 HTTP（含认证）与 SOCKS5（含认证）', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'path': request.uri.path}));
      await request.response.close();
    });
    addTearDown(() => target.close(force: true));

    final httpProxy = await _TestHttpProxy.start();
    final authedHttpProxy = await _TestHttpProxy.start(
      expectedAuth: 'alice:s3cr3t',
    );
    final socksProxy = await _TestSocks5Proxy.start();
    final authedSocksProxy = await _TestSocks5Proxy.start(
      username: 'bob',
      password: 'pw',
    );
    addTearDown(() async {
      await httpProxy.close();
      await authedHttpProxy.close();
      await socksProxy.close();
      await authedSocksProxy.close();
    });

    final settingsRepo = InMemorySettingsRepository();
    final secretStore = InMemorySecretStore();
    final settings = SettingsController(
      repository: settingsRepo,
      secretStore: secretStore,
    );
    final systemLookup = _FakeSystemLookup(
      AppProxyEndpoint(
        protocol: AppProxyProtocol.http,
        host: '127.0.0.1',
        port: httpProxy.port,
      ),
    );
    final connect = AppConnect(
      timeout: const Duration(seconds: 5),
      proxyResolver: AppProxyResolver(
        settings: settings,
        systemLookup: systemLookup,
      ),
    );
    addTearDown(() {
      connect.dispose();
      settings.onClose();
    });

    final url = 'http://127.0.0.1:${target.port}/ping';

    // 1. 默认自动模式使用系统代理
    final autoRes = await connect.get<Map<String, dynamic>>(url);
    expect(autoRes.isOk, isTrue);
    expect(autoRes.body, {'path': '/ping'});
    expect(httpProxy.requests, 1);

    // 2. 关闭模式不使用系统代理，直接连接目标
    await settings.saveProxySettings(mode: AppProxyMode.off);
    final offRes = await connect.get<Map<String, dynamic>>(url);
    expect(offRes.isOk, isTrue);
    expect(httpProxy.requests, 1);

    // 3. 手动 HTTP 代理（带用户名/密码）
    await settings.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.http,
      address: '127.0.0.1:${authedHttpProxy.port}',
      username: 'alice',
      password: 's3cr3t',
    );
    final authedHttpRes = await connect.get<Map<String, dynamic>>(url);
    expect(authedHttpRes.isOk, isTrue);
    expect(authedHttpProxy.requests, 1);

    // 4. 手动 SOCKS5 代理（无认证）
    await settings.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.socks5,
      address: '127.0.0.1:${socksProxy.port}',
      username: '',
      clearPassword: true,
    );
    final socksRes = await connect.get<Map<String, dynamic>>(url);
    expect(socksRes.isOk, isTrue);
    expect(socksProxy.requests, 1);

    // 5. 手动 SOCKS5 代理（用户名/密码认证）
    await settings.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.socks5,
      address: '127.0.0.1:${authedSocksProxy.port}',
      username: 'bob',
      password: 'pw',
    );
    final authedSocksRes = await connect.get<Map<String, dynamic>>(url);
    expect(authedSocksRes.isOk, isTrue);
    expect(authedSocksProxy.requests, 1);

    // 6. 错误的 SOCKS5 密码导致请求失败
    await settings.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.socks5,
      address: '127.0.0.1:${authedSocksProxy.port}',
      username: 'bob',
      password: 'wrong',
    );
    final failedSocksRes = await connect.get<Map<String, dynamic>>(url);
    expect(failedSocksRes.isOk, isFalse);
  });

  test('系统代理按完整目标合并查询，过期和配置变化后重新解析', () async {
    final settings = SettingsController(
      repository: InMemorySettingsRepository(),
    );
    addTearDown(settings.onClose);
    const first = AppProxyEndpoint(
      protocol: AppProxyProtocol.http,
      host: '127.0.0.1',
      port: 8001,
    );
    const second = AppProxyEndpoint(
      protocol: AppProxyProtocol.http,
      host: '127.0.0.1',
      port: 8002,
    );
    final systemLookup = _FakeSystemLookup(first);
    var elapsed = Duration.zero;
    final resolver = AppProxyResolver(
      settings: settings,
      systemLookup: systemLookup,
      elapsed: () => elapsed,
    );
    final target = Uri.parse('https://example.test/api?route=a');
    expect(
      await Future.wait([resolver.resolve(target), resolver.resolve(target)]),
      [first, first],
    );
    expect(systemLookup.calls, 1);

    systemLookup.endpoint = second;
    expect(await resolver.resolve(target), first);
    expect(await resolver.resolve(target.replace(query: 'route=b')), second);
    expect(systemLookup.calls, 2);

    elapsed = const Duration(seconds: 10);
    expect(await resolver.resolve(target), second);
    expect(systemLookup.calls, 3);

    await settings.saveProxySettings(mode: AppProxyMode.off);
    expect(await resolver.resolve(target), isNull);
    await settings.saveProxySettings(mode: AppProxyMode.auto);
    expect(await resolver.resolve(target), second);
    expect(systemLookup.calls, 4);
  });

  test('HTTPS 代理会发起 TLS 握手并透传到上游代理端口', () async {
    final tcpServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(tcpServer.close);
    final firstBytes = Completer<List<int>>();
    tcpServer.listen((socket) async {
      final data = await socket.first.timeout(const Duration(seconds: 2));
      if (!firstBytes.isCompleted) firstBytes.complete(data);
      socket.destroy();
    });

    final settings = SettingsController(
      repository: InMemorySettingsRepository(),
      secretStore: InMemorySecretStore(),
    );
    await settings.saveProxySettings(
      mode: AppProxyMode.manual,
      protocol: AppProxyProtocol.https,
      address: '127.0.0.1:${tcpServer.port}',
    );
    final connect = AppConnect(
      timeout: const Duration(seconds: 3),
      proxyResolver: AppProxyResolver(
        settings: settings,
        systemLookup: _FakeSystemLookup(null),
      ),
    );
    addTearDown(() {
      connect.dispose();
      settings.onClose();
    });

    final response = await connect.get<Object?>('http://example.invalid/test');
    expect(response.isOk, isFalse);
    final clientHello = await firstBytes.future.timeout(
      const Duration(seconds: 3),
    );
    // TLS record header: ContentType 0x16 (Handshake), LegacyVersion 0x03 0x01
    expect(clientHello.length, greaterThan(3));
    expect(clientHello[0], 0x16);
    expect(clientHello[1], 0x03);
  });
}
