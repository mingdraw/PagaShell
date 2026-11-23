import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:get/get_connect/http/src/exceptions/exceptions.dart';
import 'package:get/get_connect/http/src/request/request.dart';

import '../../domain/entities/app_proxy_settings.dart';
import 'app_proxy_resolver.dart';
import 'proxy_http_bridge.dart';

/// 全局 HTTP 配置与生命周期；请求和响应直接使用 GetConnect 原生 API。
class AppConnect extends GetConnect {
  AppConnect({
    super.timeout = const Duration(seconds: 15),
    super.followRedirects = false,
    this._proxyResolver,
  });

  final AppProxyResolver? _proxyResolver;
  _FastBodyGetHttpClient? _client;

  @override
  GetHttpClient get httpClient {
    final existing = _client;
    if (existing != null) return existing;
    if (_proxyResolver == null) {
      return _client = _FastBodyGetHttpClient(
        userAgent: userAgent,
        sendUserAgent: sendUserAgent,
        timeout: timeout,
        followRedirects: followRedirects,
        maxRedirects: maxRedirects,
        maxAuthRetries: maxAuthRetries,
        allowAutoSignedCert: allowAutoSignedCert,
        baseUrl: baseUrl,
        trustedCertificates: trustedCertificates,
        withCredentials: withCredentials,
        findProxy: findProxy,
        defaultContentType: defaultContentType,
        defaultDecoder: defaultDecoder,
      );
    }
    return _client = _ProxiedGetHttpClient(
      proxyResolver: _proxyResolver,
      userAgent: userAgent,
      sendUserAgent: sendUserAgent,
      timeout: timeout,
      followRedirects: followRedirects,
      maxRedirects: maxRedirects,
      maxAuthRetries: maxAuthRetries,
      allowAutoSignedCert: allowAutoSignedCert,
      baseUrl: baseUrl,
      trustedCertificates: trustedCertificates,
      withCredentials: withCredentials,
      defaultContentType: defaultContentType,
      defaultDecoder: defaultDecoder,
    );
  }

  @override
  void dispose() {
    _client?.close();
    _client = null;
    super.dispose();
  }

  @override
  void onClose() {
    // GetConnect 4 的默认 onClose 不释放底层 HTTP 客户端。
    dispose();
    super.onClose();
  }
}

/// 绕过 get 4.7.3 `GetHttpClient._trackProgress` 逐字节 `bodyBytes.map((i) => [i])`
/// 流式发包：整块（或带进度时按 32 KiB 分块）构建 `Request` 并经由 `send` 发出。
class _FastBodyGetHttpClient extends GetHttpClient {
  _FastBodyGetHttpClient({
    required super.userAgent,
    required super.sendUserAgent,
    required super.timeout,
    required super.followRedirects,
    required super.maxRedirects,
    required super.maxAuthRetries,
    required super.allowAutoSignedCert,
    required super.baseUrl,
    required super.trustedCertificates,
    required super.withCredentials,
    super.findProxy,
    required String defaultContentType,
    required Decoder<dynamic>? defaultDecoder,
  }) {
    this.defaultContentType = defaultContentType;
    this.defaultDecoder = defaultDecoder;
  }

  static const _progressChunkSize = 32 * 1024;

  Future<Response<T>> _sendWithBody<T>(
    String? url,
    String method, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) async {
    try {
      final request = await _buildBodyRequest<T>(
        url,
        method,
        body: body,
        contentType: contentType,
        headers: headers,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
        uploadProgress: uploadProgress,
      );
      return await send<T>(request);
    } on Exception catch (e) {
      if (!errorSafety) {
        throw GetHttpException(e.toString());
      }
      return Response<T>(statusText: 'Can not connect to server. Reason: $e');
    }
  }

  Future<Request<T>> _buildBodyRequest<T>(
    String? url,
    String method, {
    required dynamic body,
    required String? contentType,
    required Map<String, String>? headers,
    required Map<String, dynamic>? query,
    required Decoder<T>? decoder,
    required ResponseInterceptor<T>? responseInterceptor,
    required Progress? uploadProgress,
  }) async {
    final requestHeaders = <String, String>{};
    if (sendUserAgent) {
      requestHeaders['user-agent'] = userAgent;
    }

    List<int>? bodyBytes;
    if (body is FormData) {
      bodyBytes = await body.toBytes();
      requestHeaders['content-length'] = bodyBytes.length.toString();
      requestHeaders['content-type'] =
          'multipart/form-data; boundary=${body.boundary}';
    } else if (contentType != null &&
        contentType.toLowerCase() == 'application/x-www-form-urlencoded' &&
        body is Map) {
      final parts = <String>[];
      body.forEach((Object? key, Object? value) {
        parts.add(
          '${Uri.encodeQueryComponent('$key')}='
          '${Uri.encodeQueryComponent('$value')}',
        );
      });
      bodyBytes = utf8.encode(parts.join('&'));
      if (sendContentLength) {
        requestHeaders['content-length'] = bodyBytes.length.toString();
      }
      requestHeaders['content-type'] = contentType;
    } else if (body is Map || body is List) {
      bodyBytes = utf8.encode(jsonEncode(body));
      if (sendContentLength) {
        requestHeaders['content-length'] = bodyBytes.length.toString();
      }
      requestHeaders['content-type'] = contentType ?? defaultContentType;
    } else if (body is String) {
      bodyBytes = utf8.encode(body);
      if (sendContentLength) {
        requestHeaders['content-length'] = bodyBytes.length.toString();
      }
      requestHeaders['content-type'] = contentType ?? defaultContentType;
    } else if (body == null) {
      if (sendContentLength) {
        requestHeaders['content-length'] = '0';
      }
      requestHeaders['content-type'] = contentType ?? defaultContentType;
    } else if (!errorSafety) {
      throw UnexpectedFormat('body cannot be ${body.runtimeType}');
    }

    if (headers != null) {
      requestHeaders.addAll(headers);
    }

    final Stream<List<int>>? bodyStream;
    if (bodyBytes == null) {
      bodyStream = null;
    } else if (uploadProgress == null || bodyBytes.isEmpty) {
      bodyStream = Stream<List<int>>.value(bodyBytes);
    } else {
      bodyStream = _chunkedProgressStream(bodyBytes, uploadProgress);
    }

    final defaultInterceptor = defaultResponseInterceptor;
    final effectiveInterceptor =
        responseInterceptor ??
        (defaultInterceptor == null
            ? null
            : (request, targetType, response) async =>
                  await defaultInterceptor(request, targetType, response)
                      as Response<T>?);

    return Request<T>(
      method: method,
      url: createUri(url, query),
      headers: requestHeaders,
      bodyBytes: bodyStream,
      contentLength: bodyBytes?.length ?? 0,
      followRedirects: followRedirects,
      maxRedirects: maxRedirects,
      decoder: decoder ?? (defaultDecoder as Decoder<T>?),
      responseInterceptor: effectiveInterceptor,
    );
  }

  static Stream<List<int>> _chunkedProgressStream(
    List<int> bodyBytes,
    Progress uploadProgress,
  ) async* {
    final bytes = bodyBytes is Uint8List
        ? bodyBytes
        : Uint8List.fromList(bodyBytes);
    final length = bytes.length;
    var sent = 0;
    while (sent < length) {
      final end = sent + _progressChunkSize < length
          ? sent + _progressChunkSize
          : length;
      final chunk = Uint8List.sublistView(bytes, sent, end);
      sent = end;
      uploadProgress(sent / length * 100);
      yield chunk;
    }
  }

  @override
  Future<Response<T>> post<T>(
    String? url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) => _sendWithBody<T>(
    url,
    'post',
    body: body,
    contentType: contentType,
    headers: headers,
    query: query,
    decoder: decoder,
    responseInterceptor: responseInterceptor,
    uploadProgress: uploadProgress,
  );

  @override
  Future<Response<T>> put<T>(
    String url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) => _sendWithBody<T>(
    url,
    'put',
    body: body,
    contentType: contentType,
    headers: headers,
    query: query,
    decoder: decoder,
    responseInterceptor: responseInterceptor,
    uploadProgress: uploadProgress,
  );

  @override
  Future<Response<T>> patch<T>(
    String url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) => _sendWithBody<T>(
    url,
    'patch',
    body: body,
    contentType: contentType,
    headers: headers,
    query: query,
    decoder: decoder,
    responseInterceptor: responseInterceptor,
    uploadProgress: uploadProgress,
  );

  @override
  Future<Response<T>> request<T>(
    String url,
    String method, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) => _sendWithBody<T>(
    url,
    method,
    body: body,
    contentType: contentType,
    headers: headers,
    query: query,
    decoder: decoder,
    responseInterceptor: responseInterceptor,
    uploadProgress: uploadProgress,
  );
}

class _ProxySlot {
  _ProxySlot(this.client, this.bridge);

  final GetHttpClient client;
  final ProxyHttpBridge? bridge;

  void close() {
    client.close();
    if (bridge != null) {
      unawaited(bridge!.close());
    }
  }
}

class _SlotRecord {
  _SlotRecord(this.future);
  final Future<_ProxySlot> future;
}

class _ProxiedGetHttpClient extends _FastBodyGetHttpClient {
  _ProxiedGetHttpClient({
    required this.proxyResolver,
    required super.userAgent,
    required super.sendUserAgent,
    required super.timeout,
    required super.followRedirects,
    required super.maxRedirects,
    required super.maxAuthRetries,
    required this.allowAutoSignedCert,
    required super.baseUrl,
    required this.trustedCertificates,
    required this.withCredentials,
    required super.defaultContentType,
    required super.defaultDecoder,
  }) : super(
         allowAutoSignedCert: allowAutoSignedCert,
         trustedCertificates: trustedCertificates,
         withCredentials: withCredentials,
         findProxy: (_) => 'DIRECT',
       );

  final AppProxyResolver proxyResolver;
  final bool allowAutoSignedCert;
  final List<TrustedCertificate>? trustedCertificates;
  final bool withCredentials;
  final _slots = <String, _SlotRecord>{};
  bool _closed = false;

  Future<GetHttpClient> _delegateFor(
    String? url,
    Map<String, dynamic>? query,
  ) async {
    final target = createUri(url, query);
    final endpoint = await proxyResolver.resolve(target);
    if (_closed) return this;
    if (endpoint == null) return this;

    final key = endpoint.cacheKey;
    final existing = _slots[key];
    if (existing != null) {
      return (await existing.future).client;
    }

    final future = _createSlot(endpoint);
    _slots[key] = _SlotRecord(future);
    try {
      final slot = await future;
      if (_closed) {
        slot.close();
        _slots.remove(key);
        return this;
      }
      return slot.client;
    } on Object {
      _slots.remove(key);
      rethrow;
    }
  }

  Future<_ProxySlot> _createSlot(AppProxyEndpoint endpoint) async {
    ProxyHttpBridge? bridge;
    final String proxyDirective;
    if (endpoint.protocol == AppProxyProtocol.http &&
        !endpoint.hasCredentials) {
      proxyDirective = 'PROXY ${endpoint.address}';
    } else {
      bridge = await ProxyHttpBridge.start(endpoint, connectTimeout: timeout);
      proxyDirective = 'PROXY 127.0.0.1:${bridge.port}';
    }
    final client =
        _FastBodyGetHttpClient(
            userAgent: userAgent,
            sendUserAgent: sendUserAgent,
            timeout: timeout,
            followRedirects: followRedirects,
            maxRedirects: maxRedirects,
            maxAuthRetries: maxAuthRetries,
            allowAutoSignedCert: allowAutoSignedCert,
            baseUrl: baseUrl,
            trustedCertificates: trustedCertificates,
            withCredentials: withCredentials,
            findProxy: (_) => proxyDirective,
            defaultContentType: defaultContentType,
            defaultDecoder: defaultDecoder,
          )
          ..defaultResponseInterceptor = defaultResponseInterceptor
          ..errorSafety = errorSafety;
    return _ProxySlot(client, bridge);
  }

  @override
  Future<Response<T>> get<T>(
    String url, {
    Map<String, String>? headers,
    String? contentType,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.get<T>(
        url,
        headers: headers,
        contentType: contentType,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
      );
    }
    return client.get<T>(
      url,
      headers: headers,
      contentType: contentType,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
    );
  }

  @override
  Future<Response<T>> post<T>(
    String? url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.post<T>(
        url,
        body: body,
        contentType: contentType,
        headers: headers,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
        uploadProgress: uploadProgress,
      );
    }
    return client.post<T>(
      url,
      body: body,
      contentType: contentType,
      headers: headers,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
      uploadProgress: uploadProgress,
    );
  }

  @override
  Future<Response<T>> put<T>(
    String url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.put<T>(
        url,
        body: body,
        contentType: contentType,
        headers: headers,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
        uploadProgress: uploadProgress,
      );
    }
    return client.put<T>(
      url,
      body: body,
      contentType: contentType,
      headers: headers,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
      uploadProgress: uploadProgress,
    );
  }

  @override
  Future<Response<T>> patch<T>(
    String url, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.patch<T>(
        url,
        body: body,
        contentType: contentType,
        headers: headers,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
        uploadProgress: uploadProgress,
      );
    }
    return client.patch<T>(
      url,
      body: body,
      contentType: contentType,
      headers: headers,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
      uploadProgress: uploadProgress,
    );
  }

  @override
  Future<Response<T>> delete<T>(
    String url, {
    Map<String, String>? headers,
    String? contentType,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.delete<T>(
        url,
        headers: headers,
        contentType: contentType,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
      );
    }
    return client.delete<T>(
      url,
      headers: headers,
      contentType: contentType,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
    );
  }

  @override
  Future<Response<T>> request<T>(
    String url,
    String method, {
    dynamic body,
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    ResponseInterceptor<T>? responseInterceptor,
    Progress? uploadProgress,
  }) async {
    final client = await _delegateFor(url, query);
    if (identical(client, this)) {
      return super.request<T>(
        url,
        method,
        body: body,
        contentType: contentType,
        headers: headers,
        query: query,
        decoder: decoder,
        responseInterceptor: responseInterceptor,
        uploadProgress: uploadProgress,
      );
    }
    return client.request<T>(
      url,
      method,
      body: body,
      contentType: contentType,
      headers: headers,
      query: query,
      decoder: decoder,
      responseInterceptor: responseInterceptor,
      uploadProgress: uploadProgress,
    );
  }

  @override
  void close() {
    _closed = true;
    for (final record in _slots.values.toList()) {
      unawaited(
        record.future.then((slot) => slot.close(), onError: (Object _) {}),
      );
    }
    _slots.clear();
    super.close();
  }
}
