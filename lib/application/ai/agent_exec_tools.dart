part of 'agent_controller.dart';

String _scrubAgentOutput(String text) => scrubAgentOutput(text);

bool _containsSensitiveOutput(String text) => containsSensitiveOutput(text);

bool _exceedsUtf8Limit(String text, int maxBytes) =>
    exceedsUtf8Limit(text, maxBytes);

String _truncateToolOutput(String text, {int maxChars = 24000}) =>
    truncateToolOutput(text, maxChars: maxChars);

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
    boundedInt(value, fallback, min, max);

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

  Future<SshExecCollectedResult> _collectExec(
    SshExecSource source,
    String command,
    int timeoutSecs, {
    AgentCommandProposal? proposal,
  }) async {
    final result = await collectSshExec(
      source,
      command,
      timeoutSecs,
      onCancelReady: (cancel) => _tools.cancelExec = cancel,
      onCleanupCancel: (cancel) {
        if (identical(_tools.cancelExec, cancel)) _tools.cancelExec = null;
        if (proposal != null) proposal._exec = null;
      },
      onStarted: proposal == null
          ? null
          : (handle) {
              proposal._exec = handle;
              proposal.running.value = true;
            },
      onManualCancel: proposal == null
          ? null
          : () {
              proposal.cancelled.value = true;
              unawaited(proposal.cancelRunningExec());
            },
      onLivePreview: proposal == null
          ? null
          : (preview, durationMs) {
              proposal.durationMs.value = durationMs;
              if (preview.isNotEmpty) proposal.liveOutput.value = preview;
            },
    );
    if (proposal != null) {
      final terminal = result.terminal;
      proposal.stdout.value = result.stdout;
      proposal.stderr.value = result.stderr;
      proposal.exitCode.value = terminal.exitCode;
      proposal.durationMs.value = result.durationMs;
      proposal.timedOut.value = terminal.timedOut;
      proposal.cancelled.value = terminal.cancelled;
      proposal.truncated.value = terminal.truncated;
      proposal.sudoPasswordRequired.value = result.sudoPasswordRequired;
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
