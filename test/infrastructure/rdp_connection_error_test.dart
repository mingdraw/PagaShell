import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/rdp_connection_error.dart';

void main() {
  for (final status in [
    'STATUS_WRONG_PASSWORD / 0xC000006A',
    'STATUS_LOGON_FAILURE / 0xC000006D',
    'SSPI LogonDenied / 0x8009030C',
  ]) {
    test('$status 允许重新输入密码并保留底层原因', () {
      final cause = StateError('native failure');
      final error = rdpConnectionError(
        'RDP NLA 认证失败：Windows 拒绝了登录（$status）\nbacktrace',
        cause: cause,
      );
      expect(error, isA<RdpAuthenticationException>());
      expect(error.cause, same(cause));
      expect(error.message, isNot(contains('backtrace')));
    });
  }

  for (final message in [
    'RDP NLA 认证失败：Windows 拒绝了登录（STATUS_ACCOUNT_LOCKED_OUT / 0xC0000234; SSPI LogonDenied / 0x8009030C）',
    'RDP NLA 认证失败：Windows 拒绝了登录（STATUS_PASSWORD_EXPIRED / 0xC0000071）',
    'RDP NLA 认证失败：Windows 拒绝了登录（STATUS_LOGON_TYPE_NOT_GRANTED / 0xC000015B）',
    'RDP NLA 认证失败：Windows 拒绝了登录（SSPI InvalidToken / 0x80090308）',
    'RDP 会话初始化失败：Windows 拒绝了登录（STATUS_LOGON_FAILURE / 0xC000006D）',
    'RDP TLS 握手失败',
    '无法连接 windows.test:3389',
  ]) {
    test('$message 保留原错误且不提示改密码', () {
      final error = rdpConnectionError(message);
      expect(error, isA<SshEngineException>());
      expect(error, isNot(isA<RdpAuthenticationException>()));
      expect(error.message, message);
    });
  }
}
