import 'dart:async';

import 'package:get/get.dart';

class AiRequest {
  AiRequest(this.url, this.body, this.headers, {this.method = 'POST'});
  final String? url;
  final Map<String, dynamic> body;
  final Map<String, String>? headers;
  final String method;
}

class FakeAiConnect extends GetConnect {
  FakeAiConnect(this.handler, {this.getHandler});
  final FutureOr<Response<dynamic>> Function(AiRequest) handler;
  final FutureOr<Response<dynamic>> Function(AiRequest)? getHandler;
  final requests = <AiRequest>[];

  @override
  Future<Response<T>> get<T>(
    String url, {
    Map<String, String>? headers,
    String? contentType,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
  }) async {
    final request = AiRequest(url, const {}, headers, method: 'GET');
    requests.add(request);
    final response =
        await getHandler?.call(request) ??
        const Response<dynamic>(statusCode: 404);
    return Response<T>(
      statusCode: response.statusCode,
      body: response.body as T?,
    );
  }

  @override
  Future<Response<T>> post<T>(
    String? url,
    dynamic body, {
    String? contentType,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
    Progress? uploadProgress,
  }) async {
    final request = AiRequest(url, body as Map<String, dynamic>, headers);
    requests.add(request);
    final response = await handler(request);
    return Response<T>(
      statusCode: response.statusCode,
      body: response.body as T?,
    );
  }
}

Response<dynamic> openAiReply(
  String text, {
  List<Map<String, Object>> calls = const [],
}) => Response<dynamic>(
  statusCode: 200,
  body: {
    'choices': [
      {
        'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
        'message': {
          'role': 'assistant',
          'content': text,
          if (calls.isNotEmpty) 'tool_calls': calls,
        },
      },
    ],
  },
);

Response<dynamic> anthropicReply(List<Map<String, Object>> content) =>
    Response<dynamic>(
      statusCode: 200,
      body: {
        'content': content,
        'stop_reason': content.any((b) => b['type'] == 'tool_use')
            ? 'tool_use'
            : 'end_turn',
      },
    );

Response<dynamic> responsesReply(List<Map<String, Object>> output) =>
    Response<dynamic>(
      statusCode: 200,
      body: {'status': 'completed', 'output': output},
    );

Map<String, Object> responsesText(String text) => {
  'type': 'message',
  'id': 'msg-fixture',
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': <Object>[]},
  ],
};
