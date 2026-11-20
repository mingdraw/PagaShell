import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/ai/ai_model.dart';
import 'agent_api_codec.dart';

const _invalid = AgentApiException('AI 响应格式无效，请检查接口协议与模型');
const _interrupted = AgentApiException('AI 回复流意外中断，请重试');
typedef _SseEvent = ({String name, String data});

class AgentStreamReader {
  StreamIterator<_SseEvent>? _iterator;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    unawaited(_iterator?.cancel().catchError((Object _) {}));
  }

  Future<AgentReply> read(
    AiApiFormat format,
    Stream<List<int>> bytes, {
    required String responsesScope,
    required String? anthropicScope,
    required void Function(String text, bool reasoning) onDelta,
  }) async {
    final iterator = StreamIterator(_events(bytes));
    _iterator = iterator;
    final decoder = _Decoder(format, onDelta);
    try {
      if (cancelled) {
        // Start and cancel the subscription even if cancellation preceded headers.
        unawaited(
          iterator.moveNext().then<void>((_) {}, onError: (Object _) {}),
        );
        throw _interrupted;
      }
      while (!decoder.done && await iterator.moveNext()) {
        final event = iterator.current;
        decoder.add(event.name, event.data);
      }
      if (cancelled || !decoder.done) throw _interrupted;
      final reply = AgentApiCodec.parse(
        format,
        decoder.result(),
        responsesScope: responsesScope,
        anthropicScope: anthropicScope,
      );
      return AgentReply(
        reply.turn,
        truncated: reply.truncated || decoder.incomplete,
        reasoning: reply.reasoning.isNotEmpty
            ? reply.reasoning
            : decoder.thought.toString(),
      );
    } on FormatException {
      throw _invalid;
    } on TypeError {
      throw _invalid;
    } on IOException {
      throw _interrupted;
    } finally {
      await iterator.cancel();
      _iterator = null;
    }
  }
}

Stream<_SseEvent> _events(Stream<List<int>> bytes) {
  var received = 0;
  var name = '';
  final data = <String>[];
  void flush(EventSink<_SseEvent> sink) {
    if (data.isNotEmpty) sink.add((name: name, data: data.join('\n')));
    data.clear();
    name = '';
  }

  // Transform the HTTP subscription directly so stopping an idle response
  // propagates cancellation without waiting for another event to arrive.
  return bytes
      .timeout(const Duration(seconds: 120))
      .map((chunk) {
        received += chunk.length;
        if (received > 12 * 1024 * 1024) throw _invalid;
        return chunk;
      })
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(
        StreamTransformer<String, _SseEvent>.fromHandlers(
          handleData: (line, sink) {
            if (line.isEmpty) {
              flush(sink);
            } else if (line.startsWith('data:')) {
              data.add(_field(line, 5));
            } else if (line.startsWith('event:')) {
              name = _field(line, 6);
            }
          },
          handleDone: (sink) {
            flush(sink);
            sink.close();
          },
        ),
      );
}

String _field(String line, int start) =>
    line.substring(line.startsWith(' ', start) ? start + 1 : start);

class _ToolFragment {
  String? id;
  String name = '';
  final arguments = StringBuffer();
}

class _Decoder {
  _Decoder(this.format, this.onDelta);

  final AiApiFormat format;
  final void Function(String text, bool reasoning) onDelta;
  final text = StringBuffer();
  final thought = StringBuffer();
  final _chatTools = <int, _ToolFragment>{};
  final _blocks = <int, Map<String, dynamic>>{};
  final _toolJson = <int, StringBuffer>{};
  final _openBlocks = <int>{};
  String? _finishReason;
  Map<String, dynamic>? _response;
  bool done = false;
  bool incomplete = false;

  void _emit(Object? value, {bool reasoning = false}) {
    if (value is! String || value.isEmpty) return;
    (reasoning ? thought : text).write(value);
    onDelta(value, reasoning);
  }

  void add(String name, String data) {
    if (data.isEmpty) return;
    if (data == '[DONE]') {
      if (format != AiApiFormat.openai || _finishReason == null) {
        throw _interrupted;
      }
      done = true;
      return;
    }
    final message = jsonDecode(data) as Map<String, dynamic>;
    final type = message['type'] ?? name;
    if (type == 'error' ||
        type == 'response.failed' ||
        message['error'] != null) {
      throw _interrupted;
    }
    switch (format) {
      case AiApiFormat.openai:
        _chat(message);
      case AiApiFormat.openaiResponses:
        switch (type) {
          case 'response.output_text.delta' || 'response.refusal.delta':
            _emit(message['delta']);
          case 'response.reasoning_summary_text.delta':
            _emit(message['delta'], reasoning: true);
          case 'response.completed' || 'response.incomplete':
            _response = message['response'] as Map<String, dynamic>;
            incomplete = type == 'response.incomplete';
            done = true;
        }
      case AiApiFormat.anthropic:
        _anthropic(type, message);
    }
  }

  void _chat(Map<String, dynamic> message) {
    final choices = message['choices'];
    if (choices is! List || choices.isEmpty) return;
    final choice = choices
        .cast<Map<String, dynamic>>()
        .where((choice) => (choice['index'] ?? 0) == 0)
        .firstOrNull;
    if (choice == null) return;
    final delta = choice['delta'] as Map<String, dynamic>?;
    if (delta != null) {
      _emit(delta['content']);
      _emit(delta['refusal']);
      _emit(delta['reasoning_content'] ?? delta['reasoning'], reasoning: true);
      if (delta['tool_calls'] case final List<dynamic> fragments) {
        for (final raw in fragments) {
          final fragment = raw as Map<String, dynamic>;
          final index = fragment['index'] as int;
          if (index < 0 || index >= 8) throw _invalid;
          final tool = _chatTools.putIfAbsent(index, _ToolFragment.new);
          if (fragment['id'] case final String id when id.isNotEmpty) {
            if (tool.id != null && tool.id != id) throw _invalid;
            tool.id = id;
          }
          if (fragment['function'] case final Map<String, dynamic> function) {
            if (function['name'] case final String name
                when name != tool.name) {
              tool.name += name;
            }
            if (function['arguments'] case final String arguments) {
              tool.arguments.write(arguments);
            }
          }
        }
      }
    }
    if (choice['finish_reason'] case final String reason
        when reason.isNotEmpty) {
      _finishReason = reason;
      incomplete = reason == 'length' || reason == 'content_filter';
      done = true;
    }
  }

  void _anthropic(Object? type, Map<String, dynamic> message) {
    if (type == 'message_delta') {
      final delta = message['delta'] as Map<String, dynamic>;
      _finishReason = delta['stop_reason'] as String?;
      incomplete = _finishReason == 'max_tokens' || _finishReason == 'refusal';
      return;
    }
    if (type == 'message_stop') {
      if (_openBlocks.isNotEmpty || _finishReason == null) throw _interrupted;
      done = true;
      return;
    }
    if (type != 'content_block_start' &&
        type != 'content_block_delta' &&
        type != 'content_block_stop') {
      return;
    }
    final index = message['index'] as int;
    if (index < 0 || index >= 512) throw _invalid;
    if (type == 'content_block_start') {
      if (_blocks.containsKey(index)) throw _invalid;
      final block = Map<String, dynamic>.of(
        message['content_block'] as Map<String, dynamic>,
      );
      _blocks[index] = block;
      _openBlocks.add(index);
      if (block['type'] == 'text') _emit(block['text']);
      if (block['type'] == 'thinking') {
        _emit(block['thinking'], reasoning: true);
      }
      return;
    }
    if (!_openBlocks.contains(index)) throw _invalid;
    final block = _blocks[index]!;
    if (type == 'content_block_stop') {
      _openBlocks.remove(index);
      final json = _toolJson.remove(index);
      if (json?.isNotEmpty == true) {
        block['input'] = jsonDecode(json.toString()) as Map<String, dynamic>;
      }
      return;
    }
    final delta = message['delta'] as Map<String, dynamic>;
    switch ((block['type'], delta['type'])) {
      case ('text', 'text_delta'):
        final part = delta['text'] as String;
        block['text'] = (block['text'] as String? ?? '') + part;
        _emit(part);
      case ('thinking', 'thinking_delta'):
        final part = delta['thinking'] as String;
        block['thinking'] = (block['thinking'] as String? ?? '') + part;
        _emit(part, reasoning: true);
      case ('thinking', 'signature_delta'):
        final part = delta['signature'] as String;
        block['signature'] = (block['signature'] as String? ?? '') + part;
      case ('tool_use', 'input_json_delta'):
        _toolJson
            .putIfAbsent(index, StringBuffer.new)
            .write(delta['partial_json'] as String);
    }
  }

  Map<String, dynamic> result() => switch (format) {
    AiApiFormat.openaiResponses => _response ?? (throw _invalid),
    AiApiFormat.anthropic => {
      'stop_reason': _finishReason,
      'content': [
        for (final index in (_blocks.keys.toList()..sort())) _blocks[index]!,
      ],
    },
    AiApiFormat.openai => {
      'choices': [
        {
          'finish_reason': _finishReason,
          'message': {
            'content': text.toString(),
            'reasoning_content': thought.toString(),
            'tool_calls': [
              for (final index in (_chatTools.keys.toList()..sort()))
                {
                  'id': _chatTools[index]!.id,
                  'function': {
                    'name': _chatTools[index]!.name,
                    'arguments': _chatTools[index]!.arguments.toString(),
                  },
                },
            ],
          },
        },
      ],
    },
  };
}
