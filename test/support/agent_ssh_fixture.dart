import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/agent_ops.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

class AgentExecFixture implements SshExecHandle {
  AgentExecFixture(this.command, this.timeoutSecs);
  final String command;
  final int timeoutSecs;
  final _events = StreamController<SshExecEvent>();
  int cancels = 0;

  @override
  Stream<SshExecEvent> get events => _events.stream;

  void emit(SshExecEvent event) => _events.add(event);

  void finish({int? code, bool timedOut = false, bool cancelled = false}) {
    if (_events.isClosed) return;
    emit(
      SshExecEvent(
        SshExecEventKind.exit,
        exitCode: code,
        timedOut: timedOut,
        cancelled: cancelled,
      ),
    );
    unawaited(_events.close());
  }

  @override
  Future<void> cancel() async {
    cancels++;
    finish(cancelled: true);
  }
}

class AgentSshFixture extends Fake
    implements
        SshEngineSession,
        SshExecSource,
        RemoteFileOpsSource,
        ServerProfileSource,
        ProcessManagerSource,
        NetworkPortsSource,
        DockerManagerSource {
  final execs = <AgentExecFixture>[];
  void Function(AgentExecFixture)? onExec;
  final files = <String, String>{};
  final backups = <String, String>{};
  final reads = <(String, bool)>[];
  final writes = <(String, bool)>[];
  final restores = <String>[];
  RemoteFileError? readError, unprivilegedReadError, writeError;
  int profileReads = 0;

  String fingerprint(String text) => 'fixture:$text';

  @override
  SshExecHandle startExec(String command, {required int timeoutSecs}) {
    final exec = AgentExecFixture(command, timeoutSecs);
    execs.add(exec);
    onExec?.call(exec);
    return exec;
  }

  @override
  Future<RemoteTextSnapshot> readRemoteText(
    String path, {
    required bool useSudo,
  }) async {
    reads.add((path, useSudo));
    if (readError case final error?) throw RemoteFileOpsException(error);
    if (unprivilegedReadError case final error? when !useSudo) {
      throw RemoteFileOpsException(error);
    }
    final text = files[path];
    if (text == null) {
      throw const RemoteFileOpsException(RemoteFileError.notFound);
    }
    return RemoteTextSnapshot(
      text: text,
      sha256: fingerprint(text),
      sizeBytes: utf8.encode(text).length,
      usedSudo: useSudo,
    );
  }

  @override
  Future<RemoteWriteResult> writeRemoteText(
    String path,
    String content, {
    required String? expectedSha256,
    required bool createIfMissing,
    required bool createParentDirs,
    required String backupSuffix,
    required bool useSudo,
  }) async {
    if (writeError case final error?) throw RemoteFileOpsException(error);
    final old = files[path];
    if (old != null && fingerprint(old) != expectedSha256 ||
        old == null && (!createIfMissing || expectedSha256 != null)) {
      throw const RemoteFileOpsException(RemoteFileError.conflict);
    }
    writes.add((path, useSudo));
    final backup = old == null ? null : '$path.pagashell.bak.$backupSuffix';
    if (backup != null) backups[backup] = old!;
    files[path] = content;
    return RemoteWriteResult(
      sha256: fingerprint(content),
      backupPath: backup,
      createdNew: old == null,
      usedSudo: useSudo,
    );
  }

  @override
  Future<void> restoreRemoteBackup(
    String path, {
    required String? backupPath,
    required String currentSha256,
    required String? backupSha256,
    required bool useSudo,
  }) async {
    final current = files[path];
    final old = backups[backupPath];
    if (current == null ||
        fingerprint(current) != currentSha256 ||
        backupPath != null &&
            (old == null || fingerprint(old) != backupSha256)) {
      throw const RemoteFileOpsException(RemoteFileError.conflict);
    }
    restores.add(path);
    if (old == null) {
      files.remove(path);
    } else {
      files[path] = old;
    }
  }

  @override
  Future<ServerProfile> readServerProfile() async {
    profileReads++;
    return const ServerProfile(system: 'Linux', cpuCores: 8);
  }

  @override
  Future<ProcessSnapshot> readProcesses() async => const ProcessSnapshot(
    sampledAtSeconds: 12,
    memoryTotal: 4096,
    processes: [
      RemoteProcess(
        pid: 3,
        user: 'db',
        name: 'mysqld',
        startedAt: '',
        cpuPercent: 5,
        cpuSeconds: 1,
        memoryBytes: 200,
      ),
      RemoteProcess(
        pid: 8,
        user: 'svc',
        name: 'nginx',
        startedAt: '',
        cpuPercent: 15,
        cpuSeconds: 2,
        memoryBytes: 100,
      ),
    ],
  );

  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() async =>
      const NetworkPortsSnapshot(
        ports: [
          ListeningNetworkPort(
            protocol: NetworkPortProtocol.tcp,
            port: 5432,
            addresses: [],
            processes: [],
          ),
        ],
        limited: true,
      );

  @override
  Future<List<DockerResource>> readDockerResources(
    DockerResourceKind kind,
  ) async => [
    DockerResource(
      kind: kind,
      id: 'nginx-id',
      name: 'nginx',
      fields: {DockerField.health: 'healthy'},
    ),
  ];

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async =>
      DockerDetails(resource);

  @override
  Future<List<SftpDirEntry>> listDir(String path) async => const [
    SftpDirEntry(name: 'nginx.conf', isDir: false, size: 50),
  ];

  @override
  Future<void> close() async {
    for (final exec in execs) {
      exec.finish(cancelled: true);
    }
  }
}
