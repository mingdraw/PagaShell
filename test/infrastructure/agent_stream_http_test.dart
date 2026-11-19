import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/in_memory_agent_conversation_repository.dart';
import '../support/in_memory_ai_settings_repository.dart';

class _Engine extends Fake implements SshEngine {}

const _toolId = 'stream-tool';
const _summary = '先查阅说明';
const _opening = '正在查阅';
const _answer = 'SFTP uses its own tab.';

Map<String, Object> _chat(Map<String, Object> delta, [String? finish]) => {
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': finish},
  ],
};

Map<String, Object> _block(String type, int index, Map<String, Object> data) =>
    {
      'type': 'content_block_$type',
      'index': index,
      if (type == 'start') 'content_block': data,
      if (type == 'delta') 'delta': data,
    };

Map<String, Object> _response(String text, {bool withTool = false}) => {
  'type': 'response.completed',
  'response': {
    'status': 'completed',
    'output': [
      if (withTool)
        {
          'type': 'reasoning',
          'id': 'rs-stream',
          'summary': [
            {'type': 'summary_text', 'text': _summary},
          ],
          'encrypted_content': 'fixture-encrypted',
        },
      {
        'type': 'message',
        'role': 'assistant',
        'id': withTool ? 'msg-opening' : 'msg-answer',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
      if (withTool)
        {
          'type': 'function_call',
          'id': 'fc-stream',
          'call_id': _toolId,
          'name': 'read_skill',
          'arguments': '{"id":"pagashell"}',
        },
    ],
  },
};

Iterable<Map<String, Object>> _openingEvents(AiApiFormat format) =>
    switch (format) {
      AiApiFormat.openai => [
        _chat({'reasoning_content': _summary}),
        _chat({'content': _opening}),
        _chat({
          'tool_calls': [
            {
              'index': 0,
              'id': _toolId,
              'function': {'name': 'read_skill', 'arguments': '{"id":'},
            },
          ],
        }),
      ],
      AiApiFormat.openaiResponses => [
        {'type': 'response.reasoning_summary_text.delta', 'delta': _summary},
        {'type': 'response.output_text.delta', 'delta': _opening},
      ],
      AiApiFormat.anthropic => [
        _block('start', 0, {'type': 'thinking', 'thinking': ''}),
        _block('delta', 0, {'type': 'thinking_delta', 'thinking': _summary}),
        _block('delta', 0, {
          'type': 'signature_delta',
          'signature': 'fixture-signature',
        }),
        _block('stop', 0, {}),
        _block('start', 1, {'type': 'text', 'text': ''}),
        _block('delta', 1, {'type': 'text_delta', 'text': _opening}),
        _block('stop', 1, {}),
        _block('start', 2, {
          'type': 'tool_use',
          'id': _toolId,
          'name': 'read_skill',
          'input': <String, Object>{},
        }),
        _block('delta', 2, {
          'type': 'input_json_delta',
          'partial_json': '{"id":',
        }),
      ],
    };

Iterable<Map<String, Object>> _finishToolTurn(AiApiFormat format) =>
    switch (format) {
      AiApiFormat.openai => [
        _chat({
          'tool_calls': [
            {
              'index': 0,
              'function': {'arguments': '"pagashell"}'},
            },
          ],
        }),
        _chat({}, 'tool_calls'),
      ],
      AiApiFormat.openaiResponses => [_response(_opening, withTool: true)],
      AiApiFormat.anthropic => [
        _block('delta', 2, {
          'type': 'input_json_delta',
          'partial_json': '"pagashell"}',
        }),
        _block('stop', 2, {}),
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
        },
        {'type': 'message_stop'},
      ],
    };

Iterable<Map<String, Object>> _answerEvents(AiApiFormat format) =>
    switch (format) {
      AiApiFormat.openai => [
        _chat({'content': _answer}),
        _chat({}, 'stop'),
      ],
      AiApiFormat.openaiResponses => [_response(_answer)],
      AiApiFormat.anthropic => [
        _block('start', 0, {'type': 'text', 'text': ''}),
        _block('delta', 0, {'type': 'text_delta', 'text': _answer}),
        _block('stop', 0, {}),
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
        },
        {'type': 'message_stop'},
      ],
    };

void _write(HttpResponse response, Iterable<Map<String, Object>> events) {
  for (final event in events) {
    response.write('data: ${jsonEncode(event)}\r\n\r\n');
  }
}

Future<(AgentController, HttpServer)> _fixture(AiApiFormat format) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final connect = AppConnect(timeout: const Duration(seconds: 5));
  final store = InMemorySecretStore();
  final settings = AiSettingsController(
    repository: InMemoryAiSettingsRepository(),
    secretStore: store,
  );
  final sessions = SessionController(engine: _Engine());
  final agent = AgentController(
    connect: connect,
    settings: settings,
    secretStore: store,
    sessions: sessions,
    conversations: InMemoryAgentConversationRepository(),
  );
  addTearDown(() async {
    agent.onClose();
    settings.onClose();
    sessions.onClose();
    connect.dispose();
    await server.close(force: true);
  });
  await settings.saveModel(
    name: 'Stream fixture',
    format: format,
    baseUrl: 'http://127.0.0.1:${server.port}',
    model: 'fixture-model',
    apiKey: 'fixture-key',
  );
  return (agent, server);
}

Future<void> _waitForPreview(AgentController agent) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 3) && agent.busy.value) {
    if (agent.entries.any((entry) => entry.text == _opening)) return;
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  fail('响应保持打开时没有看到流式文字：${agent.error.value}');
}

void main() {
  for (final format in AiApiFormat.values) {
    test('$format 通过真实 HTTP 逐步显示文字，完成后使用工具并继续回复', () async {
      final (agent, server) = await _fixture(format);
      final finish = Completer<void>();
      final bodies = <Map<String, dynamic>>[];
      server.listen((request) async {
        final response = request.response;
        if (request.method == 'GET') {
          response.headers.contentType = ContentType.json;
          response.write('{"id":"fixture-model","max_tokens":256}');
        } else {
          bodies.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          response.bufferOutput = false;
          response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (bodies.length == 1) {
            _write(response, _openingEvents(format));
            await response.flush();
            await finish.future;
            _write(response, _finishToolTurn(format));
          } else {
            _write(response, _answerEvents(format));
          }
        }
        await response.close();
      });

      final sending = agent.send('Explain file transfer');
      try {
        await _waitForPreview(agent);
        expect(agent.entries.any((entry) => entry.text == _summary), isTrue);
        expect(
          agent.entries.where((e) => e.kind == AgentEntryKind.tool),
          isEmpty,
        );
        expect(bodies, hasLength(1));
      } finally {
        finish.complete();
        await sending.timeout(const Duration(seconds: 5));
      }
      expect(agent.error.value, isNull);
      expect(bodies.map((body) => body['stream']), [true, true]);
      expect(
        agent.entries.where((e) => e.kind == AgentEntryKind.tool),
        hasLength(1),
      );
      expect(agent.entries.last.text, _answer);
      final continuation = jsonEncode(bodies.last);
      expect(continuation, contains(_toolId));
      expect(continuation, contains('PagaShell'));
      if (format == AiApiFormat.anthropic) {
        expect(continuation, contains('fixture-signature'));
      } else if (format == AiApiFormat.openaiResponses) {
        expect(continuation, contains('fixture-encrypted'));
      }
    });
  }

  test('关闭未完成的 SSE 后保留已显示文字，不触发工具调用', () async {
    const format = AiApiFormat.openai;
    final (agent, server) = await _fixture(format);
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      _write(request.response, _openingEvents(format));
      await request.response.close();
    });

    await agent
        .send('Explain file transfer')
        .timeout(const Duration(seconds: 5));
    expect(agent.error.value, 'AI 回复流意外中断，请重试');
    expect(agent.entries.any((entry) => entry.text == _opening), isTrue);
    expect(agent.entries.where((e) => e.kind == AgentEntryKind.tool), isEmpty);
  });

  test('停止回复后，迟到的流不会使用工具或影响下一次请求', () async {
    const format = AiApiFormat.openai;
    final (agent, server) = await _fixture(format);
    final finish = Completer<void>();
    final oldResponseDone = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      await request.drain<void>();
      final response = request.response
        ..bufferOutput = false
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
      if (++requests == 1) {
        _write(response, _openingEvents(format));
        await response.flush();
        await finish.future;
        try {
          _write(response, _finishToolTurn(format));
          await response.close();
        } on IOException {
          // The cancelled request may have closed its connection already.
        } finally {
          oldResponseDone.complete();
        }
      } else {
        _write(response, _answerEvents(format));
        await response.close();
      }
    });

    final sending = agent.send('Explain file transfer');
    try {
      await _waitForPreview(agent);
      agent.stop();
      await sending.timeout(const Duration(seconds: 5));
      expect(
        agent.entries.first.requestState.value,
        AgentRequestState.cancelled,
      );
      await agent.send('Try again').timeout(const Duration(seconds: 5));
    } finally {
      finish.complete();
      await oldResponseDone.future.timeout(const Duration(seconds: 5));
    }
    expect(requests, 2);
    expect(agent.error.value, isNull);
    expect(agent.entries.where((e) => e.kind == AgentEntryKind.tool), isEmpty);
    expect(agent.entries.last.text, _answer);
  });

  test('兼容端点明确拒绝流式请求时退回普通 JSON', () async {
    final (agent, server) = await _fixture(AiApiFormat.openai);
    final modes = <Object?>[];
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final response = request.response;
      modes.add(body['stream']);
      response.headers.contentType = ContentType.json;
      if (body['stream'] == true) {
        response.statusCode = 400;
        response.write('{"error":{"message":"stream is unsupported"}}');
      } else {
        response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': _answer},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
      }
      await response.close();
    });

    await agent
        .send('Explain file transfer')
        .timeout(const Duration(seconds: 5));
    expect(agent.error.value, isNull);
    expect(modes, [true, false]);
    expect(agent.entries.last.text, _answer);
  });
}
