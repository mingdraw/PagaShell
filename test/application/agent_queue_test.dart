import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import '../support/fake_ai_connect.dart';
import '../support/fixture_terminal.dart';
import '../support/in_memory_agent_conversation_repository.dart';
import '../support/in_memory_ai_settings_repository.dart';

class _Engine extends Fake implements SshEngine {}

class _SshSession extends Fake implements SshEngineSession {
  @override
  Future<void> close() async {}
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Agent did not reach the expected state');
}

Session _terminal(String id, [List<String>? written]) => Session(
  id: id,
  host: Host(id: id, name: 'Host $id', hostname: '$id.internal'),
  phase: SessionPhase.ready,
  engineSession: _SshSession(),
  terminal: Terminal(onOutput: written?.add),
);

Response<dynamic> _command(String target) => openAiReply(
  '',
  calls: [
    {
      'id': 'input-$target',
      'type': 'function',
      'function': {
        'name': 'propose_ssh_command',
        'arguments': jsonEncode({
          'session_id': target,
          'command': 'pwd',
          'purpose': 'Read working directory',
        }),
      },
    },
  ],
);

class _App {
  _App(this.agent, this.settings, this.sessions, this.history);
  final AgentController agent;
  final AiSettingsController settings;
  final SessionController sessions;
  final InMemoryAgentConversationRepository history;

  static Future<_App> create(
    FakeAiConnect connect, {
    AiApiFormat format = AiApiFormat.openai,
    InMemoryAgentConversationRepository? history,
  }) async {
    final store = InMemorySecretStore();
    final settings = AiSettingsController(
      repository: InMemoryAiSettingsRepository(),
      secretStore: store,
    );
    await settings.saveApi(
      format: format,
      baseUrl: 'https://api.test/v1',
      defaultModel: 'queue-model',
      apiKey: 'queue-test-key',
    );
    final sessions = SessionController(engine: _Engine());
    final repository = history ?? InMemoryAgentConversationRepository();
    final agent = AgentController(
      connect: connect,
      settings: settings,
      secretStore: store,
      sessions: sessions,
      conversations: repository,
    )..onInit();
    addTearDown(() {
      agent.onClose();
      settings.onClose();
      sessions.onClose();
      connect.dispose();
    });
    return _App(agent, settings, sessions, repository);
  }
}

void main() {
  for (final format in AiApiFormat.values) {
    test('${format.name} 连续发送按完整轮次执行，未来消息不提前进入上下文', () async {
      final responses = List.generate(3, (_) => Completer<Response<dynamic>>());
      var requestCount = 0;
      final connect = FakeAiConnect(
        (_) => responses[requestCount++].future,
        getHandler: (_) => const Response<dynamic>(
          statusCode: 200,
          body: {'id': 'queue-model', 'max_tokens': 8192},
        ),
      );
      final app = await _App.create(connect, format: format);
      final agent = app.agent;
      final futures = [for (var i = 1; i <= 3; i++) agent.send('question-$i')];
      final users = agent.entries.toList();
      await _until(() => requestCount == 1);
      expect(agent.busy.value, isTrue);
      expect(agent.queuedCount, 2);
      expect(users.map((entry) => entry.requestState.value), [
        AgentRequestState.running,
        AgentRequestState.queued,
        AgentRequestState.queued,
      ]);
      for (var i = 0; i < 3; i++) {
        final requests = connect.requests.where((r) => r.method == 'POST');
        final payload = jsonEncode(requests.last.body);
        expect(requests, hasLength(i + 1));
        expect(payload, contains('question-${i + 1}'));
        if (i > 0) expect(payload, contains('answer-$i'));
        if (i < 2) expect(payload, isNot(contains('question-${i + 2}')));
        responses[i].complete(switch (format) {
          AiApiFormat.openai => openAiReply('answer-${i + 1}'),
          AiApiFormat.openaiResponses => responsesReply([
            responsesText('answer-${i + 1}'),
          ]),
          AiApiFormat.anthropic => anthropicReply([
            {'type': 'text', 'text': 'answer-${i + 1}'},
          ]),
        });
        await futures[i];
        if (i < 2) await _until(() => requestCount == i + 2);
      }
      expect(agent.entries.map((entry) => entry.text), [
        'question-1',
        'answer-1',
        'question-2',
        'answer-2',
        'question-3',
        'answer-3',
      ]);
      expect(
        users.every(
          (entry) => entry.requestState.value == AgentRequestState.completed,
        ),
        isTrue,
      );
      expect(agent.busy.value, isFalse);
      expect(agent.queuedCount, 0);
    });
  }

  test('排队时固定模型、模式、会话和标签，执行时读取最新会话输出', () async {
    final first = Completer<Response<dynamic>>();
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1 ? first.future : openAiReply('done-$count'),
    );
    final app = await _App.create(connect);
    final agent = app.agent;
    final alpha = _terminal('alpha');
    final beta = _terminal('beta');
    app.sessions.sessions.addAll([alpha, beta]);
    final running = agent.send('hold');
    await _until(() => count == 1);
    agent.selectReasoningEffort(AiReasoningEffort.low);
    agent.selectAccessMode(AgentAccessMode.requestApproval);
    final targets = [alpha];
    final labels = {'alpha': '@original-alpha'};
    final second = agent.send(
      'inspect-alpha',
      referencedSessions: targets,
      referenceLabels: labels,
    );
    targets[0] = beta;
    labels['alpha'] = '@changed-alpha';
    await app.settings.saveApi(
      format: AiApiFormat.openai,
      baseUrl: 'https://second.test/v1',
      defaultModel: 'second-model',
    );
    agent.selectReasoningEffort(AiReasoningEffort.high);
    agent.selectAccessMode(AgentAccessMode.fullAccess);
    final third = agent.send('inspect-beta', referencedSessions: [beta]);
    agent.setReferencedSessions([]);
    app.sessions.activeSessionId.value = 'beta';
    alpha.terminal!.writeText('alpha-new-output\r\n');
    first.complete(openAiReply('released'));
    await Future.wait([running, second, third]);
    final secondRequest = connect.requests[1];
    final secondPayload = jsonEncode(secondRequest.body);
    expect(secondRequest.url, 'https://api.test/v1/chat/completions');
    expect(secondRequest.body['model'], 'queue-model');
    expect(secondRequest.body['reasoning_effort'], 'low');
    expect(secondPayload, contains('ACCESS_MODE: requestApproval'));
    expect(secondPayload, contains('@original-alpha'));
    expect(secondPayload, isNot(contains('@changed-alpha')));
    expect(secondPayload, contains('alpha-new-output'));
    expect(secondPayload, isNot(contains('beta.internal')));
    final thirdRequest = connect.requests[2];
    expect(thirdRequest.url, 'https://second.test/v1/chat/completions');
    expect(thirdRequest.body['model'], 'second-model');
    expect(thirdRequest.body['reasoning_effort'], 'high');
    expect(jsonEncode(thirdRequest.body), contains('ACCESS_MODE: fullAccess'));
    expect(jsonEncode(thirdRequest.body), contains('beta.internal'));
  });

  test('等待命令批准仍能排队，下一条的完全访问模式不批准当前命令', () async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1 ? _command('ssh') : openAiReply('done-$count'),
    );
    final app = await _App.create(connect);
    final written = <String>[];
    final target = _terminal('ssh', written);
    app.sessions.sessions.add(target);
    final first = app.agent.send('check', referencedSessions: [target]);
    await _until(() => app.agent.waitingForApproval.value);
    final proposal = app.agent.entries
        .firstWhere((e) => e.command != null)
        .command!;
    app.agent.selectAccessMode(AgentAccessMode.fullAccess);
    final second = app.agent.send('next', referencedSessions: [target]);
    await Future<void>.delayed(Duration.zero);
    expect(count, 1);
    expect(app.agent.queuedCount, 1);
    expect(proposal.state.value, AgentCommandState.pending);
    expect(written, isEmpty);
    app.agent.rejectCommand(proposal);
    await Future.wait([first, second]);
    expect(count, 3);
    expect(written, isEmpty);
    expect(
      jsonEncode(connect.requests[1].body),
      contains('ACCESS_MODE: requestApproval'),
    );
    expect(
      jsonEncode(connect.requests[2].body),
      contains('ACCESS_MODE: fullAccess'),
    );
  });

  test('当前请求失败保留对应错误，后续排队请求继续执行', () async {
    final first = Completer<Response<dynamic>>();
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1 ? first.future : openAiReply('recovered'),
    );
    final app = await _App.create(connect);
    final running = app.agent.send('will-fail');
    final queued = app.agent.send('continue');
    first.complete(
      const Response<dynamic>(
        statusCode: 401,
        body: {'message': 'private provider error queue-test-key'},
      ),
    );
    await Future.wait([running, queued]);
    final failed = app.agent.entries.first;
    expect(failed.requestState.value, AgentRequestState.failed);
    expect(failed.requestError.value, 'AI API 认证失败，请检查 API Key');
    expect(app.agent.entries.last.text, 'recovered');
    expect(app.agent.error.value, isNull);
    expect(
      jsonEncode(connect.requests.last.body),
      isNot(contains('will-fail')),
    );
    await app.agent.historySaved;
    final restored = AgentConversation.fromJson(
      app.history.items.values.single.toJson(),
    );
    expect(restored.messages.first.requestState, AgentRequestState.failed);
    expect(restored.messages.first.requestError, failed.requestError.value);
  });

  test('排队引用会话同 ID 重连不操作新连接，随后无引用消息继续执行', () async {
    final first = Completer<Response<dynamic>>();
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1 ? first.future : openAiReply('safe'),
    );
    final app = await _App.create(connect);
    final old = _terminal('ssh');
    app.sessions.sessions.add(old);
    final running = app.agent.send('hold');
    final queued = app.agent.send('inspect-old', referencedSessions: [old]);
    final continuation = app.agent.send('explain-client');
    final written = <String>[];
    app.sessions.sessions.assignAll([_terminal('ssh', written)]);
    first.complete(openAiReply('released'));
    await Future.wait([running, queued, continuation]);
    final failed = app.agent.entries.firstWhere((e) => e.text == 'inspect-old');
    expect(failed.requestState.value, AgentRequestState.failed);
    expect(failed.requestError.value, contains('会话已关闭或重连'));
    expect(count, 2);
    expect(written, isEmpty);
    expect(
      jsonEncode(connect.requests.last.body),
      isNot(contains('ssh.internal')),
    );
  });

  for (final action in ['stop', 'clear', 'open', 'delete', 'exit']) {
    test('$action 取消运行和待执行消息，迟到响应不影响新请求', () async {
      final responses = List.generate(2, (_) => Completer<Response<dynamic>>());
      var count = 0;
      final connect = FakeAiConnect((_) => responses[count++].future);
      final history = InMemoryAgentConversationRepository();
      const savedId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      history.items[savedId] = AgentConversation(
        id: savedId,
        title: 'Saved conversation',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        model: 'queue-model',
        messages: const [AgentMessage(AgentEntryKind.user, 'archived')],
        turns: const [],
      );
      final app = await _App.create(connect, history: history);
      final first = app.agent.send('old-running');
      final second = app.agent.send('old-queued');
      final users = app.agent.entries.toList();
      await _until(() => count == 1);
      final oldId = app.agent.currentConversationId.value!;
      switch (action) {
        case 'stop':
          app.agent.stop();
        case 'clear':
          app.agent.clear();
        case 'open':
          expect(app.agent.openConversation(savedId), isTrue);
        case 'delete':
          expect(await app.agent.deleteConversation(oldId), isTrue);
        case 'exit':
          expect(await app.agent.prepareForExit(), isTrue);
      }
      await Future.wait([first, second]);
      expect(users.map((e) => e.requestState.value), [
        AgentRequestState.cancelled,
        AgentRequestState.cancelled,
      ]);
      expect(app.agent.queuedCount, 0);
      expect(app.agent.busy.value, isFalse);
      final next = app.agent.send('new-running');
      await _until(() => count == 2);
      responses[0].complete(openAiReply('late-old-answer'));
      await Future<void>.delayed(Duration.zero);
      expect(app.agent.busy.value, isTrue);
      expect(
        app.agent.entries.any((e) => e.text == 'late-old-answer'),
        isFalse,
      );
      responses[1].complete(openAiReply('new-answer'));
      await next;
      expect(count, 2);
      expect(app.agent.entries.last.text, 'new-answer');
      expect(app.agent.busy.value, isFalse);
      if (action == 'delete') {
        await app.agent.historySaved;
        expect(history.items.containsKey(oldId), isFalse);
      }
    });
  }

  test('忙碌状态同步触发停止时，不启动已取消的请求', () async {
    final connect = FakeAiConnect((_) => openAiReply('unexpected'));
    final app = await _App.create(connect);
    final worker = ever(app.agent.busy, (busy) {
      if (busy) app.agent.stop();
    });
    addTearDown(worker.dispose);
    await app.agent.send('cancel-before-request');
    await Future<void>.delayed(Duration.zero);
    expect(connect.requests, isEmpty);
    expect(
      app.agent.entries.single.requestState.value,
      AgentRequestState.cancelled,
    );
    expect(app.agent.busy.value, isFalse);
    expect(app.agent.queuedCount, 0);
  });

  test('完成状态同步新建对话时，旧请求不清掉新请求或写入旧上下文', () async {
    final first = Completer<Response<dynamic>>();
    final next = Completer<Response<dynamic>>();
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1 ? first.future : next.future,
    );
    final app = await _App.create(connect);
    final running = app.agent.send('old-running');
    final queued = app.agent.send('old-queued');
    await _until(() => count == 1);
    Future<void>? fresh;
    final worker = ever(app.agent.entries.first.requestState, (state) {
      if (state == AgentRequestState.completed) {
        app.agent.clear();
        fresh = app.agent.send('new-running');
      }
    });
    addTearDown(worker.dispose);
    first.complete(openAiReply('old-answer'));
    await Future.wait([running, queued]);
    await _until(() => count == 2);
    expect(app.agent.busy.value, isTrue);
    expect(app.agent.entries.single.text, 'new-running');
    expect(
      jsonEncode(connect.requests.last.body),
      isNot(contains('old-running')),
    );
    next.complete(openAiReply('new-answer'));
    await fresh;
    expect(app.agent.entries.last.text, 'new-answer');
    expect(app.agent.busy.value, isFalse);
  });

  test('退出后历史保留未完成消息为已取消，恢复不会自动发出请求', () async {
    final pending = Completer<Response<dynamic>>();
    final app = await _App.create(FakeAiConnect((_) => pending.future));
    final first = app.agent.send('running-text');
    final second = app.agent.send('queued-text');
    expect(await app.agent.prepareForExit(), isTrue);
    await Future.wait([first, second]);
    final saved = AgentConversation.fromJson(
      app.history.items.values.single.toJson(),
    );
    expect(saved.messages.map((m) => m.text), ['running-text', 'queued-text']);
    expect(saved.messages.map((m) => m.requestState), [
      AgentRequestState.cancelled,
      AgentRequestState.cancelled,
    ]);
    expect(saved.turns, isEmpty);
    final repository = InMemoryAgentConversationRepository()
      ..items[saved.id] = saved;
    final connect = FakeAiConnect((_) => openAiReply('unexpected'));
    final restored = await _App.create(connect, history: repository);
    await restored.agent.loadConversations();
    expect(restored.agent.openConversation(saved.id), isTrue);
    expect(restored.agent.entries.map((e) => e.requestState.value), [
      AgentRequestState.cancelled,
      AgentRequestState.cancelled,
    ]);
    expect(restored.agent.selectedSessions, isEmpty);
    expect(restored.agent.queuedCount, 0);
    expect(connect.requests, isEmpty);
    pending.complete(openAiReply('late'));
  });
}
