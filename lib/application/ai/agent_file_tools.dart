part of 'agent_controller.dart';

class AgentFileChangeProposal {
  AgentFileChangeProposal._({
    required this.target,
    required this.path,
    required this.purpose,
    required this.diff,
    required this.originalSha256,
    required this._content,
    required this.createIfMissing,
    required this.createParentDirs,
    required this.useSudo,
    required this.validationCommand,
    required this.generation,
  });

  final Session target;
  final String path, purpose;
  final UnifiedDiff diff;
  final String? originalSha256, validationCommand;
  final bool createIfMissing, createParentDirs, useSudo;
  final int generation;
  final _decision = Completer<bool>();
  String? _content;
  String? _appliedSha256;
  final state = AgentFileChangeState.pending.obs;
  final working = false.obs;
  final backupPath = RxnString();
  final validationOutput = RxnString();
  final validationPassed = RxnBool();
  final sudoPasswordRequired = false.obs;
  final error = RxnString();
  bool get createsFile => originalSha256 == null;
  late final String diffPreview = diff.toText(path, maxChars: 256 * 1024);
  late final String _archiveDiff = diff.toText(path);
  String get terminalFallback => 'sudoedit -- ${_quotePath(path)}';
  AgentArchivedFileChange? _archivedCache;

  void _invalidateArchive() => _archivedCache = null;

  AgentArchivedFileChange _archive() =>
      _archivedCache ??= AgentArchivedFileChange(
        path: path,
        purpose: purpose,
        target: target.title,
        diffText: _archiveDiff,
        addedLines: diff.added,
        removedLines: diff.removed,
        backupPath: backupPath.value,
        createdNew: createsFile,
        usedSudo: useSudo,
        validationOutput: validationOutput.value,
        validationPassed: validationPassed.value,
        state: state.value == AgentFileChangeState.pending
            ? AgentFileChangeState.unavailable
            : state.value,
        error: error.value,
      );
}

String _quotePath(String path) => quotePosixPath(path);

String _fileError(RemoteFileError error) => describeRemoteFileError(error);

String _fileToolError(RemoteFileOpsException error, String path) =>
    encodeRemoteFileToolError(error, path);

extension _AgentFileOperations on AgentController {
  Future<RemoteTextSnapshot?> _readFileSnapshot(
    RemoteFileOpsSource source,
    Session target,
    String path, {
    required bool sudo,
    required AgentAccessMode mode,
    required int generation,
  }) async {
    AgentCommandProposal? review;
    if (sudo) {
      review = AgentCommandProposal(
        command: 'sudo -n -- cat -- ${_quotePath(path)}',
        purpose: '以 sudo 读取远程文件',
        target: target,
        generation: generation,
        executionMode: AgentCommandExecutionMode.exec,
        isStructuredRead: true,
      );
      if (!await _reviewCommand(
        review,
        auto: mode != AgentAccessMode.requestApproval,
      )) {
        return null;
      }
    }
    if (!_live(generation) || _boundSession(target) == null) return null;
    review?.running.value = true;
    try {
      final snapshot = await source.readRemoteText(path, useSudo: sudo);
      review?.exitCode.value = 0;
      return snapshot;
    } on RemoteFileOpsException catch (error) {
      review?.sudoPasswordRequired.value = error.isSudoPasswordRequired;
      review?.error.value = _fileError(error.error);
      rethrow;
    } finally {
      if (review != null) {
        review.running.value = false;
        review._invalidateArchive();
        if (entries.any((entry) => identical(entry.command, review))) {
          _saveConversation(deferred: true);
        }
      }
    }
  }

  Future<String> _readFileTool(
    AgentToolCall call,
    Session target,
    int generation,
    AgentAccessMode mode,
  ) async {
    final path = call.arguments['path'];
    if (!_validAgentPath(path)) return 'An absolute file path is required.';
    final concretePath = path! as String;
    final source = _boundSession(target)?.engineSession;
    if (source is! RemoteFileOpsSource) {
      return 'Remote configuration reading is unsupported.';
    }
    try {
      final file = await _readFileSnapshot(
        source as RemoteFileOpsSource,
        target,
        concretePath,
        sudo: call.arguments['use_sudo'] == true,
        mode: mode,
        generation: generation,
      );
      if (file == null || !_live(generation)) {
        return 'File read declined or cancelled.';
      }
      return jsonEncode(
        formatRemoteFilePage(
          target.id,
          concretePath,
          file,
          startLine: call.arguments['start_line'],
          maxLines: call.arguments['max_lines'],
        ),
      );
    } on RemoteFileOpsException catch (error) {
      return _fileToolError(error, concretePath);
    }
  }

  Future<String> _editFileTool(
    AgentToolCall call,
    Session target,
    int generation,
    AgentAccessMode mode,
  ) async {
    final args = call.arguments;
    final rawPath = args['path'];
    final purpose = args['purpose'];
    final content = args['content'];
    final rawEdits = args['edits'];
    final validation = args['validation_command'];
    if (!_validAgentPath(rawPath) ||
        purpose is! String ||
        purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        (content is String) == (rawEdits is List<dynamic>) ||
        (validation != null &&
            (validation is! String || !isAgentValidationCommand(validation)))) {
      return 'Invalid edit parameters. Supply an absolute path, purpose, either content or exact edits, and only a supported validation command. Nothing written.';
    }
    final path = rawPath! as String;
    final source = _boundSession(target)?.engineSession;
    if (source is! RemoteFileOpsSource) {
      return 'Remote configuration editing is unsupported.';
    }
    if (validation != null && source is! SshExecSource) {
      return 'Validation is not available on this connection. Nothing written.';
    }
    final files = source as RemoteFileOpsSource;
    final create = args['create_if_missing'] == true;
    final parents = args['create_parent_dirs'] == true;
    if (parents && !create) {
      return 'Parent directories can only be created with create_if_missing.';
    }
    final explicitSudo = args['use_sudo'] == true;
    final sudo =
        explicitSudo ||
        path.startsWith('/etc/') ||
        path.startsWith('/private/etc/');
    Future<RemoteTextSnapshot?> readPreview({required bool elevated}) =>
        _readFileSnapshot(
          files,
          target,
          path,
          sudo: elevated,
          mode: mode,
          generation: generation,
        );
    RemoteTextSnapshot? original;
    try {
      try {
        original = await readPreview(elevated: explicitSudo);
      } on RemoteFileOpsException catch (error) {
        if (!sudo ||
            explicitSudo ||
            (error.error != RemoteFileError.failed &&
                error.error != RemoteFileError.notFound) ||
            !_live(generation)) {
          rethrow;
        }
        // A protected system file can look absent without search permission.
        // Obtain the approved elevated snapshot before treating it as new.
        original = await readPreview(elevated: true);
      }
      if (original == null) {
        return 'File preview declined or cancelled. Nothing written.';
      }
    } on RemoteFileOpsException catch (error) {
      if (!create || error.error != RemoteFileError.notFound) {
        return _fileToolError(error, path);
      }
    }
    if (!_live(generation) || _boundSession(target) == null) {
      return _missingSshTarget;
    }
    String updated;
    if (content is String) {
      updated = content;
    } else {
      final edits = rawEdits! as List<dynamic>;
      if (edits.isEmpty || edits.length > 32 || original == null) {
        return 'Use 1–32 exact edits for an existing file, or content for a new file.';
      }
      final typed = <TextFileEdit>[];
      for (final edit in edits) {
        if (edit is! Map<String, dynamic> ||
            edit['oldText'] is! String ||
            edit['newText'] is! String) {
          return 'Every edit needs exact oldText and newText strings. Nothing written.';
        }
        typed.add(
          TextFileEdit(edit['oldText'] as String, edit['newText'] as String),
        );
      }
      try {
        updated = applyTextFileEdits(original.text, typed);
      } on FormatException catch (error) {
        return error.message;
      }
    }
    if (_exceedsUtf8Limit(updated, 2 * 1024 * 1024)) {
      return 'Configuration exceeds the 2 MiB limit.';
    }
    if (_containsSensitiveOutput(updated) ||
        (original != null && _containsSensitiveOutput(original.text)) ||
        hasSshControlCharacters(updated)) {
      return 'Possible credentials, private key or nontext content. Nothing written.';
    }
    if (original?.text == updated) {
      return 'File already matches the proposed configuration. Nothing written.';
    }
    final diff = UnifiedDiff.between(original?.text ?? '', updated);
    final proposal = AgentFileChangeProposal._(
      target: target,
      path: path,
      purpose: _scrubAgentOutput(purpose),
      diff: diff,
      originalSha256: original?.sha256,
      content: updated,
      createIfMissing: create,
      createParentDirs: parents,
      useSudo: sudo,
      validationCommand: validation as String?,
      generation: generation,
    );
    _addEntry(
      AgentEntry(
        AgentEntryKind.fileChange,
        proposal.purpose,
        fileChange: proposal,
      ),
    );
    if (_live(generation)) {
      waitingForApproval.value = true;
      activity.value = '等待批准';
    }
    if (!await proposal._decision.future ||
        !_live(generation) ||
        _boundSession(target) == null) {
      if (proposal.state.value == AgentFileChangeState.pending) {
        proposal.state.value = AgentFileChangeState.unavailable;
      }
      proposal.working.value = false;
      proposal._content = null;
      proposal._invalidateArchive();
      return 'File change declined or target no longer available. Nothing written.';
    }
    waitingForApproval.value = false;
    activity.value = '正在应用远程配置';
    final suffix = generateRemoteBackupSuffix();
    try {
      if (!_live(generation) || _boundSession(target) == null) {
        proposal.state.value = AgentFileChangeState.unavailable;
        return _missingSshTarget;
      }
      final result = await files.writeRemoteText(
        path,
        proposal._content!,
        expectedSha256: original?.sha256,
        createIfMissing: create,
        createParentDirs: parents,
        backupSuffix: suffix,
        useSudo: sudo,
      );
      proposal.backupPath.value = result.backupPath;
      proposal._appliedSha256 = result.sha256;
      proposal.state.value = AgentFileChangeState.applied;
      if (proposal.validationCommand case final command?
          when _live(generation) && _boundSession(target) != null) {
        final checked = await _collectExec(
          source as SshExecSource,
          command,
          30,
        );
        proposal.validationOutput.value = _truncateToolOutput(
          [
            checked.stdout,
            checked.stderr,
            checked.terminal.data,
          ].where((value) => value.isNotEmpty).join('\n'),
          maxChars: 8000,
        );
        proposal.validationPassed.value = checked.success;
      }
      return jsonEncode({
        'session_id': target.id,
        'path': path,
        'applied': true,
        'backupPath': result.backupPath,
        'sha256': result.sha256,
        'createdNew': result.createdNew,
        'addedLines': diff.added,
        'removedLines': diff.removed,
        'validationPassed': proposal.validationPassed.value,
        'validationOutput': proposal.validationOutput.value,
        if (proposal.validationPassed.value == false) 'note': 'Validation did not pass. Do not reload the service; the user can roll the file back from the card.',
      });
    } on RemoteFileOpsException catch (error) {
      proposal.state.value = AgentFileChangeState.failed;
      proposal.error.value = _fileError(error.error);
      proposal.sudoPasswordRequired.value = error.isSudoPasswordRequired;
      return _fileToolError(error, path);
    } on Object {
      proposal.state.value = AgentFileChangeState.failed;
      proposal.error.value = _fileError(RemoteFileError.outcomeUnknown);
      return _fileToolError(
        const RemoteFileOpsException(RemoteFileError.outcomeUnknown),
        path,
      );
    } finally {
      proposal.working.value = false;
      proposal._content = null;
      proposal._invalidateArchive();
      _saveFileCard(proposal);
    }
  }

  bool _ownsFileCard(AgentFileChangeProposal proposal) =>
      entries.any((entry) => identical(entry.fileChange, proposal));

  void _saveFileCard(AgentFileChangeProposal proposal) {
    if (_ownsFileCard(proposal)) _saveConversation();
  }

  bool _canApplyFileChange(AgentFileChangeProposal proposal) =>
      _live(proposal.generation) &&
      !proposal._decision.isCompleted &&
      _ownsFileCard(proposal) &&
      _boundSession(proposal.target) != null;

  bool _approveFileChange(AgentFileChangeProposal proposal) {
    if (!_canApplyFileChange(proposal)) return false;
    proposal._decision.complete(true);
    proposal.working.value = true;
    return true;
  }

  void _rejectFileChange(AgentFileChangeProposal proposal) {
    if (proposal._decision.isCompleted) return;
    proposal.state.value = AgentFileChangeState.rejected;
    proposal._content = null;
    proposal._invalidateArchive();
    proposal._decision.complete(false);
    _saveFileCard(proposal);
  }

  bool _canRollbackFileChange(AgentFileChangeProposal proposal) =>
      !isClosed &&
      _ownsFileCard(proposal) &&
      !proposal.working.value &&
      proposal.state.value == AgentFileChangeState.applied &&
      proposal._appliedSha256 != null &&
      _boundSession(proposal.target) != null;

  Future<bool> _rollbackFileChange(AgentFileChangeProposal proposal) async {
    if (!_canRollbackFileChange(proposal)) return false;
    final source = _boundSession(proposal.target)?.engineSession;
    if (source is! RemoteFileOpsSource) return false;
    proposal.working.value = true;
    proposal.error.value = null;
    try {
      if (!_ownsFileCard(proposal) || _boundSession(proposal.target) == null) {
        return false;
      }
      await (source as RemoteFileOpsSource).restoreRemoteBackup(
        proposal.path,
        backupPath: proposal.backupPath.value,
        currentSha256: proposal._appliedSha256!,
        backupSha256: proposal.originalSha256,
        useSudo: proposal.useSudo,
      );
      proposal.state.value = AgentFileChangeState.rolledBack;
      return true;
    } on RemoteFileOpsException catch (error) {
      proposal.sudoPasswordRequired.value = error.isSudoPasswordRequired;
      proposal.error.value = _fileError(error.error);
      return false;
    } on Object {
      proposal.error.value = _fileError(RemoteFileError.outcomeUnknown);
      return false;
    } finally {
      proposal.working.value = false;
      proposal._invalidateArchive();
      _saveFileCard(proposal);
    }
  }
}
