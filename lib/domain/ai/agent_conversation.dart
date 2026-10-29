enum AgentEntryKind { user, assistant, tool, command }

enum AgentCommandState { pending, sent, rejected, unavailable }

/// 历史命令仅保存展示信息，不包含会话句柄或执行授权。
class AgentArchivedCommand {
  const AgentArchivedCommand({
    required this.command,
    required this.purpose,
    required this.target,
    required this.state,
  });

  final String command;
  final String purpose;
  final String target;
  final AgentCommandState state;

  Map<String, dynamic> toJson() => {
    'command': command,
    'purpose': purpose,
    'target': target,
    'state': state.name,
  };

  factory AgentArchivedCommand.fromJson(Map<String, dynamic> json) =>
      AgentArchivedCommand(
        command: json['command'] as String,
        purpose: json['purpose'] as String,
        target: json['target'] as String,
        state: switch (json['state']) {
          'sent' => AgentCommandState.sent,
          'rejected' => AgentCommandState.rejected,
          _ => AgentCommandState.unavailable,
        },
      );
}

class AgentMessage {
  const AgentMessage(this.kind, this.text, {this.command});

  final AgentEntryKind kind;
  final String text;
  final AgentArchivedCommand? command;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    if (command != null) 'command': command!.toJson(),
  };

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
    AgentEntryKind.values.byName(json['kind'] as String),
    json['text'] as String,
    command: json['command'] == null
        ? null
        : AgentArchivedCommand.fromJson(
            json['command'] as Map<String, dynamic>,
          ),
  );
}

class AgentConversation {
  const AgentConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    required this.messages,
    required this.turns,
    this.historyTrimmed = false,
    this.historyRevision = 0,
    this.error,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String model;
  final List<AgentMessage> messages;
  // 协议上下文作为纯 JSON 保存，领域层不依赖 API 编解码器。
  final List<Map<String, dynamic>> turns;
  final bool historyTrimmed;
  final int historyRevision;
  final String? error;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'model': model,
    'messages': messages.map((message) => message.toJson()).toList(),
    'turns': turns,
    'historyTrimmed': historyTrimmed,
    'historyRevision': historyRevision,
    'error': error,
  };

  factory AgentConversation.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException();
    final id = json['id'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException();
    }
    return AgentConversation(
      id: id,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      model: json['model'] as String,
      messages: List.unmodifiable(
        (json['messages'] as List<dynamic>).map(
          (dynamic item) => AgentMessage.fromJson(item as Map<String, dynamic>),
        ),
      ),
      turns: List.unmodifiable(
        (json['turns'] as List<dynamic>).cast<Map<String, dynamic>>(),
      ),
      historyTrimmed: json['historyTrimmed'] == true,
      historyRevision: json['historyRevision'] as int? ?? 0,
      error: json['error'] as String?,
    );
  }
}
