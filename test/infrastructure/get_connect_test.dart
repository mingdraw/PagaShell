import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/network/app_connect.dart';

void main() {
  late HttpServer server;
  late GetConnect client;
  late Uri origin;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    Get.lazyPut<GetConnect>(
      () => AppConnect(timeout: const Duration(milliseconds: 150)),
      fenix: true,
    );
    client = Get.find<GetConnect>();
  });

  tearDown(() async {
    Get.reset();
    await server.close(force: true);
  });

  test('GetConnect 直接管理 JSON、查询参数、请求头与响应状态', () async {
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.queryParameters['q'], '中文');
      expect(request.headers.value('x-test'), 'value');
      expect(request.headers.contentType?.mimeType, 'application/json');
      final Object? body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body, {'name': 'test'});
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true,"items":[1,2]}');
      await request.response.close();
    });
    final response = await client.post<Map<String, dynamic>>(
      origin.replace(path: '/echo').toString(),
      {'name': 'test'},
      query: {'q': '中文'},
      headers: {'x-test': 'value'},
    );
    expect(response.isOk, isTrue);
    expect(response.body, {
      'ok': true,
      'items': [1, 2],
    });
  });

  test('HTTP 失败由 GetX Response 状态管理', () async {
    server.listen((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });
    final response = await client.get<Object?>(origin.toString());
    expect(response.statusCode, 403);
    expect(response.hasError, isTrue);
    expect(response.isOk, isFalse);
  });

  test('无正文响应保留 204 状态', () async {
    server.listen((request) async {
      request.response.statusCode = 204;
      await request.response.close();
    });
    final response = await client.get<Object?>(origin.toString());
    expect(response.statusCode, 204);
    expect(response.isOk, isTrue);
    expect(response.body, isNull);
  });

  test('不会自动跟随重定向', () async {
    var calls = 0;
    server.listen((request) async {
      calls++;
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/other');
      await request.response.close();
    });
    final response = await client.get<Object?>(origin.toString());
    expect(response.statusCode, 302);
    expect(response.isOk, isFalse);
    expect(calls, 1);
  });

  test('超时由 GetX 返回失败响应，容器删除时释放客户端', () async {
    server.listen((_) {});
    final response = await client.get<Object?>(origin.toString());
    expect(response.statusCode, isNull);
    expect(response.hasError, isTrue);
    expect(await Get.delete<GetConnect>(force: true), isTrue);
    expect(client.isClosed, isTrue);
    expect(client.isDisposed, isTrue);
    expect(Get.isPrepared<GetConnect>(), isTrue);
    final replacement = Get.find<GetConnect>();
    expect(replacement, isNot(same(client)));
    expect(replacement.isDisposed, isFalse);
  });
}
