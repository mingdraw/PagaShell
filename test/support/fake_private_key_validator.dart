import 'dart:async';

import 'package:pagashell/domain/ssh/ssh_engine.dart';

/// 只记录应用传入的测试密钥；真实格式和签名由 Rust 的本地服务器测试验证。
class FakePrivateKeyValidator implements PrivateKeyValidator {
  final List<(String, String?)> calls = [];
  String? error;
  Completer<void>? pause;

  @override
  Future<void> validatePrivateKey(
    String privateKey, {
    String? passphrase,
  }) async {
    calls.add((privateKey, passphrase));
    await pause?.future;
    final message = error;
    if (message != null) throw SshEngineException(message);
  }
}
