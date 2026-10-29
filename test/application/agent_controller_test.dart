import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/ai/agent_api_codec.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_ai_connect.dart';
import '../support/in_memory_agent_conversation_repository.dart';
import '../support/in_memory_ai_settings_repository.dart';

class _Engine extends Fake implements SshEngine {}

class _ControlledHistory extends InMemoryAgentConversationRepository {
  Future<List<AgentConversation>>? pendingRead;
  Future<void>? pendingSave;
  Future<void>? pendingDelete;

  @override
  Future<List<AgentConversation>> readAll() => pendingRead ?? super.readAll();

  @override
  Future<void> save(AgentConversation conversation) async {
    await pendingSave;
    await super.save(conversation);
  }

  @override
  Future<void> remove(String id) async {
    await pendingDelete;
    await super.remove(id);
  }
}

class _SshSession extends Fake implements SshEngineSession, ServerStatusSource {
  int reads = 0;
  @override
  Future<ServerStatusSample> readServerStatus() async {
    reads++;
    return const ServerStatusSample(
      uptimeSeconds: 100,
      cpuTotal: 1000,
      cpuIdle: 900,
      memoryTotal: 8000,
      memoryAvailable: 4000,
      filesystems: [],
      network: {},
      disks: {},
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  Future<
    ({
      AgentController agent,
      SessionController sessions,
      AiSettingsController settings,
      InMemoryAgentConversationRepository history,
    })
  >
  setup(
    FakeAiConnect connect, {
    AiApiFormat format = AiApiFormat.openai,
    InMemoryAgentConversationRepository? history,
    InMemoryAiSettingsRepository? preferences,
  }) async {
    final store = InMemorySecretStore();
    final settings = AiSettingsController(
      repository: preferences ?? InMemoryAiSettingsRepository(),
      secretStore: store,
    );
    await settings.saveModel(
      name: 'test',
      format: format,
      baseUrl: 'https://api.test/v1',
      model: 'custom-model',
      apiKey: 'private-test-key',
    );
    final sessions = SessionController(engine: _Engine());
    final conversations = history ?? InMemoryAgentConversationRepository();
    final agent = AgentController(
      connect: connect,
      settings: settings,
      secretStore: store,
      sessions: sessions,
      conversations: conversations,
    );
    addTearDown(() {
      agent.onClose();
      sessions.onClose();
      connect.dispose();
      settings.onClose();
    });
    return (
      agent: agent,
      sessions: sessions,
      settings: settings,
      history: conversations,
    );
  }

  Future<List<AiAvailableModel>> loadModels(AgentController agent) {
    final model = agent.currentModel!;
    return agent.fetchModels(
      format: model.format,
      baseUrl: model.baseUrl,
      modelConfigId: model.id,
    );
  }

  Session terminal(String id, List<String> written, {_SshSession? engine}) =>
      Session(
        id: id,
        host: Host(
          id: id,
          name: 'Host $id',
          hostname: '$id.internal',
          username: 'sensitive-user',
          note: 'secret-note',
        ),
        phase: SessionPhase.ready,
        engineSession: engine ?? _SshSession(),
        terminal: Terminal(onOutput: written.add),
      );

  Map<String, Object> tool(
    String name,
    Map<String, Object> args, {
    String id = 'call-1',
  }) => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': jsonEncode(args)},
  };

  Future<AgentCommandProposal> pendingCommand(AgentController agent) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final proposal = agent.entries
          .where(
            (entry) => entry.command?.state.value == AgentCommandState.pending,
          )
          .firstOrNull
          ?.command;
      if (proposal != null) return proposal;
      await Future<void>.delayed(Duration.zero);
    }
    throw StateError('No pending command');
  }

  test('OpenAI 多轮聊天、正确鉴权且默认不发送会话地址和备注', () async {
    final connect = FakeAiConnect((_) => openAiReply('Hello'));
    final app = await setup(connect);
    app.sessions.sessions.add(terminal('private-host', []));
    app.sessions.activeSessionId.value = 'private-host';
    await app.agent.send('How can I use PagaShell?');
    await app.agent.send('And SFTP?');
    expect(connect.requests.last.url, 'https://api.test/v1/chat/completions');
    expect(
      connect.requests.last.headers!['Authorization'],
      'Bearer private-test-key',
    );
    final serialized = jsonEncode(connect.requests.last.body);
    for (final secret in [
      'private-host.internal',
      'sensitive-user',
      'secret-note',
      'private-test-key',
    ]) {
      expect(serialized, isNot(contains(secret)));
    }
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    expect(messages.map((dynamic m) => (m as Map)['role']), [
      'system',
      'user',
      'assistant',
      'user',
    ]);
    expect(app.agent.error.value, isNull);
    expect(connect.requests.last.body, isNot(contains('max_tokens')));
  });

  test('Agent 始终使用设置的默认模型，修改设置后生效', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (_) => const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {'id': 'beta'},
            {'id': 'alpha'},
          ],
        },
      ),
    );
    final app = await setup(connect);
    await loadModels(app.agent);
    expect(app.agent.currentModel!.model, 'custom-model');
    await app.agent.send('Hello');
    expect(connect.requests.last.body['model'], 'custom-model');
    expect(app.settings.state.value.apiConfig!.model, 'custom-model');
    await app.settings.saveApi(
      format: AiApiFormat.openai,
      baseUrl: 'https://new.test/v1',
      defaultModel: 'new-default',
    );
    await app.agent.send('New default');
    expect(app.agent.currentModel!.model, 'new-default');
    expect(connect.requests.last.body['model'], 'new-default');
    expect(app.agent.error.value, isNull);
  });

  test('目录失败仍能使用默认模型，重试后加载 API 模型', () async {
    var fail = true;
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (_) => fail
          ? const Response<dynamic>(statusCode: 503, body: 'private-test-key')
          : const Response<dynamic>(
              statusCode: 200,
              body: {
                'data': [
                  {'id': 'ready-model'},
                ],
              },
            ),
    );
    final app = await setup(connect);
    await expectLater(loadModels(app.agent), throwsA(isA<AgentApiException>()));
    await app.agent.send('Default still works');
    expect(app.agent.error.value, isNull);
    fail = false;
    expect((await loadModels(app.agent)).map((m) => m.id), ['ready-model']);
  });

  test('保存新 API 后忽略旧目录的迟到结果，沿用思考模式', () async {
    final old = Completer<Response<dynamic>>();
    final started = Completer<void>();
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (request) {
        if (Uri.parse(request.url!).host == 'api.test') {
          if (!started.isCompleted) started.complete();
          return old.future;
        }
        return const Response<dynamic>(
          statusCode: 200,
          body: {
            'data': [
              {'id': 'new-model'},
            ],
          },
        );
      },
    );
    final app = await setup(connect);
    app.agent.onInit();
    await app.settings.setPanel(visible: true);
    expect(connect.requests, isEmpty);
    final oldFetch = loadModels(app.agent);
    await started.future;
    app.agent.selectReasoningEffort(AiReasoningEffort.high);
    await app.settings.saveApi(
      format: AiApiFormat.openaiResponses,
      baseUrl: 'https://new.test/v1',
      defaultModel: 'new-default',
      apiKey: 'new-key',
    );
    await loadModels(app.agent);
    old.complete(
      const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {'id': 'old-model'},
          ],
        },
      ),
    );
    await oldFetch;
    expect(app.agent.currentModel!.model, 'new-default');
    expect(app.agent.reasoningEffort.value, AiReasoningEffort.high);
  });

  for (final format in AiApiFormat.values) {
    test('$format 自动省略思考参数，手动高强度按协议发送', () async {
      final connect = FakeAiConnect(
        (_) => switch (format) {
          AiApiFormat.openai => openAiReply('OK'),
          AiApiFormat.openaiResponses => responsesReply([responsesText('OK')]),
          AiApiFormat.anthropic => anthropicReply([
            {'type': 'text', 'text': 'OK'},
          ]),
        },
      );
      final app = await setup(connect, format: format);
      await app.agent.send('Auto');
      for (final field in [
        'reasoning',
        'reasoning_effort',
        'thinking',
        'output_config',
      ]) {
        expect(connect.requests.last.body, isNot(contains(field)));
      }
      app.agent.selectReasoningEffort(AiReasoningEffort.high);
      await app.agent.send('High');
      final request = connect.requests.last.body;
      switch (format) {
        case AiApiFormat.openai:
          expect(request['reasoning_effort'], 'high');
          expect(request, isNot(contains('reasoning')));
        case AiApiFormat.openaiResponses:
          expect(request['reasoning'], {'effort': 'high'});
          expect(request, isNot(contains('reasoning_effort')));
        case AiApiFormat.anthropic:
          expect(request['thinking'], {'type': 'adaptive'});
          expect(request['output_config'], {'effort': 'high'});
      }
      expect(app.agent.error.value, isNull);
    });
  }

  test('Anthropic 能力限定强度，原始思考和签名随工具结果完整回传', () async {
    const thinking = {
      'type': 'thinking',
      'thinking': '',
      'signature': 'signed-thinking',
    };
    const redacted = {
      'type': 'redacted_thinking',
      'data': 'encrypted-thinking',
    };
    var posts = 0;
    final connect = FakeAiConnect(
      (_) => ++posts == 1
          ? anthropicReply([
              thinking,
              redacted,
              {'type': 'text', 'text': 'Checking'},
              {
                'type': 'tool_use',
                'id': 'thinking-tool',
                'name': 'read_skill',
                'input': {'id': 'ssh'},
              },
            ])
          : anthropicReply([
              {'type': 'text', 'text': 'OK'},
            ]),
      getHandler: (_) => const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {
              'id': 'custom-model',
              'max_tokens': 64000,
              'capabilities': {
                'effort': {
                  'supported': true,
                  'low': {'supported': true},
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
        },
      ),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await loadModels(app.agent);
    expect(app.agent.reasoningOptions, [
      AiReasoningEffort.auto,
      AiReasoningEffort.low,
      AiReasoningEffort.high,
    ]);
    app.agent.selectReasoningEffort(AiReasoningEffort.max);
    expect(app.agent.reasoningEffort.value, AiReasoningEffort.auto);
    app.agent.selectReasoningEffort(AiReasoningEffort.high);
    await app.agent.send('SSH help');
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    final assistant = messages[1] as Map;
    expect((assistant['content'] as List).take(2), [thinking, redacted]);
    expect(connect.requests.last.body['thinking'], {'type': 'adaptive'});
    expect(connect.requests.last.body['output_config'], {'effort': 'high'});
    expect(jsonEncode(messages.last), contains('thinking-tool'));
    expect(
      app.agent.entries.any((entry) => entry.text.contains('signed-thinking')),
      isFalse,
    );
    await app.agent.send('Continue');
    expect(
      jsonEncode(connect.requests.last.body['messages']),
      contains('signed-thinking'),
    );
    app.agent.selectReasoningEffort(AiReasoningEffort.low);
    await app.agent.send('New effort');
    expect(
      jsonEncode(connect.requests.last.body['messages']),
      isNot(contains('signed-thinking')),
    );
    expect(app.agent.error.value, isNull);
  });

  test('Anthropic 旧式思考使用能力预算且小于输出上限，临时测试不污染缓存', () async {
    final connect = FakeAiConnect(
      (_) => anthropicReply([
        {'type': 'text', 'text': 'OK'},
      ]),
      getHandler: (request) {
        final draft = request.headers!['x-api-key'] == 'draft-key';
        final model = {
          'id': 'custom-model',
          'max_tokens': draft ? 2048 : 4096,
          'capabilities': {
            'effort': {'supported': false},
            'thinking': {
              'supported': true,
              'types': {
                'adaptive': {'supported': false},
                'enabled': {'supported': !draft},
              },
            },
          },
        };
        return Response<dynamic>(
          statusCode: 200,
          body: request.url!.contains('/models/')
              ? model
              : {
                  'data': [model],
                },
        );
      },
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await loadModels(app.agent);
    expect(app.agent.reasoningOptions, [
      AiReasoningEffort.auto,
      AiReasoningEffort.low,
      AiReasoningEffort.medium,
      AiReasoningEffort.high,
    ]);
    await app.agent.testConnection(
      app.settings.state.value.apiConfig!,
      apiKey: 'draft-key',
    );
    app.agent.selectReasoningEffort(AiReasoningEffort.medium);
    await app.agent.send('Think');
    expect(connect.requests.last.body['max_tokens'], 4096);
    expect(connect.requests.last.body['thinking'], {
      'type': 'enabled',
      'budget_tokens': 4095,
    });
    expect(connect.requests.last.body, isNot(contains('output_config')));
    expect(app.agent.error.value, isNull);
  });

  test('服务商拒绝思考参数时给出可恢复提示且不泄露错误原文', () async {
    final connect = FakeAiConnect(
      (_) => const Response<dynamic>(
        statusCode: 400,
        body: {
          'error': {'message': 'reasoning_effort unsupported private-test-key'},
        },
      ),
    );
    final app = await setup(connect);
    app.agent.selectReasoningEffort(AiReasoningEffort.high);
    await app.agent.send('Think');
    expect(app.agent.error.value, '当前模型不支持所选思考强度，请选择自动或其他强度');
    expect(app.agent.error.value, isNot(contains('private-test-key')));
  });

  test('技能工具循环返回关联结果，模型不直接执行命令', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('read_skill', {'id': 'ssh'}),
              ],
            )
          : openAiReply('Check DNS.'),
    );
    final app = await setup(connect);
    await app.agent.send('SSH fails');
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    expect((messages.last as Map)['role'], 'tool');
    expect((messages.last as Map)['tool_call_id'], 'call-1');
    expect((messages.last as Map)['content'], contains('host-key'));
    expect(
      app.agent.entries.any(
        (e) => e.kind == AgentEntryKind.tool && e.text == 'SSH 运维',
      ),
      isTrue,
    );
  });

  test('Anthropic 使用 system、版本头、tool_use 和 user tool_result', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? anthropicReply([
              {
                'type': 'tool_use',
                'id': 'claude-call',
                'name': 'read_skill',
                'input': {'id': 'rdp'},
              },
              {
                'type': 'tool_use',
                'id': 'claude-context',
                'name': 'get_workspace_context',
                'input': <String, Object>{},
              },
            ])
          : anthropicReply([
              {'type': 'text', 'text': 'Check NLA.'},
            ]),
      getHandler: (_) => const Response<dynamic>(
        statusCode: 200,
        body: {'id': 'custom-model', 'max_tokens': 131072},
      ),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await app.agent.send('RDP fails');
    final request = connect.requests.last;
    expect(request.url, 'https://api.test/v1/messages');
    expect(request.headers!['x-api-key'], 'private-test-key');
    expect(request.headers!['anthropic-version'], '2023-06-01');
    expect(request.body['system'], isA<String>());
    expect(request.body['max_tokens'], 131072);
    final messages = request.body['messages'] as List<dynamic>;
    expect((messages[1] as Map)['role'], 'assistant');
    final results = (messages.last as Map)['content'] as List<dynamic>;
    expect((messages.last as Map)['role'], 'user');
    expect(results.map((dynamic b) => (b as Map)['tool_use_id']), [
      'claude-call',
      'claude-context',
    ]);
    expect(app.agent.error.value, isNull);
  });

  test('Responses 保留 reasoning 和 call_id，工具往返及后续聊天不要求输出上限', () async {
    var count = 0;
    final reasoning = <String, Object>{
      'id': 'rs-1',
      'type': 'reasoning',
      'summary': <Object>[],
      'encrypted_content': 'encrypted-fixture',
    };
    final call = <String, Object>{
      'id': 'fc-1',
      'type': 'function_call',
      'call_id': 'responses-call',
      'name': 'read_skill',
      'arguments': '{"id":"ssh"}',
      'status': 'completed',
    };
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? responsesReply([reasoning, call])
          : responsesReply([responsesText('Check the host key.')]),
    );
    final app = await setup(connect, format: AiApiFormat.openaiResponses);
    await app.agent.send('SSH fails');
    expect(app.agent.error.value, isNull);
    final request = connect.requests[1];
    expect(request.url, 'https://api.test/v1/responses');
    expect(request.headers!['Authorization'], 'Bearer private-test-key');
    expect(request.body['instructions'], isA<String>());
    expect(request.body['store'], isFalse);
    expect(request.body['include'], ['reasoning.encrypted_content']);
    expect(request.body, isNot(contains('max_tokens')));
    expect(request.body, isNot(contains('max_output_tokens')));
    final input = request.body['input'] as List<dynamic>;
    expect(input[1], reasoning);
    expect(input[2], call);
    expect(input.last, {
      'type': 'function_call_output',
      'call_id': 'responses-call',
      'output': contains('host-key'),
    });
    final tools = request.body['tools'] as List<dynamic>;
    expect((tools.first as Map)['type'], 'function');
    expect((tools.first as Map)['name'], 'read_skill');
    expect((tools.first as Map).containsKey('function'), isFalse);
    await app.agent.send('What next?');
    expect(app.agent.error.value, isNull);
    expect(
      jsonEncode(connect.requests.last.body),
      contains('encrypted-fixture'),
    );
    expect((connect.requests.last.body['input'] as List).last, {
      'role': 'user',
      'content': 'What next?',
    });
  });

  test('Responses 更换模型或 Key 后重建历史，不回放其他配置的加密项目', () {
    AiModelConfig config(String model, String ref) => AiModelConfig(
      id: 'fixture',
      name: 'fixture',
      format: AiApiFormat.openaiResponses,
      baseUrl: 'https://provider.test/v1',
      model: model,
      secretRef: ref,
    );
    final original = config('model-a', 'key-a');
    final turn = AgentApiCodec.parse(AiApiFormat.openaiResponses, {
      'status': 'completed',
      'output': [
        {
          'type': 'reasoning',
          'id': 'rs',
          'summary': <Object>[],
          'encrypted_content': 'private-reasoning',
        },
        responsesText('Earlier answer'),
      ],
    }, responsesScope: AgentApiCodec.responsesScope(original)).turn;
    for (final changed in [
      config('model-b', 'key-a'),
      config('model-a', 'key-b'),
    ]) {
      final body = AgentApiCodec.request(changed, 'system', [
        const AgentTurn('user', 'Earlier question'),
        turn,
        const AgentTurn('user', 'New question'),
      ]);
      expect(jsonEncode(body), isNot(contains('private-reasoning')));
      expect((body['input'] as List)[1], {
        'role': 'assistant',
        'content': 'Earlier answer',
      });
    }
  });

  test('Responses 拒绝错误状态，截断的工具调用不执行', () async {
    expect(
      () => AgentApiCodec.parse(AiApiFormat.openaiResponses, {
        'status': 'failed',
        'output': [responsesText('partial')],
      }),
      throwsA(isA<AgentApiException>()),
    );
    final connect = FakeAiConnect(
      (_) => const Response<dynamic>(
        statusCode: 200,
        body: {
          'status': 'incomplete',
          'incomplete_details': {'reason': 'max_output_tokens'},
          'output': [
            {
              'type': 'function_call',
              'id': 'fc',
              'call_id': 'call',
              'name': 'read_skill',
              'arguments': '{"id":"ssh"}',
            },
          ],
        },
      ),
    );
    final app = await setup(connect, format: AiApiFormat.openaiResponses);
    await app.agent.send('SSH fails');
    expect(connect.requests, hasLength(1));
    expect(
      app.agent.entries.where((entry) => entry.kind == AgentEntryKind.tool),
      isEmpty,
    );
    expect(app.agent.error.value, 'AI 回复达到服务商长度上限，请缩小问题或继续提问');
  });

  test('模型列表支持当前 Key、保险库 Key、分页去重，并缓存 Anthropic 模型能力', () async {
    final connect = FakeAiConnect(
      (_) => anthropicReply([
        {'type': 'text', 'text': 'OK'},
      ]),
      getHandler: (request) => Response<dynamic>(
        statusCode: 200,
        body: Uri.parse(request.url!).queryParameters.containsKey('after_id')
            ? {
                'data': [
                  {'id': 'custom-model', 'max_tokens': 131072},
                ],
                'has_more': false,
              }
            : {
                'data': [
                  {'id': 'z-model'},
                  {'id': 'custom-model', 'max_tokens': 131072},
                ],
                'has_more': true,
                'last_id': 'page-1',
              },
      ),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    final modelId = app.settings.state.value.selectedModel!.id;
    final models = await app.agent.fetchModels(
      format: AiApiFormat.anthropic,
      baseUrl: 'https://api.test/v1/messages',
      apiKey: '',
      modelConfigId: modelId,
    );
    expect(models.map((model) => model.id), ['custom-model', 'z-model']);
    expect(connect.requests.first.headers!['x-api-key'], 'private-test-key');
    expect(Uri.parse(connect.requests.first.url!).path, '/v1/models');
    expect(
      Uri.parse(connect.requests.last.url!).queryParameters['after_id'],
      'page-1',
    );
    await app.agent.send('Hello');
    expect(app.agent.error.value, isNull);
    expect(
      connect.requests.where((request) => request.method == 'GET'),
      hasLength(2),
    );
    expect(connect.requests.last.body['max_tokens'], 131072);
    await app.agent.fetchModels(
      format: AiApiFormat.openaiResponses,
      baseUrl: 'https://api.test/proxy/v1/responses',
      apiKey: 'new-key',
      modelConfigId: modelId,
    );
    expect(connect.requests.last.headers!['Authorization'], 'Bearer new-key');
    expect(Uri.parse(connect.requests.last.url!).path, '/proxy/v1/models');
  });

  test('模型列表校验发生在请求前，获取错误不会泄露 Key 或服务端原文', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (_) =>
          const Response<dynamic>(statusCode: 401, body: 'private-test-key'),
    );
    final app = await setup(connect);
    for (final url in ['', 'https://p.test/?api_key=secret']) {
      await expectLater(
        app.agent.fetchModels(
          format: AiApiFormat.openai,
          baseUrl: url,
          apiKey: 'key',
        ),
        throwsA(isA<AgentApiException>()),
      );
    }
    await expectLater(
      app.agent.fetchModels(
        format: AiApiFormat.openai,
        baseUrl: 'https://p.test',
      ),
      throwsA(isA<AgentApiException>()),
    );
    expect(connect.requests, isEmpty);
    await expectLater(
      app.agent.fetchModels(
        format: AiApiFormat.openai,
        baseUrl: 'https://p.test',
        apiKey: 'private-test-key',
      ),
      throwsA(
        isA<AgentApiException>().having(
          (error) => error.message,
          'message',
          'AI API 认证失败，请检查 API Key',
        ),
      ),
    );
  });

  test('Anthropic 兼容服务没有目录时仍可手输模型并使用服务商默认输出', () async {
    final connect = FakeAiConnect(
      (_) => anthropicReply([
        {'type': 'text', 'text': 'OK'},
      ]),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await app.agent.send('Hello');
    expect(app.agent.error.value, isNull);
    expect(connect.requests.last.method, 'POST');
    expect(connect.requests.last.body, isNot(contains('max_tokens')));
  });

  test('Anthropic 服务商强制上限但未提供模型能力时明确提示', () async {
    final connect = FakeAiConnect(
      (_) => const Response<dynamic>(
        statusCode: 400,
        body: {
          'error': {'message': 'max_tokens is required: private-test-key'},
        },
      ),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await app.agent.send('Hello');
    expect(app.agent.error.value, '无法读取 Anthropic 模型输出上限，请检查服务商的模型接口');
    expect(connect.requests.last.body, isNot(contains('max_tokens')));
  });

  test('Anthropic 模型详情不可用时可从模型列表读取最大输出能力', () async {
    final connect = FakeAiConnect(
      (_) => anthropicReply([
        {'type': 'text', 'text': 'OK'},
      ]),
      getHandler: (request) => Uri.parse(request.url!).path.endsWith('/models')
          ? const Response<dynamic>(
              statusCode: 200,
              body: {
                'data': [
                  {'id': 'custom-model', 'max_tokens': 96000},
                ],
              },
            )
          : const Response<dynamic>(statusCode: 404),
    );
    final app = await setup(connect, format: AiApiFormat.anthropic);
    await app.agent.send('Hello');
    expect(app.agent.error.value, isNull);
    expect(connect.requests.last.body['max_tokens'], 96000);
  });

  test('命令建议绑定原会话，未经批准不发送，切换标签后仍发送原目标', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'command': 'df -h',
                  'purpose': 'Check disk',
                }),
              ],
            )
          : openAiReply('Review the proposed command.'),
    );
    final app = await setup(connect);
    final first = <String>[];
    final second = <String>[];
    app.sessions.sessions.addAll([
      terminal('one', first),
      terminal('two', second),
    ]);
    app.sessions.activeSessionId.value = 'one';
    app.agent.setReferencedSessions([app.sessions.activeSession!]);
    final run = app.agent.send('Check disk');
    final proposal = await pendingCommand(app.agent);
    expect(first, isEmpty);
    expect(second, isEmpty);
    app.sessions.activeSessionId.value = 'two';
    expect(app.agent.approveCommand(proposal), isTrue);
    expect(first, ['df -h\r']);
    expect(second, isEmpty);
    expect(app.agent.approveCommand(proposal), isFalse);
    expect(first, hasLength(1));
    app.sessions.sessions.first.terminal!.write('disk output\r\n');
    await run;
    expect(jsonEncode(connect.requests.last.body), contains('disk output'));
    expect(app.agent.waitingForApproval.value, isFalse);
  });

  test('会话已替换或关闭时拒绝发送，RDP 和未共享时拒绝命令工具', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count % 2 == 1
          ? openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'command': 'whoami',
                  'purpose': 'Account',
                }),
              ],
            )
          : openAiReply('Review.'),
    );
    final app = await setup(connect);
    final written = <String>[];
    app.sessions.sessions.add(terminal('one', written));
    app.sessions.activeSessionId.value = 'one';
    await app.agent.send('Run whoami');
    expect(app.agent.entries.where((e) => e.command != null), isEmpty);
    app.agent.setReferencedSessions([app.sessions.activeSession!]);
    final run = app.agent.send('Run whoami');
    final proposal = await pendingCommand(app.agent);
    app.sessions.sessions[0] = terminal('one', written);
    expect(app.agent.approveCommand(proposal), isFalse);
    expect(written, isEmpty);
    await run;
    app.sessions.sessions[0] = const Session(
      id: 'one',
      host: Host(
        id: 'one',
        name: 'RDP',
        hostname: 'rdp',
        serviceType: ServiceType.rdp,
      ),
      kind: SessionKind.remoteDesktop,
      phase: SessionPhase.ready,
    );
    await app.agent.send('Run PowerShell');
    expect(app.agent.entries.where((e) => e.command != null), hasLength(1));
  });

  test('状态工具仅在共享会话时读取，响应不把单次累计 CPU 当作占用率', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count % 2 == 1
          ? openAiReply('', calls: [tool('get_server_status', {})])
          : openAiReply('Memory is 50%.'),
    );
    final app = await setup(connect);
    final engine = _SshSession();
    app.sessions.sessions.add(terminal('one', [], engine: engine));
    app.sessions.activeSessionId.value = 'one';
    await app.agent.send('Status?');
    expect(engine.reads, 0);
    app.agent.setReferencedSessions([app.sessions.activeSession!]);
    await app.agent.send('Status?');
    expect(engine.reads, 1);
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    final data = jsonDecode(
      (messages.last as Map)['content'] as String,
    ) as Map<String, dynamic>;
    expect(data['memoryAvailableBytes'], 4000);
    expect(data['cpuFraction'], isNull);
  });

  test('只读取 @ 所选终端，自动携带近期输出且读取工具能获得新输出', () async {
    late Session selected;
    var count = 0;
    final connect = FakeAiConnect((_) {
      if (++count == 1) {
        selected.terminal!.write('\r\nnew-port-listener');
        return openAiReply(
          '',
          calls: [
            tool('read_terminal_output', {'lines': 200}),
          ],
        );
      }
      return openAiReply('Port 80 is in use.');
    });
    final app = await setup(connect);
    final written = <String>[];
    selected = terminal('selected', written);
    selected.terminal!.write('\x1b[31mnginx LISTEN :80\x1b[0m\r\n');
    final other = terminal('other', [])
      ..terminal!.write('unselected-private-output');
    app.sessions.sessions.addAll([selected, other]);
    app.sessions.activeSessionId.value = other.id;
    app.agent.setReferencedSessions([selected]);
    expect(app.agent.selectedSessions, [selected]);
    await app.agent.send('Check port 80');
    final first = jsonEncode(connect.requests.first.body);
    final last = jsonEncode(connect.requests.last.body);
    expect(first, contains('nginx LISTEN :80'));
    expect(last, contains('new-port-listener'));
    expect(last, isNot(contains('unselected-private-output')));
    expect(last, isNot(contains('sensitive-user')));
    expect(last, isNot(contains('secret-note')));
    expect(written, isEmpty);
    expect(app.agent.error.value, isNull);
  });

  test('未选择会话时读取工具不能读取活动页签输出；选中后输出有界', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => (++count).isOdd
          ? openAiReply('', calls: [tool('read_terminal_output', {})])
          : openAiReply('OK'),
    );
    final app = await setup(connect);
    final selected = terminal('one', []);
    selected.terminal!.write('unshared-only-output');
    app.sessions.sessions.add(selected);
    app.sessions.activeSessionId.value = selected.id;
    await app.agent.send('Read output');
    expect(
      jsonEncode(connect.requests.last.body),
      isNot(contains('unshared-only-output')),
    );
    app.agent.setReferencedSessions([selected]);
    selected.terminal!.resize(240, 24);
    for (var index = 0; index < 400; index++) {
      selected.terminal!.write('line-$index ${'x' * 180}\r\n');
    }
    await app.agent.send('Read latest output');
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    final result =
        jsonDecode((messages.last as Map)['content'] as String) as Map;
    expect((result['output'] as String).length, lessThanOrEqualTo(16000));
    expect(result['output'], contains('line-399'));
    expect(result['output'], isNot(contains('line-0 ')));
    expect(result['truncated'], isTrue);
    expect(result['completionKnown'], isFalse);
  });

  test('多个引用分别读取输出和状态，不读取未引用会话，也不猜测缺失目标', () async {
    late Session first;
    late Session second;
    var count = 0;
    final connect = FakeAiConnect((_) {
      if (++count > 1) return openAiReply('Compared.');
      first.terminal!.write('alpha-new-output\r\n');
      second.terminal!.write('beta-new-output\r\n');
      return openAiReply(
        '',
        calls: [
          tool('get_workspace_context', {}, id: 'context'),
          tool('read_terminal_output', {'session_id': 'alpha'}, id: 'alpha'),
          tool('read_terminal_output', {'session_id': 'beta'}, id: 'beta'),
          tool('read_terminal_output', {
            'session_id': 'private',
          }, id: 'foreign'),
          tool('read_terminal_output', {}, id: 'ambiguous'),
          tool('get_server_status', {'session_id': 'beta'}, id: 'status'),
        ],
      );
    });
    final app = await setup(connect);
    final alphaEngine = _SshSession();
    final betaEngine = _SshSession();
    first = terminal('alpha', [], engine: alphaEngine)
      ..terminal!.write('alpha-initial-output\r\n');
    second = terminal('beta', [], engine: betaEngine)
      ..terminal!.write('beta-initial-output\r\n');
    app.sessions.sessions.addAll([
      first,
      second,
      terminal('private', [])..terminal!.write('unreferenced-private-output'),
    ]);
    app.sessions.activeSessionId.value = 'private';
    app.agent.setReferencedSessions([first, second, first]);
    expect(app.agent.selectedSessions, [first, second]);
    await app.agent.send('Compare @Host alpha and @Host beta');
    final initial = jsonEncode(connect.requests.first.body);
    expect(initial, contains('alpha-initial-output'));
    expect(initial, contains('beta-initial-output'));
    final payload = jsonEncode(connect.requests.last.body);
    expect(payload, isNot(contains('unreferenced-private-output')));
    expect(payload, isNot(contains('secret-note')));
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    final results = {
      for (final dynamic message in messages)
        if ((message as Map)['role'] == 'tool')
          message['tool_call_id']: jsonDecode(message['content'] as String),
    };
    expect((results['context'] as Map)['sessions'], hasLength(2));
    expect((results['alpha'] as Map)['output'], contains('alpha-new-output'));
    expect(
      (results['alpha'] as Map)['output'],
      isNot(contains('beta-new-output')),
    );
    expect((results['beta'] as Map)['output'], contains('beta-new-output'));
    expect((results['foreign'] as Map)['available'], isFalse);
    expect((results['ambiguous'] as Map)['available'], isFalse);
    expect((results['status'] as Map)['session_id'], 'beta');
    expect(alphaEngine.reads, 0);
    expect(betaEngine.reads, 1);
    expect(app.agent.error.value, isNull);
  });

  for (final mode in AgentAccessMode.values) {
    test('$mode 多引用的命令缺少目标或指定未引用目标时不发送', () async {
      var count = 0;
      final connect = FakeAiConnect(
        (_) => ++count == 1
            ? openAiReply(
                '',
                calls: [
                  tool('propose_ssh_command', {
                    'command': 'whoami',
                    'purpose': 'Check identity',
                  }, id: 'ambiguous'),
                  tool('propose_ssh_command', {
                    'session_id': 'private',
                    'command': 'whoami',
                    'purpose': 'Check identity',
                  }, id: 'foreign'),
                ],
              )
            : openAiReply('Choose a referenced target.'),
      );
      final app = await setup(connect);
      final written = <String>[];
      final first = terminal('alpha', written);
      final second = terminal('beta', written);
      app.sessions.sessions.addAll([
        first,
        second,
        terminal('private', written),
      ]);
      app.agent.setReferencedSessions([first, second]);
      app.agent.selectAccessMode(mode);
      await app.agent.send('Check identity on the servers');
      expect(written, isEmpty);
      expect(app.agent.entries.where((e) => e.command != null), isEmpty);
      expect(
        jsonEncode(connect.requests.last.body),
        contains('Specify session_id'),
      );
    });
  }

  test('多引用批准卡固定单个目标，编辑下一条草稿不会改变运行中的目标', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'session_id': 'beta',
                  'command': 'whoami',
                  'purpose': 'Check identity',
                }),
              ],
            )
          : openAiReply('Observed.'),
    );
    final app = await setup(connect);
    final firstWrites = <String>[];
    final secondWrites = <String>[];
    final first = terminal('alpha', firstWrites);
    final second = terminal('beta', secondWrites);
    second.terminal!.onOutput = (input) {
      secondWrites.add(input);
      second.terminal!.write('beta-user\r\n');
    };
    app.sessions.sessions.addAll([first, second]);
    app.agent.setReferencedSessions([first, second]);
    final run = app.agent.send('Read @Host alpha and @Host beta');
    final proposal = await pendingCommand(app.agent);
    expect(proposal.target, same(second));
    expect(secondWrites, isEmpty);
    app.agent.setReferencedSessions([]);
    app.sessions.activeSessionId.value = first.id;
    expect(app.agent.approveCommand(proposal), isTrue);
    await run;
    expect(firstWrites, isEmpty);
    expect(secondWrites, ['whoami\r']);
  });

  for (final format in AiApiFormat.values) {
    test('$format 多引用完全访问只输入指定会话并将输出送回模型继续分析', () async {
      var count = 0;
      final connect = FakeAiConnect((_) {
        if (++count == 1) {
          return switch (format) {
            AiApiFormat.openai => openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'session_id': 'one',
                  'command': 'ss -lntp',
                  'purpose': 'Check listeners',
                }),
              ],
            ),
            AiApiFormat.openaiResponses => responsesReply([
              {
                'type': 'function_call',
                'call_id': 'input-1',
                'name': 'propose_ssh_command',
                'arguments': '{"session_id":"one","command":"ss -lntp","purpose":"Check listeners"}',
              },
            ]),
            AiApiFormat.anthropic => anthropicReply([
              {
                'type': 'tool_use',
                'id': 'input-1',
                'name': 'propose_ssh_command',
                'input': {
                  'session_id': 'one',
                  'command': 'ss -lntp',
                  'purpose': 'Check listeners',
                },
              },
            ]),
          };
        }
        return switch (format) {
          AiApiFormat.openai => openAiReply('nginx owns port 80.'),
          AiApiFormat.openaiResponses => responsesReply([
            responsesText('nginx owns port 80.'),
          ]),
          AiApiFormat.anthropic => anthropicReply([
            {'type': 'text', 'text': 'nginx owns port 80.'},
          ]),
        };
      });
      final app = await setup(connect, format: format);
      final written = <String>[];
      final otherWrites = <String>[];
      final target = terminal('one', written);
      target.terminal!.onOutput = (input) {
        written.add(input);
        target.terminal!.write('\r\nnginx LISTEN 0.0.0.0:80\r\n');
      };
      final second = terminal('two', otherWrites);
      app.sessions.sessions.addAll([target, second]);
      app.agent.setReferencedSessions([target, second]);
      app.agent.selectAccessMode(AgentAccessMode.fullAccess);
      app.sessions.activeSessionId.value = 'two';
      await app.agent.send('Check port 80');
      expect(written, ['ss -lntp\r']);
      expect(otherWrites, isEmpty);
      expect(count, 2);
      expect(
        jsonEncode(connect.requests.last.body),
        contains('nginx LISTEN 0.0.0.0:80'),
      );
      expect(app.agent.entries.last.text, 'nginx owns port 80.');
      expect(
        app.agent.entries
            .firstWhere((entry) => entry.command != null)
            .command!
            .state
            .value,
        AgentCommandState.sent,
      );
      expect(app.agent.error.value, isNull);
    });
  }

  test('拒绝输入后模型获得拒绝结果，不向终端写入', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'command': 'whoami',
                  'purpose': 'Check user',
                }),
              ],
            )
          : openAiReply('Input rejected.'),
    );
    final app = await setup(connect);
    final written = <String>[];
    final target = terminal('one', written);
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    final run = app.agent.send('Check user');
    final proposal = await pendingCommand(app.agent);
    expect(app.agent.waitingForApproval.value, isTrue);
    expect(count, 1);
    app.agent.rejectCommand(proposal);
    await run;
    expect(written, isEmpty);
    expect(jsonEncode(connect.requests.last.body), contains('Nothing sent'));
    expect(app.agent.waitingForApproval.value, isFalse);
    expect(app.agent.busy.value, isFalse);
  });

  test('停止或原连接替换会解除批准等待；新连接重新选择并沿用审核模式', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply(
        '',
        calls: [
          tool('propose_ssh_command', {
            'command': 'whoami',
            'purpose': 'Check user',
          }),
        ],
      ),
    );
    final app = await setup(connect);
    app.agent.onInit();
    final written = <String>[];
    var target = terminal('one', written);
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    var run = app.agent.send('Check user');
    var proposal = await pendingCommand(app.agent);
    app.agent.stop();
    await run;
    expect(app.agent.approveCommand(proposal), isFalse);
    expect(written, isEmpty);
    run = app.agent.send('Check user');
    proposal = await pendingCommand(app.agent);
    app.sessions.sessions[0] = terminal('one', written);
    await run;
    expect(app.agent.selectedSessions, isEmpty);
    expect(app.agent.approveCommand(proposal), isFalse);
    expect(written, isEmpty);
    target = app.sessions.sessions.first;
    app.agent.setReferencedSessions([target]);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    final second = terminal('two', []);
    app.sessions.sessions.add(second);
    app.agent.setReferencedSessions([second]);
    expect(app.agent.accessMode.value, AgentAccessMode.fullAccess);
  });

  test('完全访问发送后停止立即结束输出等待，迟到输出不请求模型', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply(
        '',
        calls: [
          tool('propose_ssh_command', {
            'command': 'sleep 60',
            'purpose': 'Wait',
          }),
        ],
      ),
    );
    final app = await setup(connect);
    final sent = Completer<void>();
    final target = terminal('one', []);
    target.terminal!.onOutput = (_) => sent.complete();
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    final run = app.agent.send('Wait');
    await sent.future;
    app.agent.stop();
    await run;
    target.terminal!.write('late-output');
    expect(connect.requests, hasLength(1));
    expect(app.agent.busy.value, isFalse);
    expect(target.terminal!.listeners, isEmpty);
  });

  testWidgets('终端无新输出时观察有超时，返回未知完成状态且不重复发送', (tester) async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('propose_ssh_command', {
                  'command': 'sleep 60',
                  'purpose': 'Wait for process',
                }),
              ],
            )
          : openAiReply('No new output; completion is unknown.'),
    );
    final app = await setup(connect);
    final written = <String>[];
    final target = terminal('one', written);
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    final run = app.agent.send('Wait');
    await tester.pump();
    expect(written, ['sleep 60\r']);
    await tester.pump(const Duration(seconds: 9));
    await run;
    expect(written, hasLength(1));
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    final result =
        jsonDecode((messages.last as Map)['content'] as String) as Map;
    final output = result['terminal'] as Map;
    expect(output['observation'], 'observation_timeout');
    expect(output['outputChanged'], isFalse);
    expect(output['completionKnown'], isFalse);
    expect(target.terminal!.listeners, isEmpty);
  });

  testWidgets('读取工具能等候后续输出，读取期间不向会话写入', (tester) async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                tool('read_terminal_output', {'wait_ms': 5000}),
              ],
            )
          : openAiReply('Observed new output.'),
    );
    final app = await setup(connect);
    final written = <String>[];
    final target = terminal('one', written);
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    final run = app.agent.send('Read more output');
    await tester.pump();
    target.terminal!.write('later-output\r\n');
    await tester.pump(const Duration(milliseconds: 700));
    await run;
    expect(jsonEncode(connect.requests.last.body), contains('later-output'));
    expect(written, isEmpty);
    expect(target.terminal!.listeners, isEmpty);
  });

  test('发送输入的同步回调关闭原连接时，取消等待且不继续请求模型', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply(
        '',
        calls: [
          tool('propose_ssh_command', {
            'command': 'exit',
            'purpose': 'Close shell',
          }),
        ],
      ),
    );
    final app = await setup(connect);
    app.agent.onInit();
    final written = <String>[];
    final target = terminal('one', written);
    target.terminal!.onOutput = (input) {
      written.add(input);
      app.sessions.sessions.clear();
    };
    app.sessions.sessions.add(target);
    app.agent.setReferencedSessions([target]);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    await app.agent.send('Close shell');
    expect(written, ['exit\r']);
    expect(connect.requests, hasLength(1));
    expect(app.agent.selectedSessions, isEmpty);
    expect(app.agent.busy.value, isFalse);
    expect(target.terminal!.listeners, isEmpty);
    expect(app.agent.error.value, isNull);
  });

  test('停止和清空使迟到响应失效，不生成建议或污染新聊天', () async {
    final pending = Completer<Response<dynamic>>();
    final called = Completer<void>();
    var count = 0;
    final connect = FakeAiConnect((_) {
      if (++count == 1) {
        called.complete();
        return pending.future;
      }
      return openAiReply('New reply');
    });
    final app = await setup(connect);
    final first = app.agent.send('First');
    await called.future;
    app.agent.clear();
    await app.agent.send('Second');
    pending.complete(
      openAiReply(
        'Late response',
        calls: [
          tool('propose_ssh_command', {'command': 'rm x', 'purpose': 'remove'}),
        ],
      ),
    );
    await first;
    expect(app.agent.entries.map((e) => e.text), ['Second', 'New reply']);
    expect(app.agent.busy.value, isFalse);
  });

  test('认证和服务端格式错误显示脱敏提示，错误历史不发送无配对工具消息', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? const Response<dynamic>(statusCode: 401, body: 'private-test-key')
          : openAiReply('OK'),
    );
    final app = await setup(connect);
    await app.agent.send('Fail');
    expect(app.agent.error.value, 'AI API 认证失败，请检查 API Key');
    await app.agent.send('Retry');
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    expect(messages, hasLength(2));
    expect(
      jsonEncode(app.agent.entries.map((e) => e.text).toList()),
      isNot(contains('private-test-key')),
    );
    expect(
      () =>
          AgentApiCodec.parse(AiApiFormat.openai, {'bad': 'private-test-key'}),
      throwsA(isA<AgentApiException>()),
    );
  });

  test('长对话仅提交完整最近轮次，工具调用和结果保持配对', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count % 2 == 1
          ? openAiReply(
              '',
              calls: [
                tool('read_skill', {'id': 'pagashell'}),
              ],
            )
          : openAiReply('Reply'),
    );
    final app = await setup(connect);
    for (var i = 0; i < 16; i++) {
      await app.agent.send('Turn $i');
    }
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    expect(
      messages.where((dynamic m) => (m as Map)['role'] == 'user'),
      hasLength(12),
    );
    expect((messages[1] as Map)['role'], 'user');
    for (var i = 1; i < messages.length; i++) {
      final message = messages[i] as Map;
      if (message['role'] != 'tool') continue;
      final previous = messages[i - 1] as Map;
      expect(previous['role'], 'assistant');
      expect(
        ((previous['tool_calls'] as List).single as Map)['id'],
        message['tool_call_id'],
      );
    }
    expect(app.agent.historyTrimmed.value, isTrue);
    app.agent.clear();
    expect(app.agent.historyTrimmed.value, isFalse);
  });

  for (final format in AiApiFormat.values) {
    test('$format 测试未保存配置使用当前地址和 Key，编辑留空可复用保险库 Key', () async {
      final connect = FakeAiConnect(
        (_) => switch (format) {
          AiApiFormat.openai => openAiReply('OK'),
          AiApiFormat.openaiResponses => responsesReply([responsesText('OK')]),
          AiApiFormat.anthropic => anthropicReply([
            {'type': 'text', 'text': 'OK'},
          ]),
        },
        getHandler: (_) => const Response<dynamic>(
          statusCode: 200,
          body: {'max_tokens': 131072},
        ),
      );
      final app = await setup(connect, format: format);
      final saved = app.settings.state.value.selectedModel!;
      final draft = AiModelConfig(
        id: '',
        name: '',
        format: format,
        baseUrl: 'https://draft.test/v1',
        model: 'draft-model',
        secretRef: saved.secretRef,
      );
      await app.agent.testConnection(draft, apiKey: ' draft-key ');
      expect(connect.requests.last.url, draft.endpoint.toString());
      expect(connect.requests.last.body['model'], 'draft-model');
      expect(
        connect.requests.last.headers![format == AiApiFormat.anthropic
            ? 'x-api-key'
            : 'Authorization'],
        format == AiApiFormat.anthropic ? 'draft-key' : 'Bearer draft-key',
      );
      await app.agent.testConnection(draft, apiKey: '');
      expect(
        connect.requests.last.headers![format == AiApiFormat.anthropic
            ? 'x-api-key'
            : 'Authorization'],
        format == AiApiFormat.anthropic
            ? 'private-test-key'
            : 'Bearer private-test-key',
      );
      expect(app.settings.state.value.models.single, same(saved));
      expect(app.agent.entries, isEmpty);
      expect(app.agent.busy.value, isFalse);
    });
  }

  test('测试连接对无效地址、空模型和空 Key 在请求前报错', () async {
    final connect = FakeAiConnect((_) => openAiReply('OK'));
    final app = await setup(connect);
    for (final values in [
      ('', 'model', 'key', '请输入有效的 API 地址，不含账号、查询参数或片段'),
      ('https://draft.test', '', 'key', '请输入模型 ID'),
      ('https://draft.test', 'model', '', '请输入 API Key'),
    ]) {
      await expectLater(
        app.agent.testConnection(
          AiModelConfig(
            id: '',
            name: '',
            format: AiApiFormat.openai,
            baseUrl: values.$1,
            model: values.$2,
            secretRef: '',
          ),
          apiKey: values.$3,
        ),
        throwsA(
          isA<AgentApiException>().having(
            (error) => error.message,
            'message',
            values.$4,
          ),
        ),
      );
    }
    expect(connect.requests, isEmpty);
  });

  test('工具调用次数有上限，未知工具和无效控制字符不触发执行', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply('', calls: [tool('unknown', {})]),
    );
    final app = await setup(connect);
    await app.agent.send('Loop');
    expect(connect.requests, hasLength(6));
    expect(app.agent.error.value, '已达到本轮工具调用上限，请缩小问题后继续');
    expect(app.agent.busy.value, isFalse);
  });

  test('新建保留旧聊天，恢复后继续完整工具上下文，沿用审核模式并清除目标', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              'Checking',
              calls: [
                tool('read_skill', {'id': 'ssh'}),
              ],
            )
          : openAiReply('Done'),
    );
    final app = await setup(connect);
    final session = terminal('first', []);
    app.sessions.sessions.add(session);
    app.agent.setReferencedSessions([session]);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    await app.agent.send('First chat');
    final first = app.agent.currentConversationId.value!;
    app.agent.clear();
    expect(app.agent.entries, isEmpty);
    expect(app.agent.conversations.single.id, first);
    await app.agent.send('Second chat');
    final second = app.agent.currentConversationId.value!;
    expect(second, isNot(first));
    expect(app.agent.openConversation(first), isTrue);
    expect(app.agent.selectedSessions, isEmpty);
    expect(app.agent.accessMode.value, AgentAccessMode.fullAccess);
    expect(app.agent.entries.first.text, 'First chat');
    await app.agent.send('Continue first');
    final messages = connect.requests.last.body['messages'] as List<dynamic>;
    expect(messages.map((dynamic value) => (value as Map)['role']), [
      'system',
      'user',
      'assistant',
      'tool',
      'assistant',
      'user',
    ]);
    expect(jsonEncode(messages), isNot(contains('Second chat')));
    app.agent.clear();
    await app.agent.historySaved;
    final restarted = await setup(
      FakeAiConnect((_) => openAiReply('Restarted')),
      history: app.history,
    );
    await restarted.agent.loadConversations();
    expect(restarted.agent.conversations, hasLength(2));
    expect(restarted.agent.openConversation(first), isTrue);
    expect(restarted.agent.entries.last.text, 'Done');
    expect(await restarted.agent.deleteConversation(second), isTrue);
    expect(await restarted.agent.deleteConversation(first), isTrue);
    expect(restarted.agent.entries, isEmpty);
    expect(restarted.agent.currentConversationId.value, isNull);
    expect(app.history.items, isEmpty);
  });

  test('失败请求保存在历史中，写入失败重试后可以恢复', () async {
    final app = await setup(
      FakeAiConnect(
        (_) =>
            const Response<dynamic>(statusCode: 401, body: 'private-test-key'),
      ),
    );
    app.history.failSave = true;
    await app.agent.send('Failed request');
    await app.agent.historySaved;
    expect(app.agent.entries.single.text, 'Failed request');
    expect(app.agent.historyError.value, isNotNull);
    app.agent.clear();
    expect(app.agent.conversations.single.error, 'AI API 认证失败，请检查 API Key');
    app.history.failSave = false;
    await app.agent.retryHistory();
    expect(app.agent.historyError.value, isNull);
    final saved = app.history.items.values.single;
    expect(saved.messages.single.text, 'Failed request');
    expect(saved.turns, isEmpty);
    expect(jsonEncode(saved.toJson()), isNot(contains('private-test-key')));
  });

  test('删除正在请求的聊天后迟到回复不复活记录或污染新对话', () async {
    final late = Completer<Response<dynamic>>();
    final started = Completer<void>();
    var count = 0;
    final app = await setup(
      FakeAiConnect((_) {
        if (++count == 1) {
          started.complete();
          return late.future;
        }
        return openAiReply('New response');
      }),
    );
    final firstRequest = app.agent.send('Old request');
    await started.future;
    final old = app.agent.currentConversationId.value!;
    expect(await app.agent.deleteConversation(old), isTrue);
    await app.agent.send('New request');
    late.complete(openAiReply('Late response'));
    await firstRequest;
    await app.agent.historySaved;
    expect(app.agent.entries.map((entry) => entry.text), [
      'New request',
      'New response',
    ]);
    expect(app.history.items.containsKey(old), isFalse);
    expect(app.agent.conversations, hasLength(1));
  });

  test('恢复待审批历史命令仅展示归档卡片，不恢复可执行句柄', () async {
    final connect = FakeAiConnect(
      (_) => openAiReply(
        '',
        calls: [
          tool('propose_ssh_command', {
            'command': 'pwd',
            'purpose': 'Read path',
          }),
        ],
      ),
    );
    final app = await setup(connect);
    final written = <String>[];
    final session = terminal('ssh', written);
    app.sessions.sessions.add(session);
    app.agent.setReferencedSessions([session]);
    final sending = app.agent.send('Read path');
    final pending = await pendingCommand(app.agent);
    final id = app.agent.currentConversationId.value!;
    app.agent.clear();
    await sending;
    expect(pending.state.value, AgentCommandState.rejected);
    expect(app.agent.openConversation(id), isTrue);
    final entry = app.agent.entries.firstWhere(
      (entry) => entry.archivedCommand != null,
    );
    expect(entry.command, isNull);
    expect(entry.archivedCommand!.state, AgentCommandState.rejected);
    expect(app.agent.selectedSessions, isEmpty);
    expect(written, isEmpty);
    expect(app.agent.approveCommand(pending), isFalse);
  });

  test('删除成功后忽略历史读取的旧快照，不把已删除记录重新带回列表', () async {
    final history = _ControlledHistory();
    final app = await setup(
      FakeAiConnect((_) => openAiReply('Saved')),
      history: history,
    );
    await app.agent.send('Delete while reading');
    await app.agent.historySaved;
    final id = app.agent.currentConversationId.value!;
    final old = history.items.values.toList();
    app.agent.clear();
    final read = Completer<List<AgentConversation>>();
    history.pendingRead = read.future;
    final loading = app.agent.loadConversations(retry: true);
    expect(await app.agent.deleteConversation(id), isTrue);
    read.complete(old);
    await loading;
    expect(app.agent.conversations, isEmpty);
    expect(app.agent.openConversation(id), isFalse);
    expect(history.items, isEmpty);
  });

  test('退出等待保存队列，保存失败保留数据并返回失败，删除失败可重试', () async {
    final history = _ControlledHistory();
    final saving = Completer<void>();
    history.pendingSave = saving.future;
    final app = await setup(
      FakeAiConnect((_) => openAiReply('Saved')),
      history: history,
    );
    await app.agent.send('Wait for persistence');
    var finished = false;
    final exit = app.agent.prepareForExit().then((result) {
      finished = true;
      return result;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    saving.complete();
    expect(await exit, isTrue);
    final id = app.agent.currentConversationId.value!;
    history.failDelete = true;
    expect(await app.agent.deleteConversation(id), isFalse);
    expect(app.agent.conversations, hasLength(1));
    expect(await app.agent.prepareForExit(), isFalse);
    history.failDelete = false;
    await app.agent.retryHistory();
    expect(app.agent.conversations, isEmpty);
    expect(app.agent.historyError.value, isNull);
    expect(await app.agent.prepareForExit(), isTrue);
    history.failSave = true;
    await app.agent.send('Unsaved request');
    expect(await app.agent.prepareForExit(), isFalse);
    expect(app.agent.entries.first.text, 'Unsaved request');
    history.failSave = false;
    expect(await app.agent.prepareForExit(), isTrue);
    expect(history.items.values.single.messages.first.text, 'Unsaved request');
  });

  test('保存失败重试与删除并发时，不把删除中的旧快照重新排入保存', () async {
    final history = _ControlledHistory()..failSave = true;
    final app = await setup(
      FakeAiConnect((_) => openAiReply('Saved')),
      history: history,
    );
    await app.agent.send('Delete unsaved request');
    await app.agent.historySaved;
    final id = app.agent.currentConversationId.value!;
    final gate = Completer<void>();
    history.pendingDelete = gate.future;
    history.failSave = false;
    final deleting = app.agent.deleteConversation(id);
    final retrying = app.agent.retryHistory();
    gate.complete();
    expect(await deleting, isTrue);
    await retrying;
    await app.agent.historySaved;
    expect(history.items, isEmpty);
    expect(app.agent.conversations, isEmpty);
  });

  test('思考与审核偏好在新建、恢复、重建控制器后沿用，未恢复会话句柄', () async {
    final preferences = InMemoryAiSettingsRepository();
    final app = await setup(
      FakeAiConnect((_) => openAiReply('Saved')),
      preferences: preferences,
    );
    app.agent.onInit();
    app.agent.selectReasoningEffort(AiReasoningEffort.high);
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    await Future.wait([
      app.agent.modesSaved,
      app.settings.setPanel(width: 450),
    ]);
    expect(preferences.value.reasoningEffort, AiReasoningEffort.high);
    expect(preferences.value.accessMode, AgentAccessMode.fullAccess);
    expect(preferences.value.panelWidth, 450);
    await app.agent.send('Remember my modes');
    final id = app.agent.currentConversationId.value!;
    app.agent.clear();
    expect(app.agent.reasoningEffort.value, AiReasoningEffort.high);
    expect(app.agent.accessMode.value, AgentAccessMode.fullAccess);
    expect(app.agent.openConversation(id), isTrue);
    expect(app.agent.selectedSessions, isEmpty);
    await app.agent.historySaved;
    final restoredSettings = AiSettingsController(
      repository: preferences,
      secretStore: InMemorySecretStore(),
    );
    await restoredSettings.ready;
    final restoredConnect = FakeAiConnect((_) => openAiReply('Unused'));
    final restoredSessions = SessionController(engine: _Engine());
    final restored = AgentController(
      connect: restoredConnect,
      settings: restoredSettings,
      secretStore: InMemorySecretStore(),
      sessions: restoredSessions,
      conversations: app.history,
    );
    restored.onInit();
    await restored.loadConversations();
    await Future<void>.delayed(Duration.zero);
    expect(restored.reasoningEffort.value, AiReasoningEffort.high);
    expect(restored.accessMode.value, AgentAccessMode.fullAccess);
    expect(restored.openConversation(id), isTrue);
    expect(restored.selectedSessions, isEmpty);
    restored.clear();
    expect(restored.accessMode.value, AgentAccessMode.fullAccess);
    restored.onClose();
    restoredSettings.onClose();
    restoredSessions.onClose();
    restoredConnect.dispose();
  });

  test('模式保存失败保留本次明确选择，重试和退出前完成持久化', () async {
    final preferences = InMemoryAiSettingsRepository();
    final app = await setup(
      FakeAiConnect((_) => openAiReply('OK')),
      preferences: preferences,
    );
    app.agent.onInit();
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    await app.agent.modesSaved;
    preferences.failSave = true;
    app.agent.selectAccessMode(AgentAccessMode.requestApproval);
    await app.agent.modesSaved;
    expect(app.agent.modesError.value, isNotNull);
    app.agent.clear();
    expect(app.agent.accessMode.value, AgentAccessMode.requestApproval);
    expect(preferences.value.accessMode, AgentAccessMode.fullAccess);
    expect(await app.agent.prepareForExit(), isFalse);
    preferences.failSave = false;
    expect(await app.agent.prepareForExit(), isTrue);
    expect(app.agent.modesError.value, isNull);
    expect(preferences.value.accessMode, AgentAccessMode.requestApproval);
  });
}
