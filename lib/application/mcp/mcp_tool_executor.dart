import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';

import '../../domain/ai/agent_diff.dart';
import '../../domain/ai/agent_skill.dart';
import '../../domain/ai/command_classifier.dart';
import '../../domain/entities/host.dart';
import '../../domain/mcp/mcp_models.dart';
import '../../domain/mcp/mcp_server_transport.dart';
import '../../domain/repositories/known_host_repository.dart';
import '../../domain/ssh/agent_ops.dart';
import '../../domain/ssh/server_status.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../ai/ssh_ops_tools.dart';
import '../gateways/gateway_controller.dart';
import '../hosts/host_controller.dart';
import '../identities/identity_controller.dart';
import '../session/session.dart';
import '../session/session_controller.dart';

/// 将 MCP 工具、资源和提示词映射到 PagaShell 的实时 SSH 会话与安全运维能力。
///
/// 绝不向外部 MCP 客户端暴露密码、私钥、口令、API Key 或主机备注。
class McpToolExecutor implements McpServerDelegate {
  McpToolExecutor({
    required this.sessions,
    required this.hosts,
    required this.gateways,
    required this.identities,
    required this.accessMode,
    required this.onAudit,
    this.knownHosts,
    this.serverVersion = '1.0.0',
  });

  final SessionController sessions;
  final HostController hosts;
  final GatewayController gateways;
  final IdentityController identities;
  final KnownHostRepository? knownHosts;
  final McpAccessMode Function() accessMode;
  final void Function(McpAuditEntry entry) onAudit;

  @override
  String get serverName => 'pagashell';

  @override
  final String serverVersion;

  @override
  String get instructions =>
      'PagaShell local MCP server for SSH server inspection and operations. '
      'Start by calling list_sessions to find already-connected SSH sessions, or list_hosts and connect_host to open a saved SSH host whose host key is already trusted in PagaShell. '
      'For maintenance and tuning, inspect_server_profile first, then check get_server_status, get_processes, get_network_ports, and relevant config files via read_remote_file. '
      'Use edit_remote_file for exact configuration edits (automatic timestamped backups + SHA-256 verification + optional validation_command) and rollback_remote_file to revert. '
      'Never pass passwords or private keys in commands or file edits; use sudo -n for noninteractive elevation.';

  static const _readOnlyAnnotation = McpToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );
  static const _readOnlyRemoteAnnotation = McpToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: true,
  );
  static const _connectAnnotation = McpToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: true,
  );
  static const _destructiveRemoteAnnotation = McpToolAnnotations(
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: false,
    openWorldHint: true,
  );

  static Map<String, Object?> _sessionSchema({
    Map<String, Object?> properties = const {},
    List<String> required = const [],
  }) => {
    'type': 'object',
    'properties': {
      'session_id': {
        'type': 'string',
        'description': 'Target SSH session ID from list_sessions or connect_host. Optional when exactly one ready SSH session is open.',
      },
      ...properties,
    },
    if (required.isNotEmpty) 'required': required,
    'additionalProperties': false,
  };

  @override
  List<McpToolDefinition> listTools() {
    final readOnly = accessMode() == McpAccessMode.readOnly;
    return [
      const McpToolDefinition(
        name: 'list_sessions',
        description: 'List currently open sessions in PagaShell with session_id, host metadata, connection phase, and supported capabilities. Never returns credentials.',
        inputSchema: {
          'type': 'object',
          'properties': <String, Object>{},
          'additionalProperties': false,
        },
        annotations: _readOnlyAnnotation,
      ),
      const McpToolDefinition(
        name: 'list_hosts',
        description: 'List saved SSH hosts in PagaShell (excluding RDP/VNC) with host_id, name, address, tags, hostKeyTrusted, and whether saved credentials exist. Never returns passwords, private keys, or notes.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Optional case-insensitive filter on name, hostname, username, or tags.',
            },
          },
          'additionalProperties': false,
        },
        annotations: _readOnlyAnnotation,
      ),
      const McpToolDefinition(
        name: 'connect_host',
        description: 'Connect to a saved SSH host by host_id or exact name using PagaShell stored credentials, or reuse an already-connected ready SSH session. Strictly requires a previously trusted SSH host key in PagaShell.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'host_id': {
              'type': 'string',
              'description': 'Exact host_id from list_hosts.',
            },
            'name': {
              'type': 'string',
              'description': 'Exact saved host name when host_id is omitted.',
            },
            'reuse_existing': {
              'type': 'boolean',
              'description': 'Reuse an existing ready SSH terminal session for this host if available (default true).',
            },
          },
          'additionalProperties': false,
        },
        annotations: _connectAnnotation,
      ),
      McpToolDefinition(
        name: 'inspect_server_profile',
        description: 'Read the OS, CPU/memory/Swap, disk media, package managers, noninteractive sudo availability, file limits, selected sysctl values, and installed services.',
        inputSchema: _sessionSchema(),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'get_server_status',
        description: 'Read a live resource snapshot (CPU, load average, memory, swap, disks, filesystems) from a ready SSH session.',
        inputSchema: _sessionSchema(),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'get_processes',
        description: 'Read a bounded process snapshot sorted by CPU or memory without exposing process arguments or environment.',
        inputSchema: _sessionSchema(
          properties: {
            'sort': {
              'type': 'string',
              'enum': ['cpu', 'memory'],
            },
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
          },
        ),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'get_network_ports',
        description: 'Read listening TCP/UDP ports and owning processes on the target SSH server.',
        inputSchema: _sessionSchema(),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'get_docker_resources',
        description: 'List Docker containers, images, networks, volumes, or compose projects, or inspect one resource by exact resource_id. Never exposes container environment variables or secrets.',
        inputSchema: _sessionSchema(
          properties: {
            'kind': {
              'type': 'string',
              'enum': ['container', 'image', 'network', 'volume', 'compose'],
            },
            'resource_id': {'type': 'string'},
          },
        ),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'list_remote_dir',
        description: 'List a bounded remote directory via SFTP.',
        inputSchema: _sessionSchema(
          properties: {
            'path': {
              'type': 'string',
              'description': 'Absolute POSIX directory path.',
            },
          },
          required: ['path'],
        ),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'read_remote_file',
        description: 'Read a paginated UTF-8 text/configuration file and its SHA-256. Credential files and private keys are blocked and sensitive assignments are redacted.',
        inputSchema: _sessionSchema(
          properties: {
            'path': {
              'type': 'string',
              'description': 'Absolute POSIX file path.',
            },
            'start_line': {'type': 'integer', 'minimum': 1},
            'max_lines': {'type': 'integer', 'minimum': 1, 'maximum': 500},
            'use_sudo': {'type': 'boolean'},
          },
          required: ['path'],
        ),
        annotations: _readOnlyRemoteAnnotation,
      ),
      McpToolDefinition(
        name: 'read_terminal_output',
        description: 'Read recent screen and scrollback from a ready SSH terminal session without sending input. Output is scrubbed of detected secrets.',
        inputSchema: _sessionSchema(
          properties: {
            'lines': {'type': 'integer', 'minimum': 1, 'maximum': 200},
            'wait_ms': {'type': 'integer', 'minimum': 0, 'maximum': 5000},
          },
        ),
        annotations: _readOnlyAnnotation,
      ),
      McpToolDefinition(
        name: 'read_skill',
        description: 'Load a built-in PagaShell operations playbook skill before performing Linux tuning, database optimization, software installation, or SSH troubleshooting.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'string',
              'enum': AgentSkill.builtIn.map((skill) => skill.id).toList(),
            },
          },
          'required': ['id'],
          'additionalProperties': false,
        },
        annotations: _readOnlyAnnotation,
      ),
      McpToolDefinition(
        name: 'exec_ssh_command',
        description: readOnly
            ? 'Run an allowlisted read-only noninteractive command on an independent SSH exec channel (MCP server is currently in read-only mode; mutating and unknown commands are rejected).'
            : 'Run a noninteractive command on an independent SSH exec channel. Returns exitCode, stdout, stderr, durationMs, timedOut, and cancelled. Rejects embedded passwords or sudo -S; use sudo -n when elevation is needed.',
        inputSchema: _sessionSchema(
          properties: {
            'command': {'type': 'string'},
            'purpose': {'type': 'string'},
            'impact': {'type': 'string'},
            'timeout_secs': {'type': 'integer', 'minimum': 1, 'maximum': 600},
          },
          required: ['command'],
        ),
        annotations: readOnly
            ? _readOnlyRemoteAnnotation
            : _destructiveRemoteAnnotation,
      ),
      if (!readOnly) ...[
        McpToolDefinition(
          name: 'edit_remote_file',
          description: 'Safely edit or create a UTF-8 remote configuration file with SHA-256 verification, automatic timestamped backup, sensitive-content blocking, and optional supported validation_command. Supply either exact edits or full content.',
          inputSchema: _sessionSchema(
            properties: {
              'path': {'type': 'string'},
              'purpose': {'type': 'string'},
              'edits': {
                'type': 'array',
                'minItems': 1,
                'maxItems': 32,
                'items': {
                  'type': 'object',
                  'properties': {
                    'oldText': {'type': 'string'},
                    'newText': {'type': 'string'},
                  },
                  'required': ['oldText', 'newText'],
                  'additionalProperties': false,
                },
              },
              'content': {'type': 'string'},
              'expected_sha256': {
                'type': 'string',
                'description': 'Optional SHA-256 from read_remote_file to enforce optimistic locking across calls.',
              },
              'create_if_missing': {'type': 'boolean'},
              'create_parent_dirs': {'type': 'boolean'},
              'use_sudo': {'type': 'boolean'},
              'validation_command': {'type': 'string'},
            },
            required: ['path', 'purpose'],
          ),
          annotations: _destructiveRemoteAnnotation,
        ),
        McpToolDefinition(
          name: 'rollback_remote_file',
          description: 'Restore a remote configuration file from a backup created by edit_remote_file (or delete a newly created file when backup_path is omitted), verified by SHA-256.',
          inputSchema: _sessionSchema(
            properties: {
              'path': {'type': 'string'},
              'current_sha256': {'type': 'string'},
              'backup_path': {'type': 'string'},
              'backup_sha256': {'type': 'string'},
              'use_sudo': {'type': 'boolean'},
            },
            required: ['path', 'current_sha256'],
          ),
          annotations: _destructiveRemoteAnnotation,
        ),
        McpToolDefinition(
          name: 'send_terminal_command',
          description: 'Send a command to an interactive SSH terminal PTY and briefly observe recent screen output. Prefer exec_ssh_command unless an interactive PTY is specifically required.',
          inputSchema: _sessionSchema(
            properties: {
              'command': {'type': 'string'},
              'purpose': {'type': 'string'},
              'wait_ms': {'type': 'integer', 'minimum': 0, 'maximum': 5000},
            },
            required: ['command'],
          ),
          annotations: _destructiveRemoteAnnotation,
        ),
      ],
    ];
  }

  @override
  List<McpResourceDefinition> listResources() => [
    const McpResourceDefinition(
      uri: 'pagashell://sessions',
      name: 'Open SSH Sessions',
      description: 'Current open sessions in PagaShell with session_id and capabilities (no credentials).',
      mimeType: 'application/json',
    ),
    const McpResourceDefinition(
      uri: 'pagashell://hosts',
      name: 'Saved SSH Hosts',
      description:
          'Saved SSH host inventory in PagaShell (no credentials or notes).',
      mimeType: 'application/json',
    ),
    for (final skill in AgentSkill.builtIn)
      McpResourceDefinition(
        uri: 'pagashell://skills/${skill.id}',
        name: skill.title,
        description: skill.description,
        mimeType: 'text/markdown',
      ),
  ];

  @override
  Future<McpResourceContent?> readResource(String uri) async {
    if (uri == 'pagashell://sessions') {
      return McpResourceContent(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode({'sessions': _sessionSummaries()}),
      );
    }
    if (uri == 'pagashell://hosts') {
      return McpResourceContent(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode({'hosts': await _hostSummaries()}),
      );
    }
    const skillPrefix = 'pagashell://skills/';
    if (uri.startsWith(skillPrefix)) {
      final id = uri.substring(skillPrefix.length);
      final skill = AgentSkill.builtIn.firstWhereOrNull((s) => s.id == id);
      if (skill == null) return null;
      return McpResourceContent(
        uri: uri,
        mimeType: 'text/markdown',
        text: skill.instructions,
      );
    }
    return null;
  }

  @override
  List<McpPromptDefinition> listPrompts() => [
    for (final skill in AgentSkill.builtIn)
      McpPromptDefinition(
        name: 'ops_${skill.id}',
        description: skill.description,
        arguments: const [
          McpPromptArgument(
            name: 'target',
            description: 'Optional host name or session_id to focus on.',
          ),
        ],
      ),
  ];

  @override
  Future<McpPromptResult?> getPrompt(
    String name,
    Map<String, String> arguments,
  ) async {
    const prefix = 'ops_';
    if (!name.startsWith(prefix)) return null;
    final id = name.substring(prefix.length);
    final skill = AgentSkill.builtIn.firstWhereOrNull((s) => s.id == id);
    if (skill == null) return null;
    final target = arguments['target']?.trim();
    final targetLine = target == null || target.isEmpty
        ? ''
        : '\n\nTarget host or session: ${scrubAgentOutput(target)}';
    return McpPromptResult(
      description: skill.description,
      messages: [
        McpPromptMessage(
          role: 'user',
          text:
              'Follow this PagaShell operations playbook using the available PagaShell MCP tools.\n\n'
              '${skill.instructions}$targetLine',
        ),
      ],
    );
  }

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final stopwatch = Stopwatch()..start();
    String? targetLabel;
    var status = McpAuditStatus.success;
    var summary = '';

    McpToolResult finish(
      McpToolResult result, {
      McpAuditStatus? overrideStatus,
      String? note,
    }) {
      status =
          overrideStatus ??
          (result.isError ? McpAuditStatus.error : McpAuditStatus.success);
      summary = scrubAgentOutput(
        truncateToolOutput(
          note ?? (result.isError ? result.text : 'ok'),
          maxChars: 160,
        ),
      );
      onAudit(
        McpAuditEntry(
          timestamp: DateTime.now(),
          toolName: name,
          target: targetLabel == null ? null : scrubAgentOutput(targetLabel),
          status: status,
          durationMs: stopwatch.elapsedMilliseconds,
          summary: summary,
        ),
      );
      return result;
    }

    try {
      switch (name) {
        case 'list_sessions':
          final list = _sessionSummaries();
          return finish(
            McpToolResult(text: jsonEncode({'sessions': list})),
            note: '${list.length} session(s)',
          );

        case 'list_hosts':
          final query = arguments['query'];
          final list = await _hostSummaries(
            query: query is String ? query : null,
          );
          return finish(
            McpToolResult(text: jsonEncode({'hosts': list})),
            note: '${list.length} SSH host(s)',
          );

        case 'connect_host':
          final outcome = await _connectHost(arguments);
          targetLabel = outcome.target;
          return finish(
            outcome.result,
            overrideStatus: outcome.denied ? McpAuditStatus.denied : null,
            note: outcome.note,
          );

        case 'read_skill':
          final id = arguments['id'];
          final skill = AgentSkill.builtIn.firstWhereOrNull((s) => s.id == id);
          if (skill == null) {
            return finish(
              const McpToolResult(text: 'Unknown skill.', isError: true),
            );
          }
          targetLabel = skill.id;
          return finish(
            McpToolResult(text: skill.instructions),
            note: skill.title,
          );

        case 'get_server_status':
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final source = target.engineSession;
          if (source is! ServerStatusSource) {
            return finish(
              const McpToolResult(
                text: 'Selected SSH session does not support server status.',
                isError: true,
              ),
            );
          }
          final sample = await (source as ServerStatusSource)
              .readServerStatus()
              .timeout(const Duration(seconds: 20));
          return finish(
            McpToolResult(
              text: jsonEncode(formatServerStatusSnapshot(target.id, sample)),
            ),
            note: sample.systemLabel,
          );

        case 'inspect_server_profile':
        case 'get_processes':
        case 'get_network_ports':
        case 'get_docker_resources':
        case 'list_remote_dir':
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await runSshInspectionTool(
            name,
            arguments,
            target,
            resolveLiveSession: () => _liveSession(target),
          ).timeout(const Duration(seconds: 20));
          if (outcome.error != null) {
            return finish(McpToolResult(text: outcome.error!, isError: true));
          }
          return finish(
            McpToolResult(text: outcome.json!),
            note: name == 'list_remote_dir' && arguments['path'] is String
                ? arguments['path'] as String
                : 'ok',
          );

        case 'read_remote_file':
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await _readRemoteFile(arguments, target);
          return finish(outcome.result, note: outcome.note);

        case 'read_terminal_output':
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final lines = boundedInt(arguments['lines'], 120, 1, 200);
          final waitMs = boundedInt(arguments['wait_ms'], 0, 0, 5000);
          if (waitMs > 0 && target.terminal != null) {
            final observed = await _observeTerminalOutput(
              target,
              timeout: Duration(milliseconds: waitMs),
              lines: lines,
            );
            return finish(McpToolResult(text: observed), note: '$lines lines');
          }
          return finish(
            McpToolResult(
              text: jsonEncode(readTerminalSnapshot(target, lines: lines)),
            ),
            note: '$lines lines',
          );

        case 'exec_ssh_command':
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await _execSshCommand(arguments, target);
          return finish(
            outcome.result,
            overrideStatus: outcome.denied ? McpAuditStatus.denied : null,
            note: outcome.note,
          );

        case 'edit_remote_file':
          if (accessMode() == McpAccessMode.readOnly) {
            return finish(
              const McpToolResult(
                text: 'MCP server is in read-only mode. edit_remote_file is disabled.',
                isError: true,
              ),
              overrideStatus: McpAuditStatus.denied,
              note: 'blocked by read-only mode',
            );
          }
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await _editRemoteFile(arguments, target);
          return finish(outcome.result, note: outcome.note);

        case 'rollback_remote_file':
          if (accessMode() == McpAccessMode.readOnly) {
            return finish(
              const McpToolResult(
                text: 'MCP server is in read-only mode. rollback_remote_file is disabled.',
                isError: true,
              ),
              overrideStatus: McpAuditStatus.denied,
              note: 'blocked by read-only mode',
            );
          }
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await _rollbackRemoteFile(arguments, target);
          return finish(outcome.result, note: outcome.note);

        case 'send_terminal_command':
          if (accessMode() == McpAccessMode.readOnly) {
            return finish(
              const McpToolResult(
                text: 'MCP server is in read-only mode. send_terminal_command is disabled.',
                isError: true,
              ),
              overrideStatus: McpAuditStatus.denied,
              note: 'blocked by read-only mode',
            );
          }
          final resolved = _resolveReadySshSession(arguments['session_id']);
          if (resolved.error != null) {
            return finish(McpToolResult(text: resolved.error!, isError: true));
          }
          final target = resolved.session!;
          targetLabel = _sessionLabel(target);
          final outcome = await _sendTerminalCommand(arguments, target);
          return finish(outcome.result, note: outcome.note);

        default:
          return finish(
            McpToolResult(text: 'Unknown tool: $name', isError: true),
          );
      }
    } on TimeoutException {
      return finish(
        const McpToolResult(
          text: 'Operation timed out. Check connection and remote state before retrying.',
          isError: true,
        ),
        note: 'timeout',
      );
    } on Object {
      return finish(
        const McpToolResult(
          text: 'Tool unavailable or failed. No diagnostic details containing credentials are exposed.',
          isError: true,
        ),
        note: 'failed',
      );
    }
  }

  String _sessionLabel(Session session) =>
      '${session.title} · ${session.address}';

  Session? _liveSession(Session target) {
    final current = sessions.sessions.firstWhereOrNull(
      (session) => session.id == target.id,
    );
    if (current == null ||
        current.phase != SessionPhase.ready ||
        current.kind != target.kind ||
        !identical(current.engineSession, target.engineSession) ||
        !identical(current.terminal, target.terminal)) {
      return null;
    }
    return current;
  }

  ({Session? session, String? error}) _resolveReadySshSession(Object? rawId) {
    final readySsh = sessions.sessions.where(isReadySshSession).toList();
    if (rawId is String && rawId.trim().isNotEmpty) {
      final id = rawId.trim();
      final match = readySsh.firstWhereOrNull((session) => session.id == id);
      if (match == null) {
        return (
          session: null,
          error:
              'No ready SSH terminal session with session_id "$id". Call list_sessions or connect_host first.',
        );
      }
      return (session: match, error: null);
    }
    if (readySsh.length == 1) {
      return (session: readySsh.single, error: null);
    }
    if (readySsh.isEmpty) {
      return (
        session: null,
        error: 'No ready SSH session is currently open. Call list_hosts and connect_host, or open an SSH session in PagaShell first.',
      );
    }
    final available = readySsh
        .map((session) => '${session.id} (${session.host.name})')
        .join(', ');
    return (
      session: null,
      error:
          'Multiple ready SSH sessions are open ($available). Specify session_id explicitly.',
    );
  }

  List<Map<String, Object?>> _sessionSummaries() {
    final activeId = sessions.activeSessionId.value;
    return [
      for (final session in sessions.sessions)
        {
          'session_id': session.id,
          'host_id': session.host.id,
          'name': session.host.name,
          'hostname': session.host.hostname,
          'port': session.host.port,
          'username': session.loginUsername,
          'protocol': session.host.serviceType.name,
          'tab': session.kind.name,
          'phase': session.phase.name,
          'viaGateway': session.host.gatewayId != null,
          'active': session.id == activeId,
          'supportsOps': isReadySshSession(session),
          'supportsExec':
              isReadySshSession(session) &&
              session.engineSession is SshExecSource,
          'supportsFileOps':
              isReadySshSession(session) &&
              session.engineSession is RemoteFileOpsSource,
        },
    ];
  }

  Future<List<Map<String, Object?>>> _hostSummaries({String? query}) async {
    final all = await hosts.loadAll();
    final filter = query?.trim().toLowerCase() ?? '';
    final sshHosts =
        all
            .where(
              (host) =>
                  !host.isDesktop &&
                  (filter.isEmpty || host.searchText.contains(filter)),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    final result = <Map<String, Object?>>[];
    for (final host in sshHosts) {
      final connected = sessions.sessions
          .where((s) => s.host.id == host.id && isReadySshSession(s))
          .map((s) => s.id)
          .toList();
      final trusted = knownHosts == null
          ? null
          : await knownHosts!.find(host.hostname, host.port) != null;
      final hasIdentity = host.identityId != null;
      final hasPassword = hasIdentity
          ? true
          : (await hosts.passwordOf(host.id)) != null;
      result.add({
        'host_id': host.id,
        'name': host.name,
        'hostname': host.hostname,
        'port': host.port,
        'username': host.username,
        'tags': host.tags,
        'viaGateway': host.gatewayId != null,
        'hasSavedCredentials': hasPassword,
        'hostKeyTrusted': trusted,
        'connectedSessionIds': connected,
      });
    }
    return result;
  }

  Future<({McpToolResult result, String? target, String note, bool denied})>
  _connectHost(Map<String, dynamic> arguments) async {
    final rawHostId = arguments['host_id'];
    final rawName = arguments['name'];
    final hostId = rawHostId is String ? rawHostId.trim() : '';
    final name = rawName is String ? rawName.trim() : '';
    final reuseExisting = arguments['reuse_existing'] != false;

    if (hostId.isEmpty && name.isEmpty) {
      return (
        result: const McpToolResult(
          text: 'Provide host_id or name from list_hosts.',
          isError: true,
        ),
        target: null,
        note: 'missing host_id/name',
        denied: false,
      );
    }

    final all = await hosts.loadAll();
    Host? host;
    if (hostId.isNotEmpty) {
      host = all.firstWhereOrNull((item) => item.id == hostId);
    } else {
      final matches = all
          .where((item) => !item.isDesktop && item.name == name)
          .toList();
      if (matches.length > 1) {
        final ids = matches.map((item) => item.id).join(', ');
        return (
          result: McpToolResult(
            text:
                'Multiple saved SSH hosts share the name "$name" (host_ids: $ids). Specify host_id explicitly.',
            isError: true,
          ),
          target: name,
          note: 'ambiguous host name',
          denied: false,
        );
      }
      host = matches.firstOrNull;
    }

    if (host == null) {
      return (
        result: const McpToolResult(
          text: 'Saved host not found. Call list_hosts first.',
          isError: true,
        ),
        target: hostId.isNotEmpty ? hostId : name,
        note: 'host not found',
        denied: false,
      );
    }

    final target = '${host.name} · ${host.address}';
    if (host.isDesktop) {
      return (
        result: const McpToolResult(
          text: 'RDP and VNC desktop services are not supported by MCP SSH tools.',
          isError: true,
        ),
        target: target,
        note: 'unsupported desktop protocol',
        denied: true,
      );
    }

    if (reuseExisting) {
      final existing = sessions.sessions.firstWhereOrNull(
        (session) => session.host.id == host!.id && isReadySshSession(session),
      );
      if (existing != null) {
        return (
          result: McpToolResult(
            text: jsonEncode({
              'session_id': existing.id,
              'host_id': host.id,
              'name': host.name,
              'hostname': host.hostname,
              'port': host.port,
              'username': existing.loginUsername,
              'reused': true,
              'phase': existing.phase.name,
            }),
          ),
          target: target,
          note: 'reused ${existing.id}',
          denied: false,
        );
      }
    }

    final prepared = await _prepareSavedConnection(host);
    if (prepared.error != null) {
      return (
        result: McpToolResult(text: prepared.error!, isError: true),
        target: target,
        note: 'missing saved credentials',
        denied: true,
      );
    }

    final existingIds = sessions.sessions.map((s) => s.id).toSet();
    String? openedId;
    try {
      openedId = await sessions
          .open(
            host,
            prepared.credentials!,
            kind: SessionKind.terminal,
            gateway: prepared.gateway,
            requireTrustedHostKey: true,
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      final created = sessions.sessions.firstWhereOrNull(
        (s) => s.host.id == host!.id && !existingIds.contains(s.id),
      );
      if (created != null) {
        await sessions.close(created.id);
      }
      return (
        result: const McpToolResult(
          text: 'SSH connection timed out after 30 seconds.',
          isError: true,
        ),
        target: target,
        note: 'connection timeout',
        denied: false,
      );
    } on SshEngineException catch (error) {
      return (
        result: McpToolResult(text: error.message, isError: true),
        target: target,
        note: error.message,
        denied: false,
      );
    }

    final session = sessions.sessions.firstWhereOrNull((s) => s.id == openedId);
    if (session == null || !isReadySshSession(session)) {
      final errorMessage = session?.error ?? 'SSH connection failed.';
      final hostKeyRejected =
          session?.hostKeyFailure != null || errorMessage.contains('主机指纹');
      if (session != null) {
        await sessions.close(session.id);
      }
      return (
        result: McpToolResult(
          text: jsonEncode({
            'connected': false,
            'host_id': host.id,
            'error': errorMessage,
            if (hostKeyRejected) 'code': 'host_key_verification_failed',
          }),
          isError: true,
        ),
        target: target,
        note: hostKeyRejected ? 'host key rejected' : 'connection failed',
        denied: hostKeyRejected,
      );
    }

    return (
      result: McpToolResult(
        text: jsonEncode({
          'session_id': session.id,
          'host_id': host.id,
          'name': host.name,
          'hostname': host.hostname,
          'port': host.port,
          'username': session.loginUsername,
          'reused': false,
          'phase': session.phase.name,
        }),
      ),
      target: target,
      note: 'connected ${session.id}',
      denied: false,
    );
  }

  Future<({SshCredentials? credentials, SshGateway? gateway, String? error})>
  _prepareSavedConnection(Host host) async {
    final credentials = await _resolveSavedCredentials(host, hosts);
    if (credentials.error != null) {
      return (credentials: null, gateway: null, error: credentials.error);
    }

    SshGateway? gateway;
    if (host.gatewayId case final gatewayId?) {
      final endpoint = await gateways.findSaved(gatewayId);
      if (endpoint == null) {
        return (
          credentials: null,
          gateway: null,
          error: 'Configured gateway no longer exists in PagaShell.',
        );
      }
      if (endpoint.gatewayType == GatewayType.page) {
        final token = await gateways.passwordOf(endpoint.id);
        if (token == null || token.isEmpty) {
          return (
            credentials: null,
            gateway: null,
            error: 'Gateway Page access token is not saved in PagaShell.',
          );
        }
        gateway = SshGateway.page(host: endpoint, token: token);
      } else {
        final gatewayCreds = await _resolveSavedCredentials(endpoint, gateways);
        if (gatewayCreds.error != null) {
          return (
            credentials: null,
            gateway: null,
            error:
                'Gateway has no saved credentials in PagaShell: ${gatewayCreds.error}',
          );
        }
        gateway = SshGateway(host: endpoint, credentials: gatewayCreds.value!);
      }
    }

    return (credentials: credentials.value, gateway: gateway, error: null);
  }

  Future<({SshCredentials? value, String? error})> _resolveSavedCredentials(
    Host host,
    HostController hostController,
  ) async {
    try {
      final bound = await identities.findSaved(host.identityId);
      if (bound != null) {
        if (!bound.supports(host.serviceType)) {
          return (
            value: null,
            error: 'Bound credential type does not match SSH service. Fix the binding in PagaShell.',
          );
        }
        final creds = await identities.credentialsOf(bound);
        if (creds != null) return (value: creds, error: null);
      }
      final savedPassword = await hostController.passwordOf(host.id);
      if (savedPassword != null) {
        return (value: SshCredentials.password(savedPassword), error: null);
      }
      return (
        value: null,
        error:
            'No saved credentials found for "${host.name}". Save a password or bind an SSH identity in PagaShell first.',
      );
    } on SecretStoreException {
      return (
        value: null,
        error: 'Unable to read saved credentials from PagaShell vault. Unlock or re-save the credential in PagaShell.',
      );
    }
  }

  Future<({McpToolResult result, String note})> _readRemoteFile(
    Map<String, dynamic> arguments,
    Session target,
  ) async {
    final path = arguments['path'];
    if (!isValidAgentPath(path)) {
      return (
        result: const McpToolResult(
          text: 'An absolute file path is required.',
          isError: true,
        ),
        note: 'invalid path',
      );
    }
    final concretePath = path! as String;
    final source = _liveSession(target)?.engineSession;
    if (source is! RemoteFileOpsSource) {
      return (
        result: const McpToolResult(
          text: 'Remote file reading is unsupported on this session.',
          isError: true,
        ),
        note: 'unsupported',
      );
    }
    try {
      final snapshot = await (source as RemoteFileOpsSource)
          .readRemoteText(concretePath, useSudo: arguments['use_sudo'] == true)
          .timeout(const Duration(seconds: 20));
      return (
        result: McpToolResult(
          text: jsonEncode(
            formatRemoteFilePage(
              target.id,
              concretePath,
              snapshot,
              startLine: arguments['start_line'],
              maxLines: arguments['max_lines'],
            ),
          ),
        ),
        note: concretePath,
      );
    } on RemoteFileOpsException catch (error) {
      return (
        result: McpToolResult(
          text: encodeRemoteFileToolError(error, concretePath),
          isError: true,
        ),
        note: '${error.error.name}: $concretePath',
      );
    }
  }

  Future<({McpToolResult result, String note, bool denied})> _execSshCommand(
    Map<String, dynamic> arguments,
    Session target,
  ) async {
    final command = arguments['command'];
    final purpose = arguments['purpose'];
    if (command is! String ||
        !isValidAgentCommand(command) ||
        (purpose != null && (purpose is! String || purpose.length > 2000))) {
      return (
        result: const McpToolResult(
          text: 'Invalid command or purpose (empty, too long, control characters, or embedded credentials/secrets are rejected). Nothing executed.',
          isError: true,
        ),
        note: 'invalid command',
        denied: true,
      );
    }
    final risk = classifyShellCommand(command);
    if (accessMode() == McpAccessMode.readOnly &&
        risk != AgentCommandRisk.readOnly) {
      return (
        result: const McpToolResult(
          text: 'MCP server is in read-only mode; only allowlisted read-only commands are permitted. Nothing executed.',
          isError: true,
        ),
        note:
            'blocked (${risk.name}): ${truncateToolOutput(command, maxChars: 80)}',
        denied: true,
      );
    }
    final source = _liveSession(target)?.engineSession;
    if (source is! SshExecSource) {
      return (
        result: const McpToolResult(
          text: 'The selected session does not support background SSH exec.',
          isError: true,
        ),
        note: 'exec unsupported',
        denied: false,
      );
    }
    final timeoutSecs = boundedInt(arguments['timeout_secs'], 60, 1, 600);
    final collected = await collectSshExec(
      source as SshExecSource,
      command,
      timeoutSecs,
    );
    final payload = {
      'session_id': target.id,
      'risk': risk.name,
      ...collected.toJson(),
      if (collected.sudoPasswordRequired) 'note': 'Noninteractive sudo requires a password. Ask the user to run this step directly in PagaShell terminal.',
      if (collected.terminal.timedOut || collected.terminal.cancelled) 'note': 'The exec channel was interrupted. A remote service or child process may still have changed state; verify before retrying.',
    };
    return (
      result: McpToolResult(
        text: jsonEncode(payload),
        isError: collected.terminal.exitCode == null,
      ),
      note:
          'exit=${collected.terminal.exitCode ?? 'unknown'} · ${truncateToolOutput(command, maxChars: 80)}',
      denied: false,
    );
  }

  Future<({McpToolResult result, String note})> _editRemoteFile(
    Map<String, dynamic> arguments,
    Session target,
  ) async {
    final rawPath = arguments['path'];
    final purpose = arguments['purpose'];
    final content = arguments['content'];
    final rawEdits = arguments['edits'];
    final expectedSha = arguments['expected_sha256'];
    final validation = arguments['validation_command'];
    if (!isValidAgentPath(rawPath) ||
        purpose is! String ||
        purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        (content is String) == (rawEdits is List<dynamic>) ||
        (expectedSha != null && expectedSha is! String) ||
        (validation != null &&
            (validation is! String || !isAgentValidationCommand(validation)))) {
      return (
        result: const McpToolResult(
          text: 'Invalid edit parameters. Supply an absolute path, purpose, either content or exact edits, and only a supported validation_command. Nothing written.',
          isError: true,
        ),
        note: 'invalid edit params',
      );
    }
    final path = rawPath! as String;
    final source = _liveSession(target)?.engineSession;
    if (source is! RemoteFileOpsSource) {
      return (
        result: const McpToolResult(
          text: 'Remote file editing is unsupported on this session.',
          isError: true,
        ),
        note: 'unsupported',
      );
    }
    if (validation != null && source is! SshExecSource) {
      return (
        result: const McpToolResult(
          text: 'Validation is not available on this connection. Nothing written.',
          isError: true,
        ),
        note: 'validation unsupported',
      );
    }
    final files = source as RemoteFileOpsSource;
    final create = arguments['create_if_missing'] == true;
    final parents = arguments['create_parent_dirs'] == true;
    if (parents && !create) {
      return (
        result: const McpToolResult(
          text: 'create_parent_dirs can only be used with create_if_missing.',
          isError: true,
        ),
        note: 'invalid parent dir flag',
      );
    }
    final explicitSudo = arguments['use_sudo'] == true;
    final sudo =
        explicitSudo ||
        path.startsWith('/etc/') ||
        path.startsWith('/private/etc/');

    RemoteTextSnapshot? original;
    try {
      try {
        original = await files
            .readRemoteText(path, useSudo: explicitSudo)
            .timeout(const Duration(seconds: 20));
      } on RemoteFileOpsException catch (error) {
        if (!sudo ||
            explicitSudo ||
            (error.error != RemoteFileError.failed &&
                error.error != RemoteFileError.notFound)) {
          rethrow;
        }
        original = await files
            .readRemoteText(path, useSudo: true)
            .timeout(const Duration(seconds: 20));
      }
    } on RemoteFileOpsException catch (error) {
      if (!create || error.error != RemoteFileError.notFound) {
        return (
          result: McpToolResult(
            text: encodeRemoteFileToolError(error, path),
            isError: true,
          ),
          note: '${error.error.name}: $path',
        );
      }
    }

    if (expectedSha is String && expectedSha.isNotEmpty) {
      if (original == null || original.sha256 != expectedSha) {
        return (
          result: McpToolResult(
            text: encodeRemoteFileToolError(
              const RemoteFileOpsException(RemoteFileError.conflict),
              path,
            ),
            isError: true,
          ),
          note: 'sha256 conflict: $path',
        );
      }
    }

    String updated;
    if (content is String) {
      updated = content;
    } else {
      final edits = rawEdits! as List<dynamic>;
      if (edits.isEmpty || edits.length > 32 || original == null) {
        return (
          result: const McpToolResult(
            text: 'Use 1–32 exact edits for an existing file, or content for a new file.',
            isError: true,
          ),
          note: 'invalid edits',
        );
      }
      final typed = <TextFileEdit>[];
      for (final edit in edits) {
        if (edit is! Map<String, dynamic> ||
            edit['oldText'] is! String ||
            edit['newText'] is! String) {
          return (
            result: const McpToolResult(
              text: 'Every edit needs exact oldText and newText strings. Nothing written.',
              isError: true,
            ),
            note: 'invalid edit entry',
          );
        }
        typed.add(
          TextFileEdit(edit['oldText'] as String, edit['newText'] as String),
        );
      }
      try {
        updated = applyTextFileEdits(original.text, typed);
      } on FormatException catch (error) {
        return (
          result: McpToolResult(text: error.message, isError: true),
          note: 'edit match failed',
        );
      }
    }

    if (exceedsUtf8Limit(updated, 2 * 1024 * 1024)) {
      return (
        result: const McpToolResult(
          text: 'Configuration exceeds the 2 MiB limit. Nothing written.',
          isError: true,
        ),
        note: 'too large',
      );
    }
    if (containsSensitiveOutput(updated) ||
        (original != null && containsSensitiveOutput(original.text)) ||
        hasSshControlCharacters(updated)) {
      return (
        result: const McpToolResult(
          text: 'Possible credentials, private key, or nontext content detected. Nothing written.',
          isError: true,
        ),
        note: 'sensitive content blocked',
      );
    }
    if (original?.text == updated) {
      return (
        result: McpToolResult(
          text: jsonEncode({
            'session_id': target.id,
            'path': path,
            'applied': false,
            'unchanged': true,
            'sha256': original?.sha256,
          }),
        ),
        note: 'unchanged: $path',
      );
    }

    final diff = UnifiedDiff.between(original?.text ?? '', updated);
    try {
      final written = await files
          .writeRemoteText(
            path,
            updated,
            expectedSha256: original?.sha256,
            createIfMissing: create,
            createParentDirs: parents,
            backupSuffix: generateRemoteBackupSuffix(),
            useSudo: sudo,
          )
          .timeout(const Duration(seconds: 30));

      bool? validationPassed;
      String? validationOutput;
      if (validation is String && _liveSession(target) != null) {
        final checked = await collectSshExec(
          source as SshExecSource,
          validation,
          30,
        );
        validationPassed = checked.success;
        validationOutput = truncateToolOutput(
          [
            checked.stdout,
            checked.stderr,
            checked.terminal.data,
          ].where((value) => value.isNotEmpty).join('\n'),
          maxChars: 8000,
        );
      }

      return (
        result: McpToolResult(
          text: jsonEncode({
            'session_id': target.id,
            'path': path,
            'applied': true,
            'backupPath': written.backupPath,
            'sha256': written.sha256,
            'previousSha256': original?.sha256,
            'createdNew': written.createdNew,
            'usedSudo': sudo,
            'addedLines': diff.added,
            'removedLines': diff.removed,
            'diff': scrubAgentOutput(diff.toText(path, maxChars: 12000)),
            'validationPassed': validationPassed,
            'validationOutput': validationOutput,
            if (validationPassed == false) 'note': 'Validation did not pass. Do not reload the service; call rollback_remote_file with backupPath and sha256 to revert.',
          }),
        ),
        note: '$path (+${diff.added}/-${diff.removed})',
      );
    } on RemoteFileOpsException catch (error) {
      return (
        result: McpToolResult(
          text: encodeRemoteFileToolError(error, path),
          isError: true,
        ),
        note: '${error.error.name}: $path',
      );
    }
  }

  Future<({McpToolResult result, String note})> _rollbackRemoteFile(
    Map<String, dynamic> arguments,
    Session target,
  ) async {
    final rawPath = arguments['path'];
    final currentSha = arguments['current_sha256'];
    final backupPath = arguments['backup_path'];
    final backupSha = arguments['backup_sha256'];
    if (!isValidAgentPath(rawPath) ||
        currentSha is! String ||
        currentSha.trim().isEmpty ||
        (backupPath != null && !isValidAgentPath(backupPath)) ||
        (backupSha != null && backupSha is! String)) {
      return (
        result: const McpToolResult(
          text: 'Invalid rollback parameters. Supply absolute path, current_sha256, and optional absolute backup_path/backup_sha256.',
          isError: true,
        ),
        note: 'invalid rollback params',
      );
    }
    final path = rawPath! as String;
    final source = _liveSession(target)?.engineSession;
    if (source is! RemoteFileOpsSource) {
      return (
        result: const McpToolResult(
          text: 'Remote file rollback is unsupported on this session.',
          isError: true,
        ),
        note: 'unsupported',
      );
    }
    final sudo =
        arguments['use_sudo'] == true ||
        path.startsWith('/etc/') ||
        path.startsWith('/private/etc/');
    try {
      await (source as RemoteFileOpsSource)
          .restoreRemoteBackup(
            path,
            backupPath: backupPath as String?,
            currentSha256: currentSha,
            backupSha256: backupSha as String?,
            useSudo: sudo,
          )
          .timeout(const Duration(seconds: 30));
      return (
        result: McpToolResult(
          text: jsonEncode({
            'session_id': target.id,
            'path': path,
            'rolledBack': true,
            'backupPath': backupPath,
          }),
        ),
        note: 'rolled back $path',
      );
    } on RemoteFileOpsException catch (error) {
      return (
        result: McpToolResult(
          text: encodeRemoteFileToolError(error, path),
          isError: true,
        ),
        note: '${error.error.name}: $path',
      );
    }
  }

  Future<({McpToolResult result, String note})> _sendTerminalCommand(
    Map<String, dynamic> arguments,
    Session target,
  ) async {
    final command = arguments['command'];
    if (command is! String || !isValidAgentCommand(command)) {
      return (
        result: const McpToolResult(
          text: 'Invalid command. Nothing sent to terminal.',
          isError: true,
        ),
        note: 'invalid terminal command',
      );
    }
    if (!sessions.canSendCommandToSession(target.id)) {
      return (
        result: const McpToolResult(
          text: 'The selected SSH terminal is not ready to accept input.',
          isError: true,
        ),
        note: 'terminal unavailable',
      );
    }
    final waitMs = boundedInt(arguments['wait_ms'], 1500, 0, 5000);
    final observation = waitMs > 0 && target.terminal != null
        ? _observeTerminalOutput(
            target,
            timeout: Duration(milliseconds: waitMs),
            lines: 120,
          )
        : null;
    final sent = sessions.sendCommandToSession(target.id, command);
    if (!sent) {
      return (
        result: const McpToolResult(
          text: 'Failed to queue command to SSH terminal.',
          isError: true,
        ),
        note: 'send failed',
      );
    }
    final terminalJson = observation != null
        ? jsonDecode(await observation)
        : readTerminalSnapshot(target, lines: 120);
    return (
      result: McpToolResult(
        text: jsonEncode({
          'inputSent': true,
          'session_id': target.id,
          'command': scrubAgentOutput(command),
          'terminal': terminalJson,
          'note': 'Input was queued to the interactive terminal. Observed screen output is evidence, not proof of command completion or exit code.',
        }),
      ),
      note: truncateToolOutput(command, maxChars: 80),
    );
  }

  Future<String> _observeTerminalOutput(
    Session target, {
    required Duration timeout,
    int lines = 120,
  }) {
    final terminal = target.terminal!;
    final result = Completer<String>();
    var previous = rawTerminalSnapshotText(_liveSession(target), lines: lines);
    var changed = false;
    Timer? quiet;
    Timer? deadline;
    Timer? check;
    late void Function() onChanged;

    void finish(String reason) {
      if (result.isCompleted) return;
      quiet?.cancel();
      deadline?.cancel();
      check?.cancel();
      terminal.removeListener(onChanged);
      result.complete(
        jsonEncode({
          ...readTerminalSnapshot(_liveSession(target), lines: lines),
          'observation': reason,
          'outputChanged': changed,
          'completionKnown': false,
        }),
      );
    }

    onChanged = () {
      if (result.isCompleted) return;
      final current = rawTerminalSnapshotText(
        _liveSession(target),
        lines: lines,
      );
      if (current == previous) return;
      previous = current;
      changed = true;
      quiet?.cancel();
      quiet = Timer(
        const Duration(milliseconds: 600),
        () => finish('output_observed'),
      );
    };

    terminal.addListener(onChanged);
    deadline = Timer(timeout, () => finish('observation_timeout'));
    check = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_liveSession(target) == null) {
        finish('session_unavailable');
      }
    });
    return result.future;
  }
}
