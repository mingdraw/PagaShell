import 'dart:async';

import 'package:get/get.dart';

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
  _ProxiedGetHttpClient? _proxiedClient;

  @override
  GetHttpClient get httpClient {
    if (_proxyResolver == null) return super.httpClient;
    return _proxiedClient ??= _ProxiedGetHttpClient(
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
    _proxiedClient?.close();
    _proxiedClient = null;
    super.dispose();
  }

  @override
  void onClose() {
    // GetConnect 4 的默认 onClose 不释放底层 HTTP 客户端。
    dispose();
    super.onClose();
  }
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

class _ProxiedGetHttpClient extends GetHttpClient {
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
    required String defaultContentType,
    required Decoder<dynamic>? defaultDecoder,
  }) : super(
         allowAutoSignedCert: allowAutoSignedCert,
         trustedCertificates: trustedCertificates,
         withCredentials: withCredentials,
         findProxy: (_) => 'DIRECT',
       ) {
    this.defaultContentType = defaultContentType;
    this.defaultDecoder = defaultDecoder;
  }

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
        GetHttpClient(
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
          )
          ..defaultContentType = defaultContentType
          ..defaultDecoder = defaultDecoder
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
