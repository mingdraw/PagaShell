import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../domain/mcp/mcp_models.dart';
import '../../domain/mcp/mcp_server_transport.dart';

/// 基于 `dart:io` 的纯本地 MCP Streamable HTTP 服务端实现。
///
/// 仅绑定 `127.0.0.1` 回环地址，强制校验 `Host`/`Origin` 防 DNS Rebinding，
/// 并使用常量时间比较校验 `Authorization: Bearer <token>`。
class LocalMcpServerFactory implements McpServerFactory {
  const LocalMcpServerFactory();

  @override
  Future<McpServerHandle> start({
    required int port,
    required String token,
    required McpServerDelegate delegate,
  }) =>
      _LocalMcpServerHandle.bind(port: port, token: token, delegate: delegate);
}

class _McpSession {
  _McpSession({required this.id, required this.protocolVersion})
    : lastActiveAt = DateTime.now();

  final String id;
  final String protocolVersion;
  DateTime lastActiveAt;
  final Set<_SseListener> sseListeners = {};
}

class _SseListener {
  _SseListener(this.response, this.keepalive);

  final HttpResponse response;
  final Timer keepalive;
  bool closed = false;

  Future<void> close() async {
    if (closed) return;
    closed = true;
    keepalive.cancel();
    try {
      await response.close();
    } on Object {
      // 忽略已断开的连接关闭错误。
    }
  }
}

class _LocalMcpServerHandle implements McpServerHandle {
  _LocalMcpServerHandle._({
    required this._server,
    required this._token,
    required this._delegate,
  }) {
    _server.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (Object _, StackTrace _) {},
    );
  }

  static const supportedProtocolVersions = [
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];
  static const _maxBodyBytes = 4 * 1024 * 1024;
  static const _maxOverflowDrainBytes = 256 * 1024;
  static const _maxSessions = 32;
  static const _maxConcurrentCalls = 8;
  static const _sessionIdleTtl = Duration(hours: 24);
  static const _sseKeepaliveInterval = Duration(seconds: 25);

  final HttpServer _server;
  final McpServerDelegate _delegate;
  String _token;
  bool _closed = false;
  int _inFlightCalls = 0;
  final Map<String, _McpSession> _sessions = {};
  final _sessionCountController = StreamController<int>.broadcast();

  static Future<_LocalMcpServerHandle> bind({
    required int port,
    required String token,
    required McpServerDelegate delegate,
  }) async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      return _LocalMcpServerHandle._(
        server: server,
        token: token,
        delegate: delegate,
      );
    } on SocketException {
      throw const McpServerException('MCP 服务端口已被占用或无权监听，请更换端口后重试');
    } on Object {
      throw const McpServerException('无法启动本地 MCP 服务，请检查端口设置后重试');
    }
  }

  @override
  int get port => _server.port;

  @override
  int get activeSessionCount => _sessions.length;

  @override
  Stream<int> get activeSessionCountStream => _sessionCountController.stream;

  @override
  void updateToken(String token) {
    _token = token;
  }

  @override
  void notifyToolsListChanged() {
    if (_closed) return;
    final payload =
        'event: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'})}\n\n';
    final bytes = utf8.encode(payload);
    for (final session in _sessions.values.toList()) {
      for (final listener in session.sseListeners.toList()) {
        if (listener.closed) continue;
        try {
          listener.response.add(bytes);
          unawaited(listener.response.flush().catchError((Object _) {}));
        } on Object {
          session.sseListeners.remove(listener);
          unawaited(listener.close());
        }
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final listeners = <_SseListener>[
      for (final session in _sessions.values) ...session.sseListeners,
    ];
    _sessions.clear();
    _emitSessionCount();
    for (final listener in listeners) {
      await listener.close();
    }
    try {
      await _server.close(force: true);
    } on Object {
      // 退出期间忽略关闭异常。
    }
    await _sessionCountController.close();
  }

  void _emitSessionCount() {
    if (!_sessionCountController.isClosed) {
      _sessionCountController.add(_sessions.length);
    }
  }

  void _evictExpiredSessions() {
    final now = DateTime.now();
    final expired = _sessions.values
        .where(
          (session) =>
              session.sseListeners.isEmpty &&
              now.difference(session.lastActiveAt) > _sessionIdleTtl,
        )
        .map((session) => session.id)
        .toList();
    if (expired.isEmpty) return;
    for (final id in expired) {
      _sessions.remove(id);
    }
    _emitSessionCount();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');

    try {
      final path = request.uri.path;
      if (path != McpServerConfig.mcpPath &&
          path != '${McpServerConfig.mcpPath}/') {
        await _sendJson(response, HttpStatus.notFound, {
          'error': 'Not Found',
        }, closeConnection: true);
        return;
      }

      if (!_isAllowedHost(request.headers.value(HttpHeaders.hostHeader)) ||
          !_isAllowedOrigin(request.headers.value('origin'))) {
        await _sendJson(response, HttpStatus.forbidden, {
          'jsonrpc': '2.0',
          'error': {
            'code': -32003,
            'message': 'Forbidden: non-loopback Host or Origin header.',
          },
          'id': null,
        }, closeConnection: true);
        return;
      }

      if (!_isAuthorized(
        request.headers.value(HttpHeaders.authorizationHeader),
      )) {
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="PagaShell MCP"',
        );
        await _sendJson(response, HttpStatus.unauthorized, {
          'jsonrpc': '2.0',
          'error': {
            'code': -32001,
            'message': 'Unauthorized: valid Bearer token required.',
          },
          'id': null,
        }, closeConnection: true);
        return;
      }

      _evictExpiredSessions();

      switch (request.method.toUpperCase()) {
        case 'POST':
          await _handlePost(request);
        case 'GET':
          await _handleGetSse(request);
        case 'DELETE':
          await _handleDelete(request);
        default:
          response.headers.set(HttpHeaders.allowHeader, 'POST, GET, DELETE');
          await _sendJson(response, HttpStatus.methodNotAllowed, {
            'error': 'Method Not Allowed',
          }, closeConnection: true);
      }
    } on Object {
      try {
        await _sendJson(response, HttpStatus.internalServerError, {
          'jsonrpc': '2.0',
          'error': {'code': -32603, 'message': 'Internal server error.'},
          'id': null,
        }, closeConnection: true);
      } on Object {
        // 响应头已发送或客户端已断开。
      }
    }
  }

  bool _isAllowedHost(String? hostHeader) {
    if (hostHeader == null || hostHeader.trim().isEmpty) return true;
    final normalized = hostHeader.trim().toLowerCase();
    return normalized == '127.0.0.1' ||
        normalized == 'localhost' ||
        normalized == '127.0.0.1:$port' ||
        normalized == 'localhost:$port';
  }

  bool _isAllowedOrigin(String? originHeader) {
    if (originHeader == null || originHeader.trim().isEmpty) return true;
    final uri = Uri.tryParse(originHeader.trim());
    if (uri == null || !uri.hasAuthority) return false;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    return (scheme == 'http' || scheme == 'https') &&
        (host == '127.0.0.1' || host == 'localhost');
  }

  bool _isAuthorized(String? authHeader) {
    if (authHeader == null) return false;
    final parts = authHeader.trim().split(RegExp(r'\s+'));
    if (parts.length != 2 || parts[0].toLowerCase() != 'bearer') return false;
    return _constantTimeEquals(parts[1], _token);
  }

  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    final maxLen = aBytes.length > bBytes.length
        ? aBytes.length
        : bBytes.length;
    var diff = aBytes.length ^ bBytes.length;
    for (var i = 0; i < maxLen; i++) {
      final left = i < aBytes.length ? aBytes[i] : 0;
      final right = i < bBytes.length ? bBytes[i] : 0;
      diff |= left ^ right;
    }
    return diff == 0 && bBytes.isNotEmpty;
  }

  Future<void> _handlePost(HttpRequest request) async {
    final response = request.response;
    final bytes = await _readBodyBounded(request);
    if (bytes == null) {
      await _sendJson(response, HttpStatus.requestEntityTooLarge, {
        'jsonrpc': '2.0',
        'error': {'code': -32600, 'message': 'Request body exceeds 4 MiB.'},
        'id': null,
      }, closeConnection: true);
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      await _sendJson(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'error': {'code': -32700, 'message': 'Parse error: invalid JSON.'},
        'id': null,
      });
      return;
    }

    final sessionIdHeader = request.headers.value('mcp-session-id')?.trim();
    final isBatch = decoded is List<dynamic>;
    final messages = isBatch
        ? decoded
        : decoded is Map<String, dynamic>
        ? <dynamic>[decoded]
        : null;
    if (messages == null || messages.isEmpty) {
      await _sendJson(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'error': {'code': -32600, 'message': 'Invalid Request.'},
        'id': null,
      });
      return;
    }

    final containsInitialize = messages.any(
      (item) => item is Map<String, dynamic> && item['method'] == 'initialize',
    );
    _McpSession? activeSession;
    if (!containsInitialize &&
        sessionIdHeader != null &&
        sessionIdHeader.isNotEmpty) {
      activeSession = _sessions[sessionIdHeader];
      if (activeSession == null) {
        await _sendJson(response, HttpStatus.notFound, {
          'jsonrpc': '2.0',
          'error': {
            'code': -32000,
            'message': 'Unknown or expired MCP session. Re-initialize.',
          },
          'id': null,
        });
        return;
      }
      activeSession.lastActiveAt = DateTime.now();
    }

    String? createdSessionId;
    final responses = <Map<String, Object?>>[];
    for (final raw in messages) {
      if (raw is! Map<String, dynamic>) {
        responses.add(_rpcError(null, -32600, 'Invalid Request.'));
        continue;
      }
      final outcome = await _dispatchJsonRpc(raw);
      if (outcome.createdSessionId != null) {
        createdSessionId = outcome.createdSessionId;
      }
      if (outcome.payload != null) {
        responses.add(outcome.payload!);
      }
    }

    final effectiveSessionId = createdSessionId ?? activeSession?.id;
    if (effectiveSessionId != null) {
      response.headers.set('MCP-Session-Id', effectiveSessionId);
    }

    if (responses.isEmpty) {
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }

    await _sendJson(
      response,
      HttpStatus.ok,
      isBatch ? responses : responses.single,
    );
  }

  Future<void> _handleGetSse(HttpRequest request) async {
    final response = request.response;
    final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '';
    if (!accept.toLowerCase().contains('text/event-stream')) {
      response.headers.set(HttpHeaders.allowHeader, 'POST, GET, DELETE');
      await _sendJson(response, HttpStatus.methodNotAllowed, {
        'error': 'Accept: text/event-stream required for GET /mcp.',
      });
      return;
    }
    final sessionId = request.headers.value('mcp-session-id')?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      await _sendJson(response, HttpStatus.badRequest, {
        'error': 'Missing MCP-Session-Id header.',
      });
      return;
    }
    final session = _sessions[sessionId];
    if (session == null) {
      await _sendJson(response, HttpStatus.notFound, {
        'error': 'Unknown or expired MCP session.',
      });
      return;
    }
    session.lastActiveAt = DateTime.now();
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/event-stream; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.headers.set('MCP-Session-Id', session.id);

    late final _SseListener listener;
    final keepalive = Timer.periodic(_sseKeepaliveInterval, (_) {
      if (listener.closed || _closed) return;
      try {
        response.add(utf8.encode(': keepalive\n\n'));
        unawaited(response.flush().catchError((Object _) {}));
      } on Object {
        session.sseListeners.remove(listener);
        unawaited(listener.close());
      }
    });
    listener = _SseListener(response, keepalive);
    session.sseListeners.add(listener);

    try {
      response.add(utf8.encode(': connected\n\n'));
      await response.flush();
      await response.done;
    } on Object {
      // 客户端断开 SSE 流。
    } finally {
      session.sseListeners.remove(listener);
      await listener.close();
    }
  }

  Future<void> _handleDelete(HttpRequest request) async {
    final response = request.response;
    final sessionId = request.headers.value('mcp-session-id')?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      await _sendJson(response, HttpStatus.badRequest, {
        'error': 'Missing MCP-Session-Id header.',
      });
      return;
    }
    final removed = _sessions.remove(sessionId);
    if (removed == null) {
      await _sendJson(response, HttpStatus.notFound, {
        'error': 'Unknown or expired MCP session.',
      });
      return;
    }
    for (final listener in removed.sseListeners.toList()) {
      await listener.close();
    }
    removed.sseListeners.clear();
    _emitSessionCount();
    response.statusCode = HttpStatus.noContent;
    await response.close();
  }

  Future<({Map<String, Object?>? payload, String? createdSessionId})>
  _dispatchJsonRpc(Map<String, dynamic> message) async {
    final hasId = message.containsKey('id');
    final id = message['id'];
    final method = message['method'];
    final jsonrpc = message['jsonrpc'];
    if (jsonrpc != '2.0' || method is! String || method.isEmpty) {
      return (
        payload: hasId
            ? _rpcError(id, -32600, 'Invalid JSON-RPC request.')
            : null,
        createdSessionId: null,
      );
    }

    final rawParams = message['params'];
    if (rawParams != null && rawParams is! Map<String, dynamic>) {
      return (
        payload: hasId
            ? _rpcError(id, -32602, 'Invalid params: expected object.')
            : null,
        createdSessionId: null,
      );
    }
    final params = (rawParams as Map<String, dynamic>?) ?? const {};

    // Notifications（无 id）不返回 JSON-RPC 响应体。
    if (!hasId) {
      return (payload: null, createdSessionId: null);
    }

    switch (method) {
      case 'initialize':
        final requested = params['protocolVersion'];
        final negotiated =
            requested is String && supportedProtocolVersions.contains(requested)
            ? requested
            : supportedProtocolVersions.first;
        final session = _createSession(negotiated);
        return (
          createdSessionId: session.id,
          payload: _rpcResult(id, {
            'protocolVersion': negotiated,
            'capabilities': {
              'tools': {'listChanged': true},
              'resources': <String, Object>{},
              'prompts': <String, Object>{},
            },
            'serverInfo': {
              'name': _delegate.serverName,
              'version': _delegate.serverVersion,
            },
            'instructions': _delegate.instructions,
          }),
        );

      case 'ping':
        return (
          payload: _rpcResult(id, <String, Object>{}),
          createdSessionId: null,
        );

      case 'tools/list':
        return (
          payload: _rpcResult(id, {
            'tools': _delegate
                .listTools()
                .map((tool) => tool.toJson())
                .toList(),
          }),
          createdSessionId: null,
        );

      case 'tools/call':
        final name = params['name'];
        final rawArgs = params['arguments'];
        if (name is! String ||
            name.trim().isEmpty ||
            (rawArgs != null && rawArgs is! Map<String, dynamic>)) {
          return (
            payload: _rpcError(
              id,
              -32602,
              'Invalid params: tool name and object arguments required.',
            ),
            createdSessionId: null,
          );
        }
        if (_inFlightCalls >= _maxConcurrentCalls) {
          return (
            payload: _rpcError(
              id,
              -32000,
              'Server busy: too many concurrent MCP tool calls.',
            ),
            createdSessionId: null,
          );
        }
        _inFlightCalls++;
        try {
          final result = await _delegate.callTool(
            name.trim(),
            (rawArgs as Map<String, dynamic>?) ?? const {},
          );
          return (
            payload: _rpcResult(id, {
              'content': [
                {'type': 'text', 'text': result.text},
              ],
              if (result.isError) 'isError': true,
            }),
            createdSessionId: null,
          );
        } finally {
          _inFlightCalls--;
        }

      case 'resources/list':
        return (
          payload: _rpcResult(id, {
            'resources': _delegate
                .listResources()
                .map((resource) => resource.toJson())
                .toList(),
          }),
          createdSessionId: null,
        );

      case 'resources/read':
        final uri = params['uri'];
        if (uri is! String || uri.trim().isEmpty) {
          return (
            payload: _rpcError(id, -32602, 'Invalid params: uri is required.'),
            createdSessionId: null,
          );
        }
        final content = await _delegate.readResource(uri.trim());
        if (content == null) {
          return (
            payload: _rpcError(id, -32002, 'Resource not found: $uri'),
            createdSessionId: null,
          );
        }
        return (
          payload: _rpcResult(id, {
            'contents': [content.toJson()],
          }),
          createdSessionId: null,
        );

      case 'prompts/list':
        return (
          payload: _rpcResult(id, {
            'prompts': _delegate
                .listPrompts()
                .map((prompt) => prompt.toJson())
                .toList(),
          }),
          createdSessionId: null,
        );

      case 'prompts/get':
        final name = params['name'];
        final rawArgs = params['arguments'];
        if (name is! String ||
            name.trim().isEmpty ||
            (rawArgs != null && rawArgs is! Map<String, dynamic>)) {
          return (
            payload: _rpcError(
              id,
              -32602,
              'Invalid params: prompt name required.',
            ),
            createdSessionId: null,
          );
        }
        final stringArgs = <String, String>{};
        if (rawArgs is Map<String, dynamic>) {
          for (final entry in rawArgs.entries) {
            if (entry.value != null) {
              stringArgs[entry.key] = '${entry.value}';
            }
          }
        }
        final prompt = await _delegate.getPrompt(name.trim(), stringArgs);
        if (prompt == null) {
          return (
            payload: _rpcError(id, -32602, 'Unknown prompt: $name'),
            createdSessionId: null,
          );
        }
        return (
          payload: _rpcResult(id, prompt.toJson()),
          createdSessionId: null,
        );

      default:
        return (
          payload: _rpcError(id, -32601, 'Method not found: $method'),
          createdSessionId: null,
        );
    }
  }

  _McpSession _createSession(String protocolVersion) {
    if (_sessions.length >= _maxSessions) {
      final oldest = _sessions.values.reduce(
        (a, b) => a.lastActiveAt.isBefore(b.lastActiveAt) ? a : b,
      );
      _sessions.remove(oldest.id);
      for (final listener in oldest.sseListeners.toList()) {
        unawaited(listener.close());
      }
    }
    final id = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final session = _McpSession(id: id, protocolVersion: protocolVersion);
    _sessions[id] = session;
    _emitSessionCount();
    return session;
  }

  Future<List<int>?> _readBodyBounded(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    var overflowed = false;
    var drainedAfterOverflow = 0;
    await for (final chunk in request) {
      if (overflowed) {
        drainedAfterOverflow += chunk.length;
        if (drainedAfterOverflow > _maxOverflowDrainBytes) {
          return null;
        }
        continue;
      }
      if (builder.length + chunk.length > _maxBodyBytes) {
        overflowed = true;
        drainedAfterOverflow = (builder.length + chunk.length) - _maxBodyBytes;
        builder.clear();
        if (drainedAfterOverflow > _maxOverflowDrainBytes) {
          return null;
        }
        continue;
      }
      builder.add(chunk);
    }
    return overflowed ? null : builder.takeBytes();
  }

  Map<String, Object?> _rpcResult(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, Object?> _rpcError(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Object body, {
    bool closeConnection = false,
  }) async {
    if (closeConnection) {
      response.persistentConnection = false;
    }
    response.statusCode = statusCode;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    response.add(utf8.encode(jsonEncode(body)));
    await response.close();
  }
}
