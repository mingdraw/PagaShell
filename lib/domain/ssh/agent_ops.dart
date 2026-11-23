enum SshExecEventKind { stdout, stderr, exit }

class SshExecEvent {
  const SshExecEvent(
    this.kind, {
    this.data = '',
    this.exitCode,
    this.timedOut = false,
    this.cancelled = false,
    this.truncated = false,
  });

  final SshExecEventKind kind;
  final String data;
  final int? exitCode;
  final bool timedOut;
  final bool cancelled;
  final bool truncated;
}

abstract interface class SshExecHandle {
  Stream<SshExecEvent> get events;
  Future<void> cancel();
}

abstract interface class SshExecSource {
  SshExecHandle startExec(String command, {required int timeoutSecs});
}

abstract interface class ServerProfileSource {
  Future<ServerProfile> readServerProfile();
}

class ServerProfile {
  const ServerProfile({
    required this.system,
    this.kernel,
    this.architecture,
    this.distribution,
    this.distributionVersion,
    this.distributionId,
    this.virtualization,
    this.initSystem,
    this.user,
    this.privilege,
    this.packageManagers = const [],
    this.cpuCores,
    this.memoryBytes,
    this.memoryAvailableBytes,
    this.swapBytes,
    this.swapFreeBytes,
    this.softOpenFiles,
    this.hardOpenFiles,
    this.transparentHugePages,
    this.sysctl = const {},
    this.disks = const [],
    this.services = const [],
  });

  final String system;
  final String? kernel, architecture, distribution, distributionVersion;
  final String? distributionId, virtualization, initSystem, user, privilege;
  final List<String> packageManagers;
  final int? cpuCores,
      memoryBytes,
      memoryAvailableBytes,
      swapBytes,
      swapFreeBytes;
  final String? softOpenFiles, hardOpenFiles, transparentHugePages;
  final Map<String, String> sysctl;
  final List<ServerDiskProfile> disks;
  final List<DetectedServiceProfile> services;

  Map<String, Object?> toJson() => {
    'system': system,
    'kernel': kernel,
    'architecture': architecture,
    'distribution': distribution,
    'distributionId': distributionId,
    'distributionVersion': distributionVersion,
    'virtualization': virtualization,
    'initSystem': initSystem,
    'user': user,
    'privilege': privilege,
    'packageManagers': packageManagers,
    'cpuCores': cpuCores,
    'memoryBytes': memoryBytes,
    'memoryAvailableBytes': memoryAvailableBytes,
    'swapBytes': swapBytes,
    'swapFreeBytes': swapFreeBytes,
    'softOpenFiles': softOpenFiles,
    'hardOpenFiles': hardOpenFiles,
    'transparentHugePages': transparentHugePages,
    'sysctl': sysctl,
    'disks': disks.map((disk) => disk.toJson()).toList(),
    'services': services.map((service) => service.toJson()).toList(),
  };
}

class ServerDiskProfile {
  const ServerDiskProfile(this.name, this.bytes, this.rotational);
  final String name;
  final int? bytes;
  final bool? rotational;

  Map<String, Object?> toJson() => {
    'name': name,
    'sizeBytes': bytes,
    'rotational': rotational,
    'medium': rotational == true
        ? 'HDD'
        : rotational == false
        ? 'SSD'
        : null,
  };
}

class DetectedServiceProfile {
  const DetectedServiceProfile(this.name, this.version, this.status);
  final String name;
  final String? version, status;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'status': status,
  };
}

class RemoteTextSnapshot {
  const RemoteTextSnapshot({
    required this.text,
    required this.sha256,
    required this.sizeBytes,
    this.modifiedUnix,
    this.usedSudo = false,
  });
  final String text, sha256;
  final int sizeBytes;
  final int? modifiedUnix;
  final bool usedSudo;
}

class RemoteWriteResult {
  const RemoteWriteResult({
    required this.sha256,
    this.backupPath,
    this.createdNew = false,
    this.usedSudo = false,
  });
  final String sha256;
  final String? backupPath;
  final bool createdNew, usedSudo;
}

enum RemoteFileError {
  conflict,
  notFound,
  sudoPasswordRequired,
  invalidTarget,
  sensitive,
  tooLarge,
  outcomeUnknown,
  failed,
}

class RemoteFileOpsException implements Exception {
  const RemoteFileOpsException(this.error);
  final RemoteFileError error;
  bool get isConflict => error == RemoteFileError.conflict;
  bool get isSudoPasswordRequired =>
      error == RemoteFileError.sudoPasswordRequired;
}

abstract interface class RemoteFileOpsSource {
  Future<RemoteTextSnapshot> readRemoteText(
    String path, {
    required bool useSudo,
  });

  Future<RemoteWriteResult> writeRemoteText(
    String path,
    String content, {
    required String? expectedSha256,
    required bool createIfMissing,
    required bool createParentDirs,
    required String backupSuffix,
    required bool useSudo,
  });

  Future<void> restoreRemoteBackup(
    String path, {
    required String? backupPath,
    required String currentSha256,
    required String? backupSha256,
    required bool useSudo,
  });
}
