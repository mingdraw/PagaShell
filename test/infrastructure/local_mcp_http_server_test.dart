import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/mcp/mcp_server_transport.dart';
import 'package:pagashell/infrastructure/mcp/local_mcp_http_server.dart';

Map<String, dynamic> _asMap(Object? value) => value! as Map<String, dynamic>;

List<dynamic> _asList(Object? value) => value! as List<dynamic>;

class _FakeDelegate implements McpServerDelegate {
  @override
  String get serverName => 'pagashell';

  @override
  String get serverVersion => '1.2.3';

  @override
  String get instructions => 'Test MCP server instructions';

  final calls = <(String, Map<String, dynamic>)>[];

  @override
  List<McpToolDefinition> listTools() => const [
    McpToolDefinition(
      name: 'echo',
      description: 'Echo message',
      inputSchema: {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
        'required': ['message'],
      },
      annotations: McpToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      ),
    ),
  ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    calls.add((name, arguments));
    if (name == 'fail') {
      return const McpToolResult(text: 'boom', isError: true);
    }
    return McpToolResult(text: 'echo:${arguments['message'] ?? ''}');
  }

  @override
  List<McpResourceDefinition> listResources() => const [
    McpResourceDefinition(
      uri: 'pagashell://test',
      name: 'Test Resource',
      description: 'Sample resource',
      mimeType: 'application/json',
    ),
  ];

  @override
  Future<McpResourceContent?> readResource(String uri) async {
    if (uri != 'pagashell://test') return null;
    return const McpResourceContent(
      uri: 'pagashell://test',
      mimeType: 'application/json',
      text: '{"ok":true}',
    );
  }

  @override
  List<McpPromptDefinition> listPrompts() => const [
    McpPromptDefinition(
      name: 'ops_check',
      description: 'Run check',
      arguments: [
        McpPromptArgument(name: 'target', description: 'Target host'),
      ],
    ),
  ];

  @override
  Future<McpPromptResult?> getPrompt(
    String name,
    Map<String, String> arguments,
  ) async {
    if (name != 'ops_check') return null;
    return McpPromptResult(
      description: 'Run check',
      messages: [
        McpPromptMessage(
          role: 'user',
          text: 'Inspect ${arguments['target'] ?? 'all'}',
        ),
      ],
    );
  }
}

Future<({int statusCode, HttpHeaders headers, String body})> _sendRequest(
  HttpClient client, {
  required String method,
  required int port,
  String path = '/mcp',
  Map<String, String> headers = const {},
  Object? body,
}) async {
  final req = await client.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  headers.forEach(req.headers.set);
  if (body is String) {
    req.add(utf8.encode(body));
  } else if (body is List<int>) {
    req.add(body);
  } else if (body != null) {
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
  }
  final res = await req.close();
  final text = await utf8.decoder.bind(res).join();
  return (statusCode: res.statusCode, headers: res.headers, body: text);
}

void main() {
  late HttpClient client;
  late _FakeDelegate delegate;
  late McpServerHandle handle;
  const initialToken = 'secret-test-token-123';

  setUp(() async {
    client = HttpClient();
    delegate = _FakeDelegate();
    handle = await const LocalMcpServerFactory().start(
      port: 0,
      token: initialToken,
      delegate: delegate,
    );
  });

  tearDown(() async {
    client.close(force: true);
    await handle.close();
  });

  test('鉴权、Host/Origin 防 DNS Rebinding、路径与请求体上限防护', () async {
    final noAuth = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(noAuth.statusCode, HttpStatus.unauthorized);
    expect(
      noAuth.headers.value(HttpHeaders.wwwAuthenticateHeader),
      contains('Bearer'),
    );

    final wrongAuth = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {HttpHeaders.authorizationHeader: 'Bearer wrong-token'},
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(wrongAuth.statusCode, HttpStatus.unauthorized);

    final badOrigin = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $initialToken',
        'Origin': 'https://evil.example.com',
      },
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(badOrigin.statusCode, HttpStatus.forbidden);

    final badHost = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $initialToken',
        HttpHeaders.hostHeader: 'evil.example.com:${handle.port}',
      },
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(badHost.statusCode, HttpStatus.forbidden);

    final okOrigin = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $initialToken',
        'Origin': 'http://localhost:3000',
      },
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
    );
    expect(okOrigin.statusCode, HttpStatus.ok);

    final notFound = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      path: '/other',
      headers: {HttpHeaders.authorizationHeader: 'Bearer $initialToken'},
    );
    expect(notFound.statusCode, HttpStatus.notFound);

    final badMethod = await _sendRequest(
      client,
      method: 'PUT',
      port: handle.port,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $initialToken'},
    );
    expect(badMethod.statusCode, HttpStatus.methodNotAllowed);

    final huge = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $initialToken'},
      body: List<int>.filled(4 * 1024 * 1024 + 16, 0x20),
    );
    expect(huge.statusCode, HttpStatus.requestEntityTooLarge);

    final badJson = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $initialToken'},
      body: '{invalid-json',
    );
    expect(badJson.statusCode, HttpStatus.badRequest);
    final badJsonBody = _asMap(jsonDecode(badJson.body));
    expect(_asMap(badJsonBody['error'])['code'], -32700);
  });

  test('完整 MCP Streamable HTTP 握手、工具/资源/提示词、批处理、SSE 通知、令牌热更新与会话销毁', () async {
    final auth = {HttpHeaders.authorizationHeader: 'Bearer $initialToken'};

    // 1. initialize
    final init = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: auth,
      body: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object>{},
          'clientInfo': {'name': 'codex', 'version': '0.1.0'},
        },
      },
    );
    expect(init.statusCode, HttpStatus.ok);
    final sessionId = init.headers.value('mcp-session-id');
    expect(sessionId, isNotNull);
    expect(handle.activeSessionCount, 1);

    final initResult = _asMap(_asMap(jsonDecode(init.body))['result']);
    expect(initResult['protocolVersion'], '2025-06-18');
    expect(_asMap(initResult['serverInfo'])['name'], 'pagashell');
    final caps = _asMap(initResult['capabilities']);
    expect(_asMap(caps['tools'])['listChanged'], isTrue);

    final sessionHeaders = {...auth, 'MCP-Session-Id': sessionId!};

    // 2. notifications/initialized -> 202 Accepted
    final initialized = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    );
    expect(initialized.statusCode, HttpStatus.accepted);
    expect(initialized.body, isEmpty);

    // 3. tools/list + tools/call
    final list = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    );
    expect(list.statusCode, HttpStatus.ok);
    final tools = _asList(
      _asMap(_asMap(jsonDecode(list.body))['result'])['tools'],
    );
    expect(tools, hasLength(1));
    expect(_asMap(tools.single)['name'], 'echo');

    final call = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'echo',
          'arguments': {'message': 'hello'},
        },
      },
    );
    expect(call.statusCode, HttpStatus.ok);
    final callResult = _asMap(_asMap(jsonDecode(call.body))['result']);
    expect(_asMap(_asList(callResult['content']).first)['text'], 'echo:hello');
    expect(callResult['isError'], isNull);

    final failCall = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {'name': 'fail', 'arguments': <String, Object>{}},
      },
    );
    final failResult = _asMap(_asMap(jsonDecode(failCall.body))['result']);
    expect(failResult['isError'], isTrue);

    // 4. resources/list & resources/read & prompts/list & prompts/get
    final resList = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {'jsonrpc': '2.0', 'id': 5, 'method': 'resources/list'},
    );
    final resources = _asList(
      _asMap(_asMap(jsonDecode(resList.body))['result'])['resources'],
    );
    expect(resources, hasLength(1));

    final resRead = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'resources/read',
        'params': {'uri': 'pagashell://test'},
      },
    );
    final resContents = _asList(
      _asMap(_asMap(jsonDecode(resRead.body))['result'])['contents'],
    );
    expect(_asMap(resContents.first)['text'], '{"ok":true}');

    final missingRes = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'resources/read',
        'params': {'uri': 'pagashell://missing'},
      },
    );
    expect(
      _asMap(_asMap(jsonDecode(missingRes.body))['error'])['code'],
      -32002,
    );

    final promptGet = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'prompts/get',
        'params': {
          'name': 'ops_check',
          'arguments': {'target': 'prod-db'},
        },
      },
    );
    final promptMessages = _asList(
      _asMap(_asMap(jsonDecode(promptGet.body))['result'])['messages'],
    );
    expect(
      _asMap(_asMap(promptMessages.first)['content'])['text'],
      'Inspect prod-db',
    );

    // 5. 批处理 JSON-RPC
    final batch = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: [
        {'jsonrpc': '2.0', 'id': 9, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': 10, 'method': 'prompts/list'},
      ],
    );
    expect(batch.statusCode, HttpStatus.ok);
    expect(_asList(jsonDecode(batch.body)), hasLength(2));

    // 6. GET /mcp SSE 订阅并接收 tools/list_changed 通知
    final sseClient = HttpClient();
    addTearDown(() => sseClient.close(force: true));
    final sseReq = await sseClient.getUrl(
      Uri.parse('http://127.0.0.1:${handle.port}/mcp'),
    );
    sseReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $initialToken');
    sseReq.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    sseReq.headers.set('MCP-Session-Id', sessionId);
    final sseRes = await sseReq.close();
    expect(sseRes.statusCode, HttpStatus.ok);

    final received = StringBuffer();
    final notified = Completer<void>();
    final sseSub = utf8.decoder.bind(sseRes).listen((chunk) {
      received.write(chunk);
      if (received.toString().contains('notifications/tools/list_changed') &&
          !notified.isCompleted) {
        notified.complete();
      }
    });
    addTearDown(() => sseSub.cancel());

    await Future<void>.delayed(const Duration(milliseconds: 50));
    handle.notifyToolsListChanged();
    await notified.future.timeout(const Duration(seconds: 3));
    expect(received.toString(), contains('notifications/tools/list_changed'));

    // 7. 令牌热更新：旧令牌立即失效，新令牌生效
    const rotated = 'rotated-token-456';
    handle.updateToken(rotated);
    final oldTokenRes = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: sessionHeaders,
      body: {'jsonrpc': '2.0', 'id': 11, 'method': 'ping'},
    );
    expect(oldTokenRes.statusCode, HttpStatus.unauthorized);

    final newHeaders = {
      HttpHeaders.authorizationHeader: 'Bearer $rotated',
      'MCP-Session-Id': sessionId,
    };
    final newTokenRes = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: newHeaders,
      body: {'jsonrpc': '2.0', 'id': 12, 'method': 'ping'},
    );
    expect(newTokenRes.statusCode, HttpStatus.ok);

    // 8. DELETE /mcp 注销会话
    final deleted = await _sendRequest(
      client,
      method: 'DELETE',
      port: handle.port,
      headers: newHeaders,
    );
    expect(deleted.statusCode, HttpStatus.noContent);
    expect(handle.activeSessionCount, 0);

    final afterDelete = await _sendRequest(
      client,
      method: 'POST',
      port: handle.port,
      headers: newHeaders,
      body: {'jsonrpc': '2.0', 'id': 13, 'method': 'ping'},
    );
    expect(afterDelete.statusCode, HttpStatus.notFound);
  });
}
