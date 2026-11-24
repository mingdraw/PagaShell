import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/mcp/mcp_server_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/mcp/mcp_models.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/ssh/agent_ops.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_ai_settings_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/mcp/local_mcp_http_server.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';
import 'package:pagashell/terminal/core.dart';

import '../support/agent_ssh_fixture.dart';
import '../support/in_memory_ai_settings_repository.dart';

Map<String, dynamic> _asMap(Object? value) => value! as Map<String, dynamic>;

List<dynamic> _asList(Object? value) => value! as List<dynamic>;

String _toolText(Map<String, dynamic> response) {
  final result = _asMap(response['result']);
  final content = _asList(result['content']);
  return _asMap(content.first)['text'] as String;
}

bool _isToolError(Map<String, dynamic> response) =>
    _asMap(response['result'])['isError'] == true;

class _InMemoryKnownHosts implements KnownHostRepository {
  final _store = <(String, int, ServerIdentityProtocol), SshHostKey>{};

  void trust(SshHostKey key) {
    _store[(key.hostname, key.port, key.protocol)] = key;
  }

  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async => _store[(hostname, port, protocol)];

  @override
  Future<bool> trustIfAbsent(SshHostKey key) async {
    final k = (key.hostname, key.port, key.protocol);
    if (_store.containsKey(k)) return false;
    _store[k] = key;
    return true;
  }

  @override
  Future<bool> removeIfMatches(SshHostKey key) async {
    final k = (key.hostname, key.port, key.protocol);
    final existing = _store[k];
    if (existing == null || !existing.matches(key)) return false;
    _store.remove(k);
    return true;
  }
}

class _McpSshSession extends AgentSshFixture
    implements TerminalScreenSource, ServerStatusSource {
  final _frames = StreamController<TerminalFrame>.broadcast();
  final written = <String>[];

  @override
  Stream<TerminalFrame> startTerminalShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) => _frames.stream;

  @override
  Future<void> acknowledgeTerminalFrame(int frameId) async {}

  @override
  Future<void> resizeTerminal(int cols, int rows) async {}

  @override
  void write(String data) {
    written.add(data);
  }

  @override
  Future<ServerStatusSample> readServerStatus() async =>
      const ServerStatusSample(
        system: 'Linux',
        systemRelease: 'Ubuntu 24.04',
        architecture: 'x86_64',
        loadAverage: [0.42, 0.38, 0.31],
        uptimeSeconds: 7200,
        cpuTotal: 1000,
        cpuIdle: 800,
        memoryTotal: 16 * 1024 * 1024 * 1024,
        memoryAvailable: 8 * 1024 * 1024 * 1024,
        filesystems: [],
        network: {},
        disks: {},
      );

  @override
  Future<void> close() async {
    await super.close();
    await _frames.close();
  }
}

class _ScriptedSshEngine implements SshEngine {
  _ScriptedSshEngine(this.hostKeys, this.sessionFactory);

  final Map<String, SshHostKey> hostKeys;
  final _McpSshSession Function(Host host, SshCredentials creds) sessionFactory;
  int connectCalls = 0;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    connectCalls++;
    final key = hostKeys[host.id];
    if (key != null && verifyHostKey != null) {
      final ok = await verifyHostKey(key);
      if (!ok) throw const SshEngineException('主机指纹未通过验证');
    }
    return sessionFactory(host, credentials);
  }
}

Future<int> _reserveFreeLoopbackPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<Map<String, dynamic>> _mcpCall(
  HttpClient client,
  int port,
  String token,
  String method, {
  Map<String, Object?>? params,
  String? sessionId,
}) async {
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  req.headers.contentType = ContentType.json;
  if (sessionId != null) req.headers.set('MCP-Session-Id', sessionId);
  req.add(
    utf8.encode(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      }),
    ),
  );
  final res = await req.close();
  final body = await utf8.decoder.bind(res).join();
  expect(res.statusCode, HttpStatus.ok, reason: 'Unexpected body: $body');
  return _asMap(jsonDecode(body));
}

void main() {
  test('DriftAiSettingsRepository 正确持久化与向后兼容 MCP 配置', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftAiSettingsRepository(db);

    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: DriftAiSettingsRepository.settingsKey,
            value: jsonEncode({'models': <Object>[]}),
          ),
        );
    final legacy = await repo.read();
    expect(legacy.mcp.enabled, isFalse);
    expect(legacy.mcp.port, McpServerConfig.defaultPort);
    expect(legacy.mcp.accessMode, McpAccessMode.fullAccess);
    expect(legacy.mcp.tokenSecretRef, isNull);

    const savedMcp = McpServerConfig(
      enabled: true,
      port: 48888,
      accessMode: McpAccessMode.readOnly,
      tokenSecretRef: 'mcp-token-ref-1',
    );
    await repo.save(const AiSettings(mcp: savedMcp));
    final reloaded = await repo.read();
    expect(reloaded.mcp, savedMcp);
  });

  test('McpServerConfig 生成合法的 Codex TOML 与通用 MCP JSON 片段', () {
    const config = McpServerConfig(port: 47321);
    final toml = config.codexTomlSnippet('tok_abc');
    expect(toml, contains('[mcp_servers.pagashell]'));
    expect(toml, contains('url = "http://127.0.0.1:47321/mcp"'));
    expect(
      toml,
      contains('http_headers = { "Authorization" = "Bearer tok_abc" }'),
    );

    final decoded = _asMap(jsonDecode(config.mcpJsonSnippet('tok_abc')));
    final server = _asMap(_asMap(decoded['mcpServers'])['pagashell']);
    expect(server['type'], 'http');
    expect(server['url'], 'http://127.0.0.1:47321/mcp');
    expect(_asMap(server['headers'])['Authorization'], 'Bearer tok_abc');
  });

  group('McpServerController 端到端集成测试', () {
    late InMemorySecretStore secretStore;
    late InMemoryAiSettingsRepository aiSettingsRepo;
    late AiSettingsController aiSettings;
    late _InMemoryKnownHosts knownHosts;
    late Map<String, SshHostKey> hostKeys;
    late Map<String, _McpSshSession> liveSessions;
    late _ScriptedSshEngine sshEngine;
    late SessionController sessions;
    late HostController hosts;
    late GatewayController gateways;
    late IdentityController identities;
    late McpServerController mcp;
    late HttpClient client;

    const trustedHost = Host(
      id: 'h-prod',
      name: 'prod-db',
      hostname: '10.0.0.10',
      port: 22,
      username: 'ops',
      note: 'TOP-SECRET-NOTE-NEVER-EXPOSE',
      tags: ['prod', 'mysql'],
    );
    const untrustedHost = Host(
      id: 'h-new',
      name: 'new-node',
      hostname: '10.0.0.20',
      port: 22,
      username: 'root',
    );
    const changedKeyHost = Host(
      id: 'h-changed',
      name: 'changed-node',
      hostname: '10.0.0.30',
      port: 22,
      username: 'root',
    );
    const noCredsHost = Host(
      id: 'h-nocreds',
      name: 'no-creds',
      hostname: '10.0.0.40',
      port: 22,
      username: 'root',
    );
    const rdpHost = Host(
      id: 'h-rdp',
      name: 'win-box',
      hostname: '10.0.0.50',
      port: 3389,
      username: 'administrator',
      serviceType: ServiceType.rdp,
    );

    setUp(() async {
      secretStore = InMemorySecretStore();
      aiSettingsRepo = InMemoryAiSettingsRepository();
      aiSettings = AiSettingsController(
        repository: aiSettingsRepo,
        secretStore: secretStore,
      );
      await aiSettings.ready;
      final port = await _reserveFreeLoopbackPort();
      await aiSettings.saveMcpConfig(port: port);

      knownHosts = _InMemoryKnownHosts();
      knownHosts.trust(
        const SshHostKey(
          hostname: '10.0.0.10',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:trusted-prod-fp',
        ),
      );
      knownHosts.trust(
        const SshHostKey(
          hostname: '10.0.0.30',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:old-fp',
        ),
      );

      hostKeys = {
        'h-prod': const SshHostKey(
          hostname: '10.0.0.10',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:trusted-prod-fp',
        ),
        'h-new': const SshHostKey(
          hostname: '10.0.0.20',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:brand-new-fp',
        ),
        'h-changed': const SshHostKey(
          hostname: '10.0.0.30',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:tampered-fp',
        ),
      };

      liveSessions = {};
      sshEngine = _ScriptedSshEngine(hostKeys, (host, creds) {
        final s = _McpSshSession();
        s.files['/etc/my.cnf'] = '[mysqld]\nmax_connections = 100\n';
        s.onExec = (exec) {
          if (exec.command.contains('secret-leak')) {
            exec.emit(
              const SshExecEvent(
                SshExecEventKind.stdout,
                data: 'password=super-secret-value\nok\n',
              ),
            );
            exec.finish(code: 0);
          } else if (exec.command.startsWith('nginx -t')) {
            exec.emit(
              const SshExecEvent(
                SshExecEventKind.stdout,
                data: 'syntax is ok\n',
              ),
            );
            exec.finish(code: 0);
          } else {
            exec.emit(
              SshExecEvent(
                SshExecEventKind.stdout,
                data: 'ran:${exec.command}\n',
              ),
            );
            exec.finish(code: 0);
          }
        };
        liveSessions[host.id] = s;
        return s;
      });

      sessions = SessionController(engine: sshEngine, knownHosts: knownHosts);
      final hostRepo = InMemoryHostRepository();
      final folderRepo = InMemoryFolderRepository();
      final hostTree = InMemoryHostTreeRepository(
        folders: folderRepo,
        hosts: hostRepo,
      );
      final gwRepo = InMemoryHostRepository();
      final gwFolders = InMemoryFolderRepository();
      final gwTree = InMemoryHostTreeRepository(
        folders: gwFolders,
        hosts: gwRepo,
      );
      final idRepo = InMemoryIdentityRepository(
        services: hostRepo,
        gateways: gwRepo,
      );

      hosts = HostController(
        repository: hostRepo,
        secretStore: secretStore,
        treeRepository: hostTree,
        sessions: sessions,
      );
      gateways = GatewayController(
        repository: gwRepo,
        secretStore: secretStore,
        treeRepository: gwTree,
        services: hostRepo,
        sessions: sessions,
      );
      identities = IdentityController(
        repository: idRepo,
        secretStore: secretStore,
      );

      for (final h in [
        trustedHost,
        untrustedHost,
        changedKeyHost,
        noCredsHost,
        rdpHost,
      ]) {
        await hosts.save(h);
      }
      await hosts.savePassword('h-prod', 'prod-ssh-password-never-leak');
      await hosts.savePassword('h-new', 'new-node-password');
      await hosts.savePassword('h-changed', 'changed-node-password');

      mcp = McpServerController(
        aiSettings: aiSettings,
        sessions: sessions,
        hosts: hosts,
        gateways: gateways,
        identities: identities,
        knownHosts: knownHosts,
        serverFactory: const LocalMcpServerFactory(),
      );
      await mcp.ready;
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await mcp.stopForExit();
      await sessions.closeAll();
      mcp.onClose();
      sessions.onClose();
    });

    test('按需连接已信任主机、拒绝未信任/已变更指纹和无凭据/RDP主机、且绝不泄漏敏感信息', () async {
      expect(mcp.running.value, isFalse);
      await mcp.setEnabled(true);
      expect(mcp.running.value, isTrue);
      final token = mcp.token.value!;
      final port = mcp.boundPort.value!;

      final listHostsRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {'name': 'list_hosts', 'arguments': <String, Object>{}},
      );
      final hostsText = _toolText(listHostsRes);
      expect(hostsText, isNot(contains('TOP-SECRET-NOTE')));
      expect(hostsText, isNot(contains('prod-ssh-password')));
      expect(hostsText, isNot(contains('win-box')));
      final hostsData = _asList(_asMap(jsonDecode(hostsText))['hosts']);
      final prodEntry = hostsData
          .map(_asMap)
          .firstWhere((item) => item['host_id'] == 'h-prod');
      expect(prodEntry['hostKeyTrusted'], isTrue);
      expect(prodEntry['hasSavedCredentials'], isTrue);

      final untrustedRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-new'},
        },
      );
      expect(_isToolError(untrustedRes), isTrue);
      expect(_toolText(untrustedRes), contains('host_key_verification_failed'));
      expect(sessions.sessions, isEmpty);

      final changedRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-changed'},
        },
      );
      expect(_isToolError(changedRes), isTrue);
      expect(_toolText(changedRes), contains('host_key_verification_failed'));
      expect(sessions.sessions, isEmpty);

      final noCredsRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-nocreds'},
        },
      );
      expect(_isToolError(noCredsRes), isTrue);

      final rdpRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-rdp'},
        },
      );
      expect(_isToolError(rdpRes), isTrue);

      final connectedRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'name': 'prod-db'},
        },
      );
      expect(_isToolError(connectedRes), isFalse);
      final connected = _asMap(jsonDecode(_toolText(connectedRes)));
      expect(connected['reused'], isFalse);
      final sessionId = connected['session_id'] as String;
      expect(sessions.sessions.single.phase, SessionPhase.ready);

      final beforeCalls = sshEngine.connectCalls;
      final reusedRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-prod'},
        },
      );
      final reused = _asMap(jsonDecode(_toolText(reusedRes)));
      expect(reused['reused'], isTrue);
      expect(reused['session_id'], sessionId);
      expect(sshEngine.connectCalls, beforeCalls);
    });

    test('完全放行与只读模式隔离、配置编辑+备份+校验+回滚、脱敏和令牌轮换', () async {
      await mcp.setEnabled(true);
      final token = mcp.token.value!;
      final port = mcp.boundPort.value!;

      final conn = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'connect_host',
          'arguments': {'host_id': 'h-prod'},
        },
      );
      final sessionId =
          _asMap(jsonDecode(_toolText(conn)))['session_id'] as String;

      final profileRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'inspect_server_profile',
          'arguments': {'session_id': sessionId},
        },
      );
      expect(_isToolError(profileRes), isFalse);
      expect(_toolText(profileRes), contains('"cpuCores":8'));

      final readRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'read_remote_file',
          'arguments': {'session_id': sessionId, 'path': '/etc/my.cnf'},
        },
      );
      final readData = _asMap(jsonDecode(_toolText(readRes)));
      final originalSha = readData['sha256'] as String;

      final conflictRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'edit_remote_file',
          'arguments': {
            'session_id': sessionId,
            'path': '/etc/my.cnf',
            'purpose': 'Bump max_connections',
            'expected_sha256': 'stale-sha',
            'edits': [
              {
                'oldText': 'max_connections = 100',
                'newText': 'max_connections = 300',
              },
            ],
          },
        },
      );
      expect(_isToolError(conflictRes), isTrue);
      expect(_toolText(conflictRes), contains('conflict'));

      final secretEdit = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'edit_remote_file',
          'arguments': {
            'session_id': sessionId,
            'path': '/etc/my.cnf',
            'purpose': 'Bad secret write',
            'edits': [
              {
                'oldText': 'max_connections = 100',
                'newText': 'password = my-db-secret',
              },
            ],
          },
        },
      );
      expect(_isToolError(secretEdit), isTrue);

      final badCmd = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'exec_ssh_command',
          'arguments': {
            'session_id': sessionId,
            'command': 'PGPASSWORD=secret psql -c "select 1"',
          },
        },
      );
      expect(_isToolError(badCmd), isTrue);

      final editRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'edit_remote_file',
          'arguments': {
            'session_id': sessionId,
            'path': '/etc/my.cnf',
            'purpose': 'Tune MySQL max_connections',
            'expected_sha256': originalSha,
            'validation_command': 'nginx -t',
            'edits': [
              {
                'oldText': 'max_connections = 100',
                'newText': 'max_connections = 300',
              },
            ],
          },
        },
      );
      expect(_isToolError(editRes), isFalse);
      final editData = _asMap(jsonDecode(_toolText(editRes)));
      expect(editData['applied'], isTrue);
      expect(editData['backupPath'], isNotNull);
      expect(editData['validationPassed'], isTrue);
      expect(
        liveSessions['h-prod']!.files['/etc/my.cnf'],
        contains('max_connections = 300'),
      );

      final rollbackRes = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'rollback_remote_file',
          'arguments': {
            'session_id': sessionId,
            'path': '/etc/my.cnf',
            'current_sha256': editData['sha256'],
            'backup_path': editData['backupPath'],
            'backup_sha256': editData['previousSha256'],
          },
        },
      );
      expect(_isToolError(rollbackRes), isFalse);
      expect(
        liveSessions['h-prod']!.files['/etc/my.cnf'],
        contains('max_connections = 100'),
      );

      final leakCheck = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'exec_ssh_command',
          'arguments': {'session_id': sessionId, 'command': 'echo secret-leak'},
        },
      );
      final leakText = _toolText(leakCheck);
      expect(leakText, isNot(contains('super-secret-value')));
      expect(leakText, contains('[redacted]'));

      await mcp.setAccessMode(McpAccessMode.readOnly);
      final roToolsRes = await _mcpCall(client, port, token, 'tools/list');
      final roNames = _asList(_asMap(roToolsRes['result'])['tools'])
          .map((t) => _asMap(t)['name'])
          .toSet();
      expect(roNames, contains('inspect_server_profile'));
      expect(roNames, contains('exec_ssh_command'));
      expect(roNames, isNot(contains('edit_remote_file')));
      expect(roNames, isNot(contains('rollback_remote_file')));
      expect(roNames, isNot(contains('send_terminal_command')));

      final blockedEdit = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'edit_remote_file',
          'arguments': {
            'session_id': sessionId,
            'path': '/etc/my.cnf',
            'purpose': 'Blocked in read-only',
            'content': 'x',
          },
        },
      );
      expect(_isToolError(blockedEdit), isTrue);

      final blockedExec = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'exec_ssh_command',
          'arguments': {
            'session_id': sessionId,
            'command': 'systemctl restart mysql',
          },
        },
      );
      expect(_isToolError(blockedExec), isTrue);
      expect(mcp.auditLogs.first.status, McpAuditStatus.denied);

      final allowedExec = await _mcpCall(
        client,
        port,
        token,
        'tools/call',
        params: {
          'name': 'exec_ssh_command',
          'arguments': {'session_id': sessionId, 'command': 'uname -a'},
        },
      );
      expect(_isToolError(allowedExec), isFalse);

      final oldRef = aiSettings.state.value.mcp.tokenSecretRef!;
      final nextToken = await mcp.rotateToken();
      expect(nextToken, isNot(token));
      expect(await secretStore.read(oldRef), isNull);

      final pingWithNew = await _mcpCall(client, port, nextToken, 'ping');
      expect(pingWithNew['result'], isA<Map<String, dynamic>>());

      final newPort = await _reserveFreeLoopbackPort();
      await mcp.updatePort(newPort);
      expect(mcp.boundPort.value, newPort);
      final pingOnNewPort = await _mcpCall(client, newPort, nextToken, 'ping');
      expect(pingOnNewPort['result'], isA<Map<String, dynamic>>());
    });
  });
}
