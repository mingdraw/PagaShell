import '../entities/forward_port.dart';
import '../entities/host.dart';
import '../entities/identity.dart';
import 'host_key.dart';

/// 连接凭据（仅存在于内存，随会话生命周期结束而丢弃）。
///
/// 可来自用户即时输入，或由已保存凭证（Identity + SecretStore）解出。
class SshCredentials {
  const SshCredentials.password(String this.password, {this.username})
    : authType = AuthType.password,
      privateKey = null,
      passphrase = null;

  const SshCredentials.privateKey(
    String this.privateKey, {
    this.passphrase,
    this.username,
  }) : authType = AuthType.privateKey,
       password = null;

  final AuthType authType;
  final String? password;
  final String? privateKey;
  final String? passphrase;

  /// 覆盖主机默认用户名（来自所选凭证）；null 表示使用主机配置的用户名。
  final String? username;
}

/// 每个目标会话独立建立 SSH 或 Page 网关连接，凭据只在内存中保留。
class SshGateway {
  const SshGateway({required this.host, required this.credentials});

  SshGateway.page({required this.host, required String token})
    : credentials = SshCredentials.password(token);

  final Host host;
  final SshCredentials credentials;
}

/// 私钥解析与口令校验；验证时不连接服务器。
abstract interface class PrivateKeyValidator {
  Future<void> validatePrivateKey(String privateKey, {String? passphrase});
}

/// SSH 协议栈的抽象接口。
///
/// 当前实现为 Rust 引擎（russh + russh-sftp，经 flutter_rust_bridge FFI）。
/// 抽象的目的是隔离协议栈依赖、便于测试注入假引擎。
abstract interface class SshEngine {
  /// 建立到 [host] 的连接并完成认证，返回可用的会话句柄。
  ///
  /// 必须在发送凭据前通过 [verifyHostKey]；未提供核验器时拒绝真实连接。
  /// 失败时抛出 [SshEngineException]。
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  });
}

/// 一条已建立的 SSH 会话（同一连接上可承载 shell 与 SFTP）。
abstract interface class SshEngineSession {
  /// 打开带 PTY 的 shell 通道，返回解码后的输出流（单订阅）。
  ///
  /// [cols]/[rows] 为初始终端尺寸；后续变化通过 [resizeTerminal] 通知。
  Stream<String> startShell({required int cols, required int rows});

  /// 向远端写入用户输入。
  void write(String data);

  /// 通知远端终端尺寸变化。
  void resizeTerminal(int width, int height);

  /// 列出远程目录（SFTP）。
  Future<List<SftpDirEntry>> listDir(String path);

  /// 规范化远程路径（解析 `.`/`..`/符号链接）；传 `.` 可取得家目录。
  Future<String> canonicalize(String path);

  /// 下载远程文件到本地路径，流式返回进度。
  ///
  /// 取消订阅即取消传输，半成品文件由引擎清理；失败以错误结束流。
  Stream<SftpTransferProgress> download(String remotePath, String localPath);

  /// 上传本地文件到远程路径，流式返回进度。语义同 [download]。
  Stream<SftpTransferProgress> upload(String localPath, String remotePath);

  /// 创建远程目录。
  Future<void> createDir(String path);

  /// 重命名/移动远程文件或目录。
  Future<void> rename(String oldPath, String newPath);

  /// 删除远程文件或目录（目录递归删除）。
  Future<void> remove(String path, {required bool isDir});

  Future<void> close();
}

/// 独立转发连接的可选能力，不要求终端/SFTP 测试替身实现。
abstract interface class PortForwardSession {
  Stream<PortForwardEvent> startPortForwards(List<ForwardPort> ports);
}

class PortForwardEvent {
  const PortForwardEvent({required this.kind, this.localPort});
  final String kind;
  final int? localPort;
}

/// SFTP 传输进度（domain 层数据结构）。
class SftpTransferProgress {
  const SftpTransferProgress({required this.transferred, required this.total});

  final int transferred;

  /// 总字节数；0 表示大小未知。
  final int total;

  /// 完成比例（0~1）；大小未知时为 null。
  double? get fraction =>
      total <= 0 ? null : (transferred / total).clamp(0.0, 1.0).toDouble();
}

/// SFTP 目录条目（domain 层数据结构）。
class SftpDirEntry {
  const SftpDirEntry({
    required this.name,
    required this.isDir,
    required this.size,
    this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

class SshEngineException implements Exception {
  const SshEngineException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'SshEngineException: $message';
}

/// 连接被拒绝时保留实际变更的端点及旧记录，供用户明确清除后重新核验。
class HostKeyChangedException extends SshEngineException {
  const HostKeyChangedException(this.review, String message) : super(message);

  final HostKeyReview review;
}
