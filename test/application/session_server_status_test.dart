import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/server_status_connection.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/docker_fixture.dart';
import '../support/fake_sftp_session.dart';
import '../support/network_ports_fixture.dart';
import '../support/process_fixture.dart';
import '../support/server_status_fixture.dart';

const _host = Host(id: 'server', name: 'Server', hostname: 'server.test');
const _key = SshHostKey(
  hostname: 'server.test',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:trusted',
);
const _gatewayKey = SshHostKey(
  hostname: 'jump.test',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:gateway',
);
const _credentials = SshCredentials.privateKey(
  'test-only-key',
  username: 'rocky',
  passphrase: 'test-only-passphrase',
);
const _gateway = SshGateway(
  host: Host(id: 'jump', name: 'Jump', hostname: 'jump.test'),
  credentials: SshCredentials.password('test-only-gateway', username: 'jump'),
);

class _KnownHosts implements KnownHostRepository {
  final keys = <String, SshHostKey>{
    _key.hostname: _key,
    _gatewayKey.hostname: _gatewayKey,
  };
  int trustWrites = 0;

  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async {
    final key = keys[hostname];
    return key?.port == port && key?.protocol == protocol ? key : null;
  }

  @override
  Future<bool> trustIfAbsent(SshHostKey key) async {
    trustWrites++;
    final previous = keys.putIfAbsent(key.hostname, () => key);
    return previous.matches(key);
  }

  @override
  Future<bool> removeIfMatches(SshHostKey key) async {
    if (keys[key.hostname]?.matches(key) != true) return false;
    keys.remove(key.hostname);
    return true;
  }
}

class _StatusSession extends FakeSftpSession
    implements
        ServerStatusSource,
        ProcessManagerSource,
        NetworkPortsSource,
        DockerManagerSource,
        DockerContainerActions,
        DockerImageActions,
        DockerComposeActions {
  final actions = <(DockerResource, DockerContainerAction, String?, bool)>[];
  final imageActions = <(DockerImageAction, DockerResource?)>[];
  final composeActions = <(DockerResource, DockerComposeAction)>[];
  Completer<DockerActionResult>? actionGate;
  int portReads = 0;
  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() async {
    portReads++;
    return networkPortsFixture();
  }

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) async {
    composeActions.add((project, action));
    return actionGate?.future ?? const DockerActionResult();
  }

  @override
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) async {
    imageActions.add((action, image));
    return actionGate?.future ?? const DockerActionResult();
  }

  @override
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource resource,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) async {
    actions.add((resource, action, targetImage, forcePull));
    return actionGate?.future ?? const DockerActionResult();
  }

  final dockerReads = <DockerResourceKind>[];
  final dockerDetailReads = <DockerResource>[];
  Object? dockerFailure;
  Completer<List<DockerResource>>? dockerGate;
  Completer<void>? closingGate;

  @override
  Future<List<DockerResource>> readDockerResources(
    DockerResourceKind kind,
  ) async {
    dockerReads.add(kind);
    if (dockerFailure case final failure?) throw failure;
    if (dockerGate case final gate?) return gate.future;
    return [dockerResource(kind: kind)];
  }

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async {
    dockerDetailReads.add(resource);
    if (dockerFailure case final failure?) throw failure;
    return dockerDetails(resource);
  }

  int samples = 0;
  Object? sampleFailure;
  int processReads = 0;
  final terminations = <RemoteProcess>[];
  Object? terminationFailure;
  final detailsRead = <RemoteProcess>[];
  Object? detailsFailure;

  @override
  Future<void> close() async {
    await super.close();
    await closingGate?.future;
  }

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) async {
    detailsRead.add(process);
    if (detailsFailure case final failure?) throw failure;
    return processDetails(process: process);
  }

  @override
  Future<ProcessSnapshot> readProcesses() async {
    processReads++;
    return processSnapshot();
  }

  @override
  Future<void> terminateProcess(RemoteProcess process) async {
    terminations.add(process);
    if (terminationFailure case final failure?) throw failure;
  }

  @override
  Future<ServerStatusSample> readServerStatus() async {
    if (sampleFailure case final failure?) throw failure;
    samples++;
    return statusSample(uptime: 1000 + samples * 3);
  }
}

class _Attempt {
  _Attempt(this.host, this.credentials, this.gateway);
  final Host host;
  final SshCredentials credentials;
  final SshGateway? gateway;
  bool cancelled = false;
}

class _Engine implements SshEngine {
  final attempts = <_Attempt>[];
  final sessions = <FakeSftpSession>[];
  final presentedKeys = <String, SshHostKey>{
    _key.hostname: _key,
    _gatewayKey.hostname: _gatewayKey,
  };
  Completer<void>? nextConnection;
  Object? nextFailure;
  bool supportsStatus = true;
  int authentications = 0;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final attempt = _Attempt(host, credentials, gateway);
    attempts.add(attempt);
    unawaited(cancelled?.then((_) => attempt.cancelled = true));
    final gate = nextConnection;
    nextConnection = null;
    for (final endpoint in [if (gateway != null) gateway.host, host]) {
      if (verifyHostKey == null ||
          !await verifyHostKey(presentedKeys[endpoint.hostname]!)) {
        throw const SshEngineException('主机密钥未获信任，已取消连接');
      }
    }
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) throw failure;
    // 故意允许取消后迟到返回，验证调用方仍会回收引擎句柄。
    await gate?.future;
    authentications++;
    final session = supportsStatus ? _StatusSession() : FakeSftpSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  test('端口与进程和服务状态复用后台连接，端口采集不启动 shell', () async {
    final session = _StatusSession();
    var connects = 0;
    final source = ServerStatusConnection(
      connect: (_) async {
        connects++;
        return session;
      },
    );
    final ports = await source.readNetworkPorts();
    await source.readProcesses();
    await source.readServerStatus();
    expect(connects, 1);
    expect(ports.ports, hasLength(3));
    expect(session.portReads, 1);
    expect(session.shellStarts, 0);
    await source.close();
    expect(session.closes, 1);
  });

  testWidgets('端口查询的总超时覆盖握手，迟到旧连接被释放，新请求重新连接', (tester) async {
    final gate = Completer<SshEngineSession>();
    final retry = _StatusSession();
    var connects = 0;
    final source = ServerStatusConnection(
      networkPortsTimeout: const Duration(seconds: 1),
      connect: (_) => connects++ == 0 ? gate.future : Future.value(retry),
    );
    final failure = expectLater(
      source.readNetworkPorts(),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          '网络端口查询超时，请重试',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await failure;
    final late = _StatusSession();
    gate.complete(late);
    await tester.pump();
    expect(late.closes, 1);
    expect((await source.readNetworkPorts()).ports, hasLength(3));
    expect(connects, 2);
    await source.close();
    expect(retry.closes, 1);
  });
  test('编排重建使用独立连接，面板关闭不打断已提交操作，完成后释放连接', () async {
    final sampler = _StatusSession();
    final owned = _StatusSession()
      ..actionGate = Completer<DockerActionResult>();
    var connections = 0;
    final source = ServerStatusConnection(
      connect: (_) async => connections++ == 0 ? sampler : owned,
    );
    await source.readDockerResources(DockerResourceKind.compose);
    final project = dockerResource(kind: DockerResourceKind.compose);
    final operation = source.runDockerComposeAction(
      project,
      DockerComposeAction.rebuild,
    );
    await Future<void>.delayed(Duration.zero);
    expect(connections, 2);
    expect(owned.composeActions.single, (project, DockerComposeAction.rebuild));
    expect(owned.shellStarts, 0);
    await source.close();
    expect(sampler.closes, 1);
    expect(owned.closes, 0);
    owned.actionGate!.complete(const DockerActionResult());
    await operation;
    expect(owned.closes, 1);
  });
  test('镜像删除和无标签清理独占操作连接，采集连接关闭后仍完成并回收', () async {
    for (final kind in DockerImageAction.values) {
      final sampler = _StatusSession();
      final owned = _StatusSession()
        ..actionGate = Completer<DockerActionResult>();
      var connections = 0;
      final source = ServerStatusConnection(
        connect: (_) async => connections++ == 0 ? sampler : owned,
      );
      await source.readDockerResources(DockerResourceKind.image);
      final image = kind == DockerImageAction.delete
          ? dockerImage(hex: 'b')
          : null;
      final operation = source.runDockerImageAction(kind, image: image);
      await Future<void>.delayed(Duration.zero);
      expect(owned.imageActions.single, (kind, image));
      expect(connections, 2);
      expect(owned.shellStarts, 0);
      await source.close();
      expect(sampler.closes, 1);
      expect(owned.closes, 0);
      owned.actionGate!.complete(const DockerActionResult());
      await operation;
      expect(owned.closes, 1);
    }
  });

  test('容器变更使用独立连接，关闭采集连接不打断已提交的升级', () async {
    final sampler = _StatusSession();
    final action = _StatusSession()
      ..actionGate = Completer<DockerActionResult>();
    var connections = 0;
    final source = ServerStatusConnection(
      connect: (_) async => connections++ == 0 ? sampler : action,
    );
    await source.readDockerResources(DockerResourceKind.container);
    final resource = dockerResource();
    final request = source.runDockerContainerAction(
      resource,
      DockerContainerAction.upgrade,
      targetImage: 'nginx:new',
      forcePull: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(connections, 2);
    expect(action.actions.single, (
      resource,
      DockerContainerAction.upgrade,
      'nginx:new',
      true,
    ));
    expect(action.shellStarts, 0);
    expect(sampler.shellStarts, 0);
    await source.close();
    expect(sampler.closes, 1);
    expect(action.closes, 0);
    action.actionGate!.complete(const DockerActionResult());
    await request;
    expect(action.closes, 1);
  });

  testWidgets('变更连接握手超时后回收迟到连接，不执行写操作', (tester) async {
    final gate = Completer<SshEngineSession>();
    final source = ServerStatusConnection(
      connect: (_) => gate.future,
      dockerTimeout: const Duration(seconds: 1),
    );
    final failure = expectLater(
      source.runDockerContainerAction(
        dockerResource(),
        DockerContainerAction.delete,
      ),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 操作连接超时，请重试',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await failure;
    final late = _StatusSession();
    gate.complete(late);
    await tester.pump();
    expect(late.closes, 1);
    expect(late.actions, isEmpty);
    await source.close();
  });

  testWidgets('Docker 建立后台连接也有总超时，取消旧握手，迟到连接不替换重试连接', (tester) async {
    final gate = Completer<SshEngineSession>();
    final stale = _StatusSession();
    final fresh = _StatusSession();
    var connections = 0;
    var cancelled = false;
    final source = ServerStatusConnection(
      connect: (cancellation) {
        connections++;
        if (connections == 1) {
          unawaited(cancellation.then((_) => cancelled = true));
          return gate.future;
        }
        return Future<SshEngineSession>.value(fresh);
      },
    );
    addTearDown(source.close);
    final rejected = expectLater(
      source.readDockerResources(DockerResourceKind.container),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 查询超时，请重试',
        ),
      ),
    );
    await tester.pump(dockerQueryTimeout);
    await rejected;
    expect(cancelled, isTrue);
    await source.readDockerResources(DockerResourceKind.image);
    gate.complete(stale);
    await tester.pump();
    expect(stale.closes, 1);
    expect(stale.dockerReads, isEmpty);
    expect(fresh.closes, 0);
    await source.readDockerResources(DockerResourceKind.volume);
    expect(connections, 2);
    expect(fresh.dockerReads, [
      DockerResourceKind.image,
      DockerResourceKind.volume,
    ]);
  });

  testWidgets('Docker 命令超时不等待连接清理，重连后忽略旧连接的迟到错误', (tester) async {
    final gate = Completer<List<DockerResource>>();
    final closing = Completer<void>();
    final stale = _StatusSession()
      ..dockerGate = gate
      ..closingGate = closing;
    final fresh = _StatusSession();
    var connections = 0;
    final source = ServerStatusConnection(
      connect: (_) async {
        connections++;
        return connections == 1 ? stale : fresh;
      },
    );
    addTearDown(source.close);
    final rejected = expectLater(
      source.readDockerResources(DockerResourceKind.container),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 查询超时，请重试',
        ),
      ),
    );
    await tester.pump();
    expect(stale.dockerReads, [DockerResourceKind.container]);
    await tester.pump(dockerQueryTimeout);
    await rejected;
    expect(stale.closes, 1);
    await source.readDockerResources(DockerResourceKind.network);
    gate.completeError(const SshEngineException('Docker 管理连接已关闭'));
    closing.complete();
    await tester.pump();
    await source.readDockerResources(DockerResourceKind.volume);
    expect(connections, 2);
    expect(fresh.closes, 0);
    expect(fresh.dockerReads, [
      DockerResourceKind.network,
      DockerResourceKind.volume,
    ]);
  });

  test('Docker 原生超时会释放旧后台连接，下一请求可重连', () async {
    final stale = _StatusSession()
      ..dockerFailure = const SshEngineException('Docker 查询超时，请重试');
    final fresh = _StatusSession();
    var connections = 0;
    final source = ServerStatusConnection(
      connect: (_) async => ++connections == 1 ? stale : fresh,
    );
    await expectLater(
      source.readDockerResources(DockerResourceKind.container),
      throwsA(isA<SshEngineException>()),
    );
    await source.readDockerResources(DockerResourceKind.container);
    expect(connections, 2);
    expect(stale.closes, 1);
    await source.close();
    expect(fresh.closes, 1);
  });

  test('Docker 与服务状态、进程共用页签后台连接，Docker 错误不重连，分屏及关闭保留生命周期', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final id = await controller.open(_host, _credentials, gateway: _gateway);
    final docker = controller.dockerManagerSource(id)!;
    expect(engine.attempts, hasLength(1));
    final resources = await docker.readDockerResources(
      DockerResourceKind.container,
    );
    final background = engine.sessions.last as _StatusSession;
    expect(background.shellStarts, 0);
    expect(controller.serverStatusSource(id), same(docker));
    expect(controller.processManagerSource(id), same(docker));
    expect(
      (await docker.readDockerDetails(resources.single)).resource.id,
      resources.single.id,
    );
    for (final message in [
      'Docker 未运行',
      '没有权限获取 Docker 信息',
      'Docker 资源可能已移除，请刷新后重试',
    ]) {
      background.dockerFailure = SshEngineException(message);
      await expectLater(
        docker.readDockerResources(DockerResourceKind.volume),
        throwsA(isA<SshEngineException>()),
      );
      await expectLater(
        docker.readDockerDetails(resources.single),
        throwsA(isA<SshEngineException>()),
      );
    }
    await controller.serverStatusSource(id)!.readServerStatus();
    await controller.processManagerSource(id)!.readProcesses();
    expect(engine.attempts, hasLength(2));
    expect(background.closes, 0);
    final second = (await controller.splitTerminal(
      id,
      SessionSplitAxis.horizontal,
    ))!;
    expect(controller.dockerManagerSource(id), same(docker));
    await controller.close(id);
    expect(controller.dockerManagerSource(id), same(docker));
    expect(background.closes, 0);
    await controller.close(second);
    expect(background.closes, 1);
    final reads = background.dockerReads.length;
    await expectLater(
      docker.readDockerResources(DockerResourceKind.container),
      throwsA(isA<SshEngineException>()),
    );
    expect(background.dockerReads, hasLength(reads));
    controller.onClose();
  });

  test('进程管理与服务状态复用后台连接，TERM 失败不重发或重建，关闭后不能操作', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final id = await controller.open(_host, _credentials, gateway: _gateway);
    final source = controller.processManagerSource(id)!;
    expect(engine.attempts, hasLength(1));
    await source.readProcesses();
    final status = controller.serverStatusSource(id)!;
    expect(source, same(status));
    await status.readServerStatus();
    final background = engine.sessions.last as _StatusSession;
    expect(engine.attempts, hasLength(2));
    expect(engine.attempts.last.credentials, same(_credentials));
    expect(engine.attempts.last.gateway, same(_gateway));
    expect(background.shellStarts, 0);
    final process = remoteProcess();
    expect((await source.readProcessDetails(process)).process, same(process));
    expect(background.detailsRead, [process]);
    background.detailsFailure = const SshEngineException('进程已退出，请刷新列表');
    await expectLater(
      source.readProcessDetails(process),
      throwsA(isA<SshEngineException>()),
    );
    background.terminationFailure = const SshEngineException(
      '无法结束进程，进程可能已退出或权限不足',
    );
    await expectLater(
      source.terminateProcess(process),
      throwsA(isA<SshEngineException>()),
    );
    await source.readProcesses();
    expect(background.terminations, [process]);
    expect(background.closes, 0);
    expect(engine.attempts, hasLength(2));
    controller.onClose();
    await Future<void>.delayed(Duration.zero);
    expect(background.closes, 1);
    await expectLater(
      source.terminateProcess(process),
      throwsA(isA<SshEngineException>()),
    );
    expect(background.terminations, [process]);
    await expectLater(
      source.readProcessDetails(process),
      throwsA(isA<SshEngineException>()),
    );
    expect(background.detailsRead, hasLength(2));
  });

  test('状态连接按页签懒创建，复用登录信息和网关，不启动 shell', () async {
    final engine = _Engine();
    final knownHosts = _KnownHosts();
    final controller = SessionController(
      engine: engine,
      knownHosts: knownHosts,
    );
    final host = _host.copyWith(gatewayId: _gateway.host.id);
    final first = await controller.open(host, _credentials, gateway: _gateway);
    final source = controller.serverStatusSource(first)!;
    final visible = controller.sessions.single;
    expect(engine.attempts, hasLength(1));
    expect(controller.serverStatusSource(first), same(source));

    await source.readServerStatus();
    final background = engine.sessions.last as _StatusSession;
    expect(engine.attempts, hasLength(2));
    expect(engine.attempts.last.host, same(host));
    expect(engine.attempts.last.credentials, same(_credentials));
    expect(engine.attempts.last.gateway, same(_gateway));
    expect(engine.sessions.map((session) => session.shellStarts), [1, 0]);
    expect(controller.sessions.single, same(visible));
    expect(controller.sessions.single.address, 'rocky@server.test');
    expect(controller.tabs, hasLength(1));

    final second = (await controller.splitTerminal(
      first,
      SessionSplitAxis.horizontal,
    ))!;
    controller.activate(first);
    expect(controller.serverStatusSource(first), same(source));
    controller.activate(second);
    expect(controller.serverStatusSource(first), same(source));
    await source.readServerStatus();
    expect(background.samples, 2);
    expect(engine.attempts, hasLength(3));
    expect(knownHosts.trustWrites, 0);

    await controller.close(first);
    expect(controller.tabs.single.id, first);
    expect(controller.serverStatusSource(first), same(source));
    expect(background.closes, 0);
    await source.readServerStatus();
    expect(background.samples, 3);
    await controller.close(second);
    expect(background.closes, 1);
    expect(controller.serverStatusSource(first), isNull);
    await expectLater(
      source.readServerStatus(),
      throwsA(isA<SshEngineException>()),
    );
    await controller.closeAll();
    expect(engine.sessions.map((session) => session.closes), [1, 1, 1]);
  });

  test('收起未采样的状态源不会额外建立连接，无采集能力的终端不创建状态源', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final first = await controller.open(_host, _credentials);
    expect(controller.serverStatusSource(first), isNotNull);
    expect(engine.attempts, hasLength(1));
    await controller.closeAll();
    expect(engine.attempts, hasLength(1));
    engine.supportsStatus = false;
    final second = await controller.open(_host, _credentials);
    expect(controller.serverStatusSource(second), isNull);
    await controller.closeAll();
  });

  test('不同页签各有独立状态连接，关闭一个不影响另一个，closeAll 完整清理', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final first = await controller.open(_host, _credentials);
    final firstSource = controller.serverStatusSource(first)!;
    await firstSource.readServerStatus();
    final firstBackground = engine.sessions.last;
    final second = await controller.open(_host, _credentials);
    final secondSource = controller.serverStatusSource(second)!;
    expect(secondSource, isNot(same(firstSource)));
    await secondSource.readServerStatus();
    final secondBackground = engine.sessions.last;
    expect(engine.sessions.map((session) => session.shellStarts), [1, 0, 1, 0]);
    await controller.close(first);
    expect(firstBackground.closes, 1);
    expect(secondBackground.closes, 0);
    await secondSource.readServerStatus();
    await controller.closeAll();
    expect(engine.sessions.every((session) => session.closes == 1), isTrue);
  });

  test('采集或连接失败仅重连状态源，终端保持 ready 且无需重开 shell', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final id = await controller.open(_host, _credentials);
    final visible = controller.sessions.single;
    final source = controller.serverStatusSource(id)!;
    await source.readServerStatus();
    final failed = engine.sessions.last as _StatusSession;
    failed.sampleFailure = const SshEngineException('服务状态采集超时');
    await expectLater(
      source.readServerStatus(),
      throwsA(isA<SshEngineException>()),
    );
    expect(failed.closes, 1);
    engine.nextFailure = const SshEngineException('连接失败');
    await expectLater(
      source.readServerStatus(),
      throwsA(isA<SshEngineException>()),
    );
    expect(controller.sessions.single, same(visible));
    expect(controller.sessions.single.phase, SessionPhase.ready);
    await source.readServerStatus();
    expect(engine.attempts, hasLength(4));
    expect(engine.sessions.map((session) => session.shellStarts), [1, 0, 0]);
    await controller.closeAll();
    expect(engine.sessions.every((session) => session.closes == 1), isTrue);
  });

  for (final endpoint in [_key, _gatewayKey]) {
    for (final changed in [false, true]) {
      test(
        '${endpoint.hostname} 指纹${changed ? '变更' : '被移除'}时拒绝后台认证，不改变终端状态',
        () async {
          final engine = _Engine();
          final knownHosts = _KnownHosts();
          final controller = SessionController(
            engine: engine,
            knownHosts: knownHosts,
          );
          final id = await controller.open(
            _host.copyWith(gatewayId: _gateway.host.id),
            _credentials,
            gateway: _gateway,
          );
          final visible = controller.sessions.single;
          if (changed) {
            engine.presentedKeys[endpoint.hostname] = SshHostKey(
              hostname: endpoint.hostname,
              port: endpoint.port,
              keyType: endpoint.keyType,
              fingerprint: 'SHA256:changed',
            );
          } else {
            knownHosts.keys.remove(endpoint.hostname);
          }
          await expectLater(
            controller.serverStatusSource(id)!.readServerStatus(),
            throwsA(
              changed
                  ? isA<HostKeyChangedException>()
                  : isA<SshEngineException>(),
            ),
          );
          expect(engine.authentications, 1);
          expect(knownHosts.trustWrites, 0);
          expect(controller.sessions.single, same(visible));
          expect(controller.sessions.single.phase, SessionPhase.ready);
          expect(controller.sessions.single.hostKeyReview, isNull);
          await controller.closeAll();
        },
      );
    }
  }

  for (final dispose in [false, true]) {
    test('${dispose ? '销毁控制器' : '关闭页签'}会取消建立中的状态连接，迟到句柄只释放一次', () async {
      final engine = _Engine();
      final controller = SessionController(
        engine: engine,
        knownHosts: _KnownHosts(),
      );
      final id = await controller.open(_host, _credentials);
      final source = controller.serverStatusSource(id)!;
      final gate = engine.nextConnection = Completer<void>();
      final result = expectLater(
        source.readServerStatus(),
        throwsA(isA<SshEngineException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engine.attempts, hasLength(2));
      if (dispose) {
        controller.onClose();
      } else {
        await controller.close(id);
      }
      await Future<void>.delayed(Duration.zero);
      expect(engine.attempts.last.cancelled, isTrue);
      gate.complete();
      await result;
      expect(engine.sessions.last.shellStarts, 0);
      expect(engine.sessions.last.closes, 1);
      expect((engine.sessions.last as _StatusSession).samples, 0);
    });
  }

  test('控制器销毁释放已连接的状态资源，重复关闭不会重复释放', () async {
    final engine = _Engine();
    final controller = SessionController(
      engine: engine,
      knownHosts: _KnownHosts(),
    );
    final id = await controller.open(_host, _credentials);
    final source = controller.serverStatusSource(id)!;
    await source.readServerStatus();
    controller.onClose();
    await Future<void>.delayed(Duration.zero);
    expect(engine.sessions.map((session) => session.closes), [1, 1]);
    await expectLater(
      source.readServerStatus(),
      throwsA(isA<SshEngineException>()),
    );
    expect(engine.attempts, hasLength(2));
  });
}
