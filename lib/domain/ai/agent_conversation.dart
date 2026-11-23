import 'command_classifier.dart';

enum AgentEntryKind {
  user,
  assistant,
  tool,
  command,
  reasoning,
  fileChange;

  bool get isActivity => this == reasoning || this == tool;
}

enum AgentCommandState { pending, sent, rejected, unavailable }

enum AgentCommandExecutionMode { exec, terminal }

enum AgentFileChangeState {
  pending,
  applied,
  rejected,
  rolledBack,
  failed,
  unavailable,
}

enum AgentRequestState { queued, running, completed, failed, cancelled }

final _conversationId = RegExp(r'^[a-f0-9]{32}$');

/// 历史命令仅保存展示信息，不包含会话句柄或执行授权。
class AgentArchivedCommand {
  const AgentArchivedCommand({
    required this.command,
    required this.purpose,
    required this.target,
    required this.state,
    this.executionMode = AgentCommandExecutionMode.terminal,
    this.risk,
    this.exitCode,
    this.durationMs,
    this.outputPreview,
    this.timedOut = false,
    this.cancelled = false,
  });

  final String command;
  final String purpose;
  final String target;
  final AgentCommandState state;
  final AgentCommandExecutionMode executionMode;
  final AgentCommandRisk? risk;
  final int? exitCode, durationMs;
  final String? outputPreview;
  final bool timedOut, cancelled;

  Map<String, dynamic> toJson() => {
    'command': command,
    'purpose': purpose,
    'target': target,
    'state': state.name,
    if (executionMode == AgentCommandExecutionMode.exec)
      'executionMode': executionMode.name,
    if (risk != null) 'risk': risk!.name,
    if (exitCode != null) 'exitCode': exitCode,
    if (durationMs != null) 'durationMs': durationMs,
    if (outputPreview != null) 'outputPreview': outputPreview,
    if (timedOut) 'timedOut': true,
    if (cancelled) 'cancelled': true,
  };

  factory AgentArchivedCommand.fromJson(Map<String, dynamic> json) =>
      AgentArchivedCommand(
        command: json['command'] as String,
        purpose: json['purpose'] as String,
        target: json['target'] as String,
        executionMode: json['executionMode'] == 'exec'
            ? AgentCommandExecutionMode.exec
            : AgentCommandExecutionMode.terminal,
        risk: AgentCommandRisk.values
            .where((risk) => risk.name == json['risk'])
            .firstOrNull,
        exitCode: json['exitCode'] as int?,
        durationMs: json['durationMs'] as int?,
        outputPreview: json['outputPreview'] as String?,
        timedOut: json['timedOut'] == true,
        cancelled: json['cancelled'] == true,
        state: switch (json['state']) {
          'sent' => AgentCommandState.sent,
          'rejected' => AgentCommandState.rejected,
          _ => AgentCommandState.unavailable,
        },
      );
}

/// Display data only. No file contents, connection or rollback authority.
class AgentArchivedFileChange {
  const AgentArchivedFileChange({
    required this.path,
    required this.purpose,
    required this.target,
    required this.diffText,
    required this.addedLines,
    required this.removedLines,
    required this.state,
    this.backupPath,
    this.createdNew = false,
    this.usedSudo = false,
    this.validationOutput,
    this.validationPassed,
    this.error,
  });

  final String path, purpose, target, diffText;
  final int addedLines, removedLines;
  final AgentFileChangeState state;
  final String? backupPath, validationOutput, error;
  final bool createdNew, usedSudo;
  final bool? validationPassed;

  Map<String, dynamic> toJson() => {
    'path': path,
    'purpose': purpose,
    'target': target,
    'diffText': diffText,
    'addedLines': addedLines,
    'removedLines': removedLines,
    'state': state.name,
    'backupPath': backupPath,
    'createdNew': createdNew,
    'usedSudo': usedSudo,
    'validationOutput': validationOutput,
    'validationPassed': validationPassed,
    'error': error,
  };

  factory AgentArchivedFileChange.fromJson(Map<String, dynamic> json) =>
      AgentArchivedFileChange(
        path: json['path'] as String,
        purpose: json['purpose'] as String,
        target: json['target'] as String,
        diffText: json['diffText'] as String,
        addedLines: json['addedLines'] as int,
        removedLines: json['removedLines'] as int,
        state: switch (json['state']) {
          'applied' => AgentFileChangeState.applied,
          'rejected' => AgentFileChangeState.rejected,
          'rolledBack' => AgentFileChangeState.rolledBack,
          'failed' => AgentFileChangeState.failed,
          _ => AgentFileChangeState.unavailable,
        },
        backupPath: json['backupPath'] as String?,
        createdNew: json['createdNew'] == true,
        usedSudo: json['usedSudo'] == true,
        validationOutput: json['validationOutput'] as String?,
        validationPassed: json['validationPassed'] as bool?,
        error: json['error'] as String?,
      );
}

class AgentToolSummary {
  const AgentToolSummary(
    this.target, {
    this.elapsedMs,
    this.outputLength,
    this.cancelled = false,
  });

  final String? target;
  final int? elapsedMs;
  final int? outputLength;
  final bool cancelled;

  Map<String, dynamic> toJson() => {
    'target': target,
    'elapsedMs': elapsedMs,
    'outputLength': outputLength,
    if (cancelled) 'cancelled': true,
  };

  factory AgentToolSummary.fromJson(Map<String, dynamic> json) =>
      AgentToolSummary(
        json['target'] as String?,
        elapsedMs: json['elapsedMs'] as int?,
        outputLength: json['outputLength'] as int?,
        // Older snapshots could save a running tool before Stop finalized it.
        cancelled: json['cancelled'] == true || json['elapsedMs'] == null,
      );
}

class AgentMessage {
  const AgentMessage(
    this.kind,
    this.text, {
    this.command,
    this.fileChange,
    this.requestState,
    this.requestError,
    this.toolSummary,
    this.hadSessionReferences = false,
  });

  final AgentEntryKind kind;
  final String text;
  final AgentArchivedCommand? command;
  final AgentArchivedFileChange? fileChange;
  final AgentRequestState? requestState;
  final String? requestError;
  final AgentToolSummary? toolSummary;
  final bool hadSessionReferences;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    if (command != null) 'command': command!.toJson(),
    if (fileChange != null) 'fileChange': fileChange!.toJson(),
    if (requestState != null) 'requestState': requestState!.name,
    if (requestError != null) 'requestError': requestError,
    if (toolSummary != null) 'toolSummary': toolSummary!.toJson(),
    if (hadSessionReferences) 'hadSessionReferences': true,
  };

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
    AgentEntryKind.values.byName(json['kind'] as String),
    json['text'] as String,
    command: json['command'] == null
        ? null
        : AgentArchivedCommand.fromJson(
            json['command'] as Map<String, dynamic>,
          ),
    fileChange: json['fileChange'] == null
        ? null
        : AgentArchivedFileChange.fromJson(
            json['fileChange'] as Map<String, dynamic>,
          ),
    // 队列和连接授权只在运行内存中存在，恢复历史不能自动重发消息。
    requestState: switch (json['requestState']) {
      'completed' => AgentRequestState.completed,
      'failed' => AgentRequestState.failed,
      'queued' || 'running' || 'cancelled' => AgentRequestState.cancelled,
      _ => null,
    },
    requestError: json['requestError'] as String?,
    hadSessionReferences: json['hadSessionReferences'] == true,
    toolSummary: json['toolSummary'] == null
        ? null
        : AgentToolSummary.fromJson(
            json['toolSummary'] as Map<String, dynamic>,
          ),
  );
}

/// List and search data; it deliberately holds neither messages nor API context.
class AgentConversationSummary {
  const AgentConversationSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    required this.messageCount,
  });

  final String id, title, model;
  final DateTime createdAt, updatedAt;
  final int messageCount;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'model': model,
    'messageCount': messageCount,
  };

  factory AgentConversationSummary.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final count = json['messageCount'] as int;
    if (json['version'] != 1 || !_conversationId.hasMatch(id) || count < 0) {
      throw const FormatException();
    }
    return AgentConversationSummary(
      id: id,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      model: json['model'] as String,
      messageCount: count,
    );
  }
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

  AgentConversationSummary get summary => AgentConversationSummary(
    id: id,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    model: model,
    messageCount: messages.length,
  );

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
    if (!_conversationId.hasMatch(id)) {
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
