import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/entities/app_proxy_settings.dart';

/// 进程内仅绑定 127.0.0.1 的临时 HTTP 代理桥，用于为 dart:io HttpClient
/// 补齐 HTTPS 代理、SOCKS5 代理及带用户名/密码的预认证支持。
class ProxyHttpBridge {
  ProxyHttpBridge._(
    this._server,
    this.endpoint, {
    required this.connectTimeout,
  }) {
    _subscription = _server.listen(_handleClient);
  }

  final ServerSocket _server;
  final AppProxyEndpoint endpoint;
  final Duration connectTimeout;
  late final StreamSubscription<Socket> _subscription;
  final _sockets = <Socket>{};
  bool _closed = false;

  int get port => _server.port;

  static Future<ProxyHttpBridge> start(
    AppProxyEndpoint endpoint, {
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return ProxyHttpBridge._(server, endpoint, connectTimeout: connectTimeout);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }

  void _track(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
  }

  void _untrack(Socket socket) {
    _sockets.remove(socket);
  }

  Future<void> _handleClient(Socket client) async {
    if (_closed) {
      client.destroy();
      return;
    }
    _track(client);
    final clientReader = _BufferedSocket(client);
    Socket? upstream;
    try {
      final headerBytes = await clientReader.readUntil(const [
        13,
        10,
        13,
        10,
      ], maxBytes: 64 * 1024);
      if (headerBytes == null) {
        await _closeQuietly(client);
        return;
      }
      final headerText = latin1.decode(headerBytes);
      final lines = headerText.split('\r\n');
      if (lines.isEmpty) {
        await _sendBadGateway(client);
        return;
      }
      final requestLine = lines.first.split(' ');
      if (requestLine.length < 3) {
        await _sendBadGateway(client);
        return;
      }
      final method = requestLine[0].toUpperCase();
      final target = requestLine[1];
      final version = requestLine[2];

      if (method == 'CONNECT') {
        final targetHostPort = _parseConnectAuthority(target);
        if (targetHostPort == null) {
          await _sendBadGateway(client);
          return;
        }
        upstream = await _connectUpstream();
        _track(upstream);
        final upstreamReader = _BufferedSocket(upstream);
        if (endpoint.protocol == AppProxyProtocol.socks5) {
          await _socks5Connect(
            upstreamReader,
            upstream,
            targetHostPort.$1,
            targetHostPort.$2,
          );
        } else {
          await _httpConnectTunnel(
            upstreamReader,
            upstream,
            targetHostPort.$1,
            targetHostPort.$2,
          );
        }
        client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        await client.flush();
        await _pipeBoth(client, clientReader, upstream, upstreamReader);
        return;
      }

      final uri = Uri.tryParse(target);
      if (uri == null || uri.host.isEmpty) {
        await _sendBadGateway(client);
        return;
      }
      upstream = await _connectUpstream();
      _track(upstream);
      final upstreamReader = _BufferedSocket(upstream);
      if (endpoint.protocol == AppProxyProtocol.socks5) {
        final targetPort = uri.hasPort
            ? uri.port
            : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);
        await _socks5Connect(upstreamReader, upstream, uri.host, targetPort);
        final originTarget =
            '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
        final rewritten = _rewriteHttpHeaders(
          '$method $originTarget $version',
          lines.skip(1),
          includeProxyAuth: false,
        );
        upstream.add(latin1.encode(rewritten));
      } else {
        final rewritten = _rewriteHttpHeaders(
          '$method $target $version',
          lines.skip(1),
          includeProxyAuth: endpoint.hasCredentials,
        );
        upstream.add(latin1.encode(rewritten));
      }
      await upstream.flush();
      await _pipeBoth(client, clientReader, upstream, upstreamReader);
    } on Object {
      await _sendBadGateway(client);
    } finally {
      await clientReader.cancel();
      _untrack(client);
      client.destroy();
      if (upstream != null) {
        _untrack(upstream);
        upstream.destroy();
      }
    }
  }

  Future<Socket> _connectUpstream() {
    if (endpoint.protocol == AppProxyProtocol.https) {
      return SecureSocket.connect(
        endpoint.host,
        endpoint.port,
        timeout: connectTimeout,
      );
    }
    return Socket.connect(
      endpoint.host,
      endpoint.port,
      timeout: connectTimeout,
    );
  }

  Future<void> _httpConnectTunnel(
    _BufferedSocket upstreamReader,
    Socket upstream,
    String targetHost,
    int targetPort,
  ) async {
    final formattedHost = targetHost.contains(':')
        ? '[$targetHost]'
        : targetHost;
    final authority = '$formattedHost:$targetPort';
    final buffer = StringBuffer()
      ..write('CONNECT $authority HTTP/1.1\r\n')
      ..write('Host: $authority\r\n');
    if (endpoint.hasCredentials) {
      buffer.write('Proxy-Authorization: ${_basicAuthHeader()}\r\n');
    }
    buffer.write('\r\n');
    upstream.add(latin1.encode(buffer.toString()));
    await upstream.flush();

    final responseHeader = await upstreamReader.readUntil(const [
      13,
      10,
      13,
      10,
    ], maxBytes: 64 * 1024);
    if (responseHeader == null) {
      throw const HttpException('Upstream proxy closed during CONNECT');
    }
    final statusLine = latin1.decode(responseHeader).split('\r\n').first;
    final parts = statusLine.split(' ');
    final code = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    if (code == null || code < 200 || code >= 300) {
      throw HttpException('Upstream proxy rejected CONNECT ($statusLine)');
    }
  }

  Future<void> _socks5Connect(
    _BufferedSocket upstreamReader,
    Socket upstream,
    String targetHost,
    int targetPort,
  ) async {
    final authBytes = endpoint.hasCredentials
        ? const [0x05, 0x02, 0x00, 0x02]
        : const [0x05, 0x01, 0x00];
    upstream.add(authBytes);
    await upstream.flush();

    final greeting = await upstreamReader.readExact(2);
    if (greeting == null || greeting[0] != 0x05) {
      throw const SocketException('Invalid SOCKS5 greeting response');
    }
    final method = greeting[1];
    if (method == 0x02) {
      final userBytes = utf8.encode(endpoint.username);
      final passBytes = utf8.encode(endpoint.password);
      if (userBytes.length > 255 || passBytes.length > 255) {
        throw const SocketException('SOCKS5 credentials exceed 255 bytes');
      }
      final authPacket = BytesBuilder(copy: false)
        ..addByte(0x01)
        ..addByte(userBytes.length)
        ..add(userBytes)
        ..addByte(passBytes.length)
        ..add(passBytes);
      upstream.add(authPacket.takeBytes());
      await upstream.flush();
      final authReply = await upstreamReader.readExact(2);
      if (authReply == null || authReply[1] != 0x00) {
        throw const SocketException('SOCKS5 authentication failed');
      }
    } else if (method != 0x00) {
      throw SocketException('Unsupported SOCKS5 auth method: $method');
    }

    final req = BytesBuilder(copy: false)
      ..addByte(0x05)
      ..addByte(0x01)
      ..addByte(0x00);
    final parsedIp = InternetAddress.tryParse(targetHost);
    if (parsedIp != null && parsedIp.type == InternetAddressType.IPv4) {
      req.addByte(0x01);
      req.add(parsedIp.rawAddress);
    } else if (parsedIp != null && parsedIp.type == InternetAddressType.IPv6) {
      req.addByte(0x04);
      req.add(parsedIp.rawAddress);
    } else {
      final hostBytes = utf8.encode(targetHost);
      if (hostBytes.length > 255) {
        throw const SocketException('Target hostname exceeds 255 bytes');
      }
      req.addByte(0x03);
      req.addByte(hostBytes.length);
      req.add(hostBytes);
    }
    req.addByte((targetPort >> 8) & 0xff);
    req.addByte(targetPort & 0xff);
    upstream.add(req.takeBytes());
    await upstream.flush();

    final head = await upstreamReader.readExact(4);
    if (head == null || head[0] != 0x05 || head[1] != 0x00) {
      throw SocketException(
        'SOCKS5 CONNECT failed (code=${head == null ? 'eof' : head[1]})',
      );
    }
    switch (head[3]) {
      case 0x01:
        if (await upstreamReader.readExact(4) == null) {
          throw const SocketException('Truncated SOCKS5 IPv4 reply');
        }
      case 0x04:
        if (await upstreamReader.readExact(16) == null) {
          throw const SocketException('Truncated SOCKS5 IPv6 reply');
        }
      case 0x03:
        final len = await upstreamReader.readExact(1);
        if (len == null || await upstreamReader.readExact(len[0]) == null) {
          throw const SocketException('Truncated SOCKS5 domain reply');
        }
      default:
        throw SocketException('Unsupported SOCKS5 ATYP: ${head[3]}');
    }
    if (await upstreamReader.readExact(2) == null) {
      throw const SocketException('Truncated SOCKS5 port reply');
    }
  }

  String _rewriteHttpHeaders(
    String requestLine,
    Iterable<String> headerLines, {
    required bool includeProxyAuth,
  }) {
    final out = StringBuffer()..write('$requestLine\r\n');
    for (final line in headerLines) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon > 0) {
        final name = line.substring(0, colon).trim().toLowerCase();
        if (name == 'proxy-connection' ||
            name == 'connection' ||
            name == 'proxy-authorization') {
          continue;
        }
      }
      out.write('$line\r\n');
    }
    out.write('Connection: close\r\n');
    if (includeProxyAuth) {
      out.write('Proxy-Authorization: ${_basicAuthHeader()}\r\n');
    }
    out.write('\r\n');
    return out.toString();
  }

  String _basicAuthHeader() =>
      'Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}';

  static (String, int)? _parseConnectAuthority(String authority) {
    final trimmed = authority.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('[')) {
      final close = trimmed.indexOf(']');
      if (close <= 1 ||
          close + 1 >= trimmed.length ||
          trimmed[close + 1] != ':') {
        return null;
      }
      final port = int.tryParse(trimmed.substring(close + 2));
      if (port == null || port < 1 || port > 65535) return null;
      return (trimmed.substring(1, close), port);
    }
    final colon = trimmed.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(trimmed.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return (trimmed.substring(0, colon), port);
  }

  Future<void> _pipeBoth(
    Socket client,
    _BufferedSocket clientReader,
    Socket upstream,
    _BufferedSocket upstreamReader,
  ) async {
    Future<void> forward(_BufferedSocket from, Socket to) async {
      try {
        await from.pipeTo(to);
      } on Object {
        // 对端关闭或重置连接时安全收尾。
      } finally {
        try {
          await to.close();
        } on Object {
          to.destroy();
        }
      }
    }

    await Future.wait([
      forward(clientReader, upstream),
      forward(upstreamReader, client),
    ]);
  }

  Future<void> _sendBadGateway(Socket client) async {
    try {
      client.add(
        ascii.encode('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n'),
      );
      await client.flush();
      await client.close();
    } on Object {
      // 忽略已关闭的本地连接。
    }
  }

  Future<void> _closeQuietly(Socket socket) async {
    try {
      await socket.close();
    } on Object {
      socket.destroy();
    }
  }
}

class _BufferedSocket {
  _BufferedSocket(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = <int>[];

  Future<List<int>?> readExact(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) return null;
      _buffer.addAll(_iterator.current);
    }
    final result = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return result;
  }

  Future<List<int>?> readUntil(
    List<int> delimiter, {
    required int maxBytes,
  }) async {
    var searchFrom = 0;
    while (true) {
      final index = _indexOfDelimiter(_buffer, delimiter, searchFrom);
      if (index >= 0) {
        final end = index + delimiter.length;
        final result = _buffer.sublist(0, index);
        _buffer.removeRange(0, end);
        return result;
      }
      if (_buffer.length >= maxBytes) return null;
      searchFrom = (_buffer.length - delimiter.length + 1).clamp(
        0,
        _buffer.length,
      );
      if (!await _iterator.moveNext()) return null;
      _buffer.addAll(_iterator.current);
      if (_buffer.length > maxBytes) {
        final overflowIndex = _indexOfDelimiter(_buffer, delimiter, searchFrom);
        if (overflowIndex < 0 || overflowIndex > maxBytes) return null;
      }
    }
  }

  Future<void> pipeTo(Socket sink) async {
    if (_buffer.isNotEmpty) {
      sink.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    while (await _iterator.moveNext()) {
      sink.add(_iterator.current);
    }
    await sink.flush();
  }

  Future<void> cancel() async {
    try {
      await _iterator.cancel();
    } on Object {
      // 忽略取消阶段异常。
    }
  }

  static int _indexOfDelimiter(List<int> data, List<int> delimiter, int start) {
    final limit = data.length - delimiter.length;
    for (var i = start; i <= limit; i++) {
      var matched = true;
      for (var j = 0; j < delimiter.length; j++) {
        if (data[i + j] != delimiter[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }
}
