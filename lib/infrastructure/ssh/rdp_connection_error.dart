import '../../domain/rdp/rdp_engine.dart';
import '../../domain/ssh/ssh_engine.dart';

/// 只识别引擎返回的认证状态码；不把网络、账号锁定或权限错误当作密码错误。
SshEngineException rdpConnectionError(String nativeMessage, {Object? cause}) {
  final message = nativeMessage.split('\n').first;
  if (message.contains('RDP NLA 认证失败：')) {
    final status = RegExp(r'(?:STATUS_[A-Z_]+|NTSTATUS) / (0x[0-9A-F]{8})')
        .firstMatch(message)?[1];
    final rejected = status == '0xC000006A' || status == '0xC000006D';
    final sspiRejected =
        status == null && message.contains('SSPI LogonDenied / 0x8009030C');
    if (rejected || sspiRejected) {
      return RdpAuthenticationException(message, cause: cause);
    }
  }
  return SshEngineException(message, cause);
}
