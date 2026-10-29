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

void main() {
  for (final format in AiApiFormat.values) {
    test('$format 通过真实 GetConnect HTTP 完成技能调用与后续聊天', () async {
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
        name: 'Local contract',
        format: format,
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'contract-model',
        apiKey: 'fixture-key',
      );
      final bodies = <Map<String, dynamic>>[];
      final headers = <HttpHeaders>[];
      final paths = <String>[];
      final modelPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'GET') {
          modelPaths.add(request.uri.path);
          expect(request.uri.path, '/v1/models');
          expect(
            request.headers.value(
              format == AiApiFormat.anthropic ? 'x-api-key' : 'authorization',
            ),
            format == AiApiFormat.anthropic
                ? 'fixture-key'
                : 'Bearer fixture-key',
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                for (final id in ['contract-model', 'alternate-model'])
                  {
                    'id': id,
                    'max_tokens': 131072,
                    'capabilities': {
                      'effort': {
                        'supported': true,
                        'high': {'supported': true},
                      },
                      'thinking': {
                        'supported': true,
                        'types': {
                          'adaptive': {'supported': true},
                        },
                      },
                    },
                  },
              ],
              'has_more': false,
            }),
          );
          await request.response.close();
          return;
        }
        headers.add(request.headers);
        paths.add(request.uri.path);
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        bodies.add(body);
        final first = bodies.length == 1;
        final Object reply = switch (format) {
          AiApiFormat.openai => {
            'choices': [
              {
                'finish_reason': first ? 'tool_calls' : 'stop',
                'message': {
                  'role': 'assistant',
                  'content': first ? '' : 'SFTP uses its own tab.',
                  if (first)
                    'tool_calls': [
                      {
                        'id': 'http-tool',
                        'type': 'function',
                        'function': {
                          'name': 'read_skill',
                          'arguments': '{"id":"pagashell"}',
                        },
                      },
                    ],
                },
              },
            ],
          },
          AiApiFormat.openaiResponses => {
            'status': 'completed',
            'output': [
              if (first) ...[
                {
                  'type': 'reasoning',
                  'id': 'rs-http',
                  'summary': <Object>[],
                  'encrypted_content': 'encrypted-http',
                },
                {
                  'type': 'function_call',
                  'id': 'fc-http',
                  'call_id': 'http-tool',
                  'name': 'read_skill',
                  'arguments': '{"id":"pagashell"}',
                },
              ] else
                {
                  'type': 'message',
                  'id': 'msg-http',
                  'role': 'assistant',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'SFTP uses its own tab.',
                      'annotations': <Object>[],
                    },
                  ],
                },
            ],
          },
          AiApiFormat.anthropic => {
            'stop_reason': first ? 'tool_use' : 'end_turn',
            'content': [
              if (first) ...[
                {
                  'type': 'thinking',
                  'thinking': '',
                  'signature': 'http-thinking-signature',
                },
                {
                  'type': 'tool_use',
                  'id': 'http-tool',
                  'name': 'read_skill',
                  'input': {'id': 'pagashell'},
                },
              ] else
                {'type': 'text', 'text': 'SFTP uses its own tab.'},
            ],
          },
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
        await request.response.close();
      });
      await agent.fetchModels(
        format: format,
        baseUrl: settings.state.value.apiConfig!.baseUrl,
        modelConfigId: settings.state.value.apiConfig!.id,
      );
      expect(agent.currentModel!.model, 'contract-model');
      expect(modelPaths, ['/v1/models']);
      agent.selectReasoningEffort(AiReasoningEffort.high);
      await agent.send('Explain file transfer');
      await agent.send('Can I open two tabs?');
      expect(agent.error.value, isNull);
      expect(bodies, hasLength(3));
      final path = switch (format) {
        AiApiFormat.openai => '/v1/chat/completions',
        AiApiFormat.openaiResponses => '/v1/responses',
        AiApiFormat.anthropic => '/v1/messages',
      };
      expect(paths, everyElement(path));
      expect(headers.first.contentType!.mimeType, 'application/json');
      expect(bodies.first['model'], 'contract-model');
      expect(settings.state.value.apiConfig!.model, 'contract-model');
      expect(bodies.first['stream'], isFalse);
      final tools = (bodies.first['tools'] as List<dynamic>)
          .map(
            (dynamic value) =>
                (format == AiApiFormat.openai
                        ? (value as Map)['function']
                        : value)
                    as Map,
          )
          .toList();
      expect(
        tools.map((tool) => tool['name']),
        unorderedEquals([
          'read_skill',
          'get_workspace_context',
          'get_server_status',
          'read_terminal_output',
          'propose_ssh_command',
        ]),
      );
      final outputTool = tools.firstWhere(
        (tool) => tool['name'] == 'read_terminal_output',
      );
      final schema =
          outputTool[format == AiApiFormat.anthropic
                  ? 'input_schema'
                  : 'parameters']
              as Map;
      expect(((schema['properties'] as Map)['lines'] as Map)['maximum'], 200);
      expect(
        ((schema['properties'] as Map)['wait_ms'] as Map)['maximum'],
        5000,
      );
      if (format == AiApiFormat.openai) {
        expect(headers.first.value('authorization'), 'Bearer fixture-key');
        expect(
          bodies.every((body) => body['reasoning_effort'] == 'high'),
          isTrue,
        );
        final second = bodies[1]['messages'] as List<dynamic>;
        expect((second.last as Map)['tool_call_id'], 'http-tool');
        expect((second.last as Map)['content'], contains('PagaShell'));
      } else if (format == AiApiFormat.openaiResponses) {
        expect(headers.first.value('authorization'), 'Bearer fixture-key');
        expect(bodies.first['reasoning'], {'effort': 'high'});
        expect(bodies.first['store'], isFalse);
        expect(bodies.first['instructions'], isA<String>());
        final input = bodies[1]['input'] as List<dynamic>;
        expect((input.last as Map)['type'], 'function_call_output');
        expect((input.last as Map)['call_id'], 'http-tool');
        expect((input.last as Map)['output'], contains('PagaShell'));
        expect(jsonEncode(bodies[2]['input']), contains('encrypted-http'));
      } else {
        expect(headers.first.value('x-api-key'), 'fixture-key');
        expect(headers.first.value('anthropic-version'), '2023-06-01');
        expect(bodies.first['system'], isA<String>());
        expect(bodies.first['max_tokens'], 131072);
        expect(bodies.first['thinking'], {'type': 'adaptive'});
        expect(bodies.first['output_config'], {'effort': 'high'});
        final second = bodies[1]['messages'] as List<dynamic>;
        expect(jsonEncode(second[1]), contains('http-thinking-signature'));
        expect((second.last as Map)['role'], 'user');
        final blocks = (second.last as Map)['content'] as List<dynamic>;
        expect((blocks.first as Map)['tool_use_id'], 'http-tool');
      }
      if (format != AiApiFormat.anthropic) {
        expect(bodies.first, isNot(contains('max_tokens')));
        expect(bodies.first, isNot(contains('max_output_tokens')));
      }
    });
  }
}
