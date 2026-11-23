part of 'agent_controller.dart';

final _privateKeyBlockPattern = RegExp(
  r'-----BEGIN [^\r\n]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [^\r\n]*PRIVATE KEY(?: BLOCK)?-----|$)',
  caseSensitive: false,
);
final _sensitiveAssignmentPattern = RegExp(
  r'''((?<![\w.-])[\w.-]*(?:password|passwd|requirepass|masterauth|api[-_]?key|(?:access|refresh)[-_]?token|client[-_]?secret|secret[-_]?key|authorization)\b["']?(?:\s*[=:]\s*|\t+| +))([^\s\r\n].*)''',
  caseSensitive: false,
  multiLine: true,
);
final _sudoPromptPhrasePattern = RegExp(
  r'^(?:is required|is needed|required|prompt)\b',
  caseSensitive: false,
);
final _urlPasswordPattern = RegExp(
  r'((?<![\w+.-])[\w+.-]+://[^:/\s@]+:)[^/\s@]+(@)',
);
final _ansiEscapePattern = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
final _controlCharPattern = RegExp(r'[\x00-\x08\x0b-\x1f\x7f]');
final _sudoNonInteractivePattern = RegExp(r'\bsudo\s+-n\b');
final _sudoErrorPattern = RegExp(
  r'sudo:[^\r\n]*(?:password is required|a terminal is required|需要密码|需要终端)',
  caseSensitive: false,
);

String _scrubAgentOutput(String text) => text
    .replaceAll(_privateKeyBlockPattern, '[private key removed]')
    .replaceAllMapped(_sensitiveAssignmentPattern, (match) {
      final value = match[2]!;
      // Keep human-readable sudo diagnostics, never credential assignments.
      if (_sudoPromptPhrasePattern.hasMatch(value)) {
        return match[0]!;
      }
      return '${match[1]}[redacted]';
    })
    .replaceAllMapped(
      _urlPasswordPattern,
      (match) => '${match[1]}[redacted]${match[2]}',
    );

/// Zero-copy check matching [_scrubAgentOutput] without allocating copies of
/// large configuration files.
bool _containsSensitiveOutput(String text) {
  if (_privateKeyBlockPattern.hasMatch(text)) return true;
  if (_urlPasswordPattern.hasMatch(text)) return true;
  for (final match in _sensitiveAssignmentPattern.allMatches(text)) {
    final value = match[2]!;
    if (!_sudoPromptPhrasePattern.hasMatch(value)) return true;
  }
  return false;
}

/// Counts UTF-8 bytes without allocating a temporary Uint8List.
bool _exceedsUtf8Limit(String text, int maxBytes) {
  if (text.length > maxBytes) return true;
  if (text.length * 3 <= maxBytes) return false;
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final cu = text.codeUnitAt(i);
    if (cu <= 0x7f) {
      bytes += 1;
    } else if (cu <= 0x7ff) {
      bytes += 2;
    } else if ((cu & 0xfc00) == 0xd800 &&
        i + 1 < text.length &&
        (text.codeUnitAt(i + 1) & 0xfc00) == 0xdc00) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (bytes > maxBytes) return true;
  }
  return false;
}

String _outputText(String value) => _scrubAgentOutput(
  value
      .replaceAll(_ansiEscapePattern, '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_controlCharPattern, ''),
);

/// Keeps only the most recent [_limit] characters so periodic live-output UI
/// previews run in O(1) instead of scrubbing a growing multi-megabyte buffer.
class _TailWindow {
  static const _limit = 8192;
  String _older = '';
  final _recent = StringBuffer();

  void write(String chunk) {
    if (chunk.isEmpty) return;
    if (chunk.length >= _limit) {
      _older = '';
      _recent.clear();
      _recent.write(_tail(chunk, _limit));
      return;
    }
    _recent.write(chunk);
    if (_recent.length >= _limit) {
      _older = _tail(_recent.toString(), _limit);
      _recent.clear();
    }
  }

  String snapshot() {
    if (_older.isEmpty) return _recent.toString();
    if (_recent.isEmpty) return _older;
    return _tail('$_older$_recent', _limit);
  }
}

String _prefix(String text, int length) {
  if (text.length <= length) return text;
  if (length > 0 && text.codeUnitAt(length - 1) & 0xfc00 == 0xd800) length--;
  return text.substring(0, length);
}

String _tail(String text, int length) {
  if (text.length <= length) return text;
  var start = text.length - length;
  if (start < text.length && text.codeUnitAt(start) & 0xfc00 == 0xdc00) start++;
  return text.substring(start);
}

String _truncateToolOutput(String text, {int maxChars = 24000}) {
  if (text.length <= maxChars) return text;
  final head = _prefix(text, maxChars * 4 ~/ 10);
  final tail = _tail(text, maxChars ~/ 2);
  final omitted = '\n'
      .allMatches(text, head.length)
      .takeWhile((match) => match.start < text.length - tail.length)
      .length;
  return '$head\n… [$omitted lines omitted] …\n$tail';
}

String _limitToolResult(String result) {
  if (result.length <= 24000) return result;
  // Keep the tool envelope parseable even if a remote result has many escapes.
  for (var chars = 19000; chars >= 2000; chars ~/= 2) {
    final shortened = jsonEncode({
      'truncated': true,
      'preview': _truncateToolOutput(result, maxChars: chars),
    });
    if (shortened.length <= 24000) return shortened;
  }
  return 'Tool output exceeded the context limit.';
}

int _boundedInt(Object? value, int fallback, int min, int max) =>
    value is int ? value.clamp(min, max) : fallback;

class _ExecResult {
  const _ExecResult({
    required this.stdout,
    required this.stderr,
    required this.terminal,
    required this.durationMs,
    required this.sudoPasswordRequired,
  });
  final String stdout, stderr;
  final SshExecEvent terminal;
  final int durationMs;
  final bool sudoPasswordRequired;

  bool get success =>
      terminal.exitCode == 0 && !terminal.timedOut && !terminal.cancelled;

  Map<String, Object?> toJson() => {
    'exitCode': terminal.exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'durationMs': durationMs,
    'timedOut': terminal.timedOut,
    'cancelled': terminal.cancelled,
    'truncated': terminal.truncated,
    'sudoPasswordRequired': sudoPasswordRequired,
    'completionKnown':
        terminal.exitCode != null && !terminal.timedOut && !terminal.cancelled,
  };
}

extension _AgentExecOperations on AgentController {
  Future<String> _runExecProposal(AgentCommandProposal proposal) async {
    final target = _boundSession(proposal.target);
    final source = target?.engineSession;
    if (!_live(proposal.generation) ||
        source is! SshExecSource ||
        target == null) {
      proposal.state.value = AgentCommandState.unavailable;
      return _missingSshTarget;
    }
    activity.value = '正在执行后台命令';
    if (!_live(proposal.generation) || _boundSession(target) == null) {
      proposal.state.value = AgentCommandState.unavailable;
      return _missingSshTarget;
    }
    final result = await _collectExec(
      source as SshExecSource,
      proposal.effectiveCommand,
      proposal.timeoutSecs,
      proposal: proposal,
    );
    if (entries.any((entry) => identical(entry.command, proposal))) {
      _saveConversation(deferred: true);
    }
    return jsonEncode({
      'session_id': target.id,
      ...result.toJson(),
      if (result.sudoPasswordRequired) 'note': 'Noninteractive sudo needs user intervention. The card can put the command in the terminal for manual review and entry.',
      if (result.terminal.timedOut || result.terminal.cancelled) 'note': 'The channel was interrupted. A remote service or child process may still have changed state; verify before retrying.',
    });
  }

  Future<_ExecResult> _collectExec(
    SshExecSource source,
    String command,
    int timeoutSecs, {
    AgentCommandProposal? proposal,
  }) async {
    final elapsed = Stopwatch()..start();
    final output = [StringBuffer(), StringBuffer()];
    final tailWindows = proposal == null
        ? null
        : [_TailWindow(), _TailWindow()];
    var terminal = const SshExecEvent(
      SshExecEventKind.exit,
      data: 'SSH 后台命令未完成，请检查连接',
    );
    SshExecHandle? handle;
    StreamSubscription<SshExecEvent>? subscription;
    Timer? refresh;
    var stopped = false;
    var received = 0;
    var clipped = false;
    void cancel() {
      stopped = true;
      if (proposal != null) {
        proposal.cancelled.value = true;
        unawaited(proposal.cancelRunningExec());
      } else if (handle != null) {
        unawaited(handle.cancel().catchError((Object _) {}));
      }
    }

    try {
      handle = source.startExec(command, timeoutSecs: timeoutSecs);
      _tools.cancelExec = cancel;
      if (proposal != null) {
        proposal._exec = handle;
        proposal.running.value = true;
        var shown = 0;
        refresh = Timer.periodic(const Duration(milliseconds: 150), (_) {
          proposal.durationMs.value = elapsed.elapsedMilliseconds;
          if (shown == received) return;
          shown = received;
          String preview(int index) {
            final text = _outputText(tailWindows![index].snapshot());
            final lastBreak = text.lastIndexOf('\n');
            return lastBreak < 0
                ? ''
                : _tail(text.substring(0, lastBreak), 3500);
          }

          proposal.liveOutput.value = [
            preview(0),
            preview(1),
          ].where((text) => text.isNotEmpty).join('\n');
        });
      }
      final completion = Completer<SshExecEvent?>();
      void finish(SshExecEvent? result) {
        if (!completion.isCompleted) completion.complete(result);
      }

      subscription = handle.events.listen(
        (event) {
          if (completion.isCompleted) return;
          if (event.kind == SshExecEventKind.exit) {
            finish(event);
            return;
          }
          final budget = 2 * 1024 * 1024 - received;
          final chunk = _prefix(event.data, budget);
          clipped |= chunk.length < event.data.length;
          final streamIndex = event.kind == SshExecEventKind.stdout ? 0 : 1;
          output[streamIndex].write(chunk);
          tailWindows?[streamIndex].write(chunk);
          received += chunk.length;
        },
        onError: (Object _, StackTrace _) => finish(null),
        onDone: () => finish(null),
      );
      terminal = await completion.future ?? terminal;
    } on Object {
      // Bridge/transport errors can contain remote bytes; keep a fixed message.
    } finally {
      refresh?.cancel();
      final closing = subscription?.cancel();
      if (closing != null) unawaited(closing.catchError((Object _) {}));
      if (identical(_tools.cancelExec, cancel)) _tools.cancelExec = null;
      if (proposal != null) proposal._exec = null;
    }
    final err = output[1].toString();
    final needsSudo =
        _sudoNonInteractivePattern.hasMatch(command) &&
        (terminal.exitCode == 77 ||
            (terminal.exitCode != null &&
                terminal.exitCode != 0 &&
                _sudoErrorPattern.hasMatch(err)));
    final stdout = _outputText(output[0].toString());
    final stderr = _outputText(err);
    if (stopped || clipped || stdout.length > 12000 || stderr.length > 12000) {
      terminal = SshExecEvent(
        terminal.kind,
        data: terminal.data,
        exitCode: terminal.exitCode,
        timedOut: terminal.timedOut,
        cancelled: terminal.cancelled || (stopped && terminal.exitCode == null),
        truncated:
            terminal.truncated ||
            clipped ||
            stdout.length > 12000 ||
            stderr.length > 12000,
      );
    }
    final result = _ExecResult(
      stdout: _truncateToolOutput(stdout, maxChars: 12000),
      stderr: _truncateToolOutput(stderr, maxChars: 12000),
      terminal: terminal,
      durationMs: elapsed.elapsedMilliseconds,
      sudoPasswordRequired: needsSudo,
    );
    if (proposal != null) {
      proposal.stdout.value = result.stdout;
      proposal.stderr.value = result.stderr;
      proposal.exitCode.value = terminal.exitCode;
      proposal.durationMs.value = result.durationMs;
      proposal.timedOut.value = terminal.timedOut;
      proposal.cancelled.value = terminal.cancelled;
      proposal.truncated.value = terminal.truncated;
      proposal.sudoPasswordRequired.value = needsSudo;
      if (!terminal.cancelled &&
          terminal.exitCode == null &&
          terminal.data.isNotEmpty) {
        proposal.error.value = terminal.data;
      }
      proposal.running.value = false;
      proposal._invalidateArchive();
    }
    return result;
  }
}
