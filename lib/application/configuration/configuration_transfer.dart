import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/entities/connection_configuration.dart';
import '../../domain/repositories/configuration_repository.dart';

/// 密码仅存在于本次操作内存，不缓存、不存入应用偏好。
class ConfigurationTransfer {
  const ConfigurationTransfer({required this.repository});
  final ConfigurationRepository repository;
  static const maxFileBytes = 32 * 1024 * 1024;
  static const _iterations = 600000;
  static const _aad =
      'PagaShell.configuration.v1.pbkdf2-sha256.600000.aes-256-gcm';

  Future<Uint8List> exportFile([String? password]) async {
    if (password != null && password.length < 8) {
      throw const ConfigurationException('导出密码至少需要 8 个字符');
    }
    final data = await repository.read();
    data.validate();
    if (password == null) {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'PagaShell',
            'version': 1,
            'encrypted': false,
            'data': data.toJson(),
          }),
        ),
      );
      _checkSize(bytes);
      return bytes;
    }
    final payload = jsonEncode(data.toJson());
    if (utf8.encode(payload).length > maxFileBytes * 3 ~/ 4 - 1024) {
      throw const ConfigurationException('配置文件不能超过 32 MiB');
    }
    return Isolate.run(() => _encrypt(payload, password));
  }

  /// 旧版加密文件没有 encrypted 字段，仍按原算法参数识别。
  bool isEncrypted(Uint8List bytes) => _isEncrypted(_readEnvelope(bytes));

  Future<ConnectionConfiguration> readFile(
    Uint8List bytes, [
    String? password,
  ]) => Isolate.run(() async {
    final envelope = _readEnvelope(bytes);
    if (!_isEncrypted(envelope)) {
      return ConnectionConfiguration.fromJson(
        envelope['data'] as Map<String, dynamic>,
      );
    }
    if (password == null || password.isEmpty) {
      throw const ConfigurationException('请输入配置文件密码');
    }
    return ConnectionConfiguration.fromJson(await _decrypt(envelope, password));
  });

  Future<void> importFile(Uint8List bytes, [String? password]) async {
    await repository.merge(await readFile(bytes, password));
  }

  static void _checkSize(Uint8List bytes) {
    if (bytes.length > maxFileBytes) {
      throw const ConfigurationException('配置文件不能超过 32 MiB');
    }
  }

  static Map<String, dynamic> _readEnvelope(Uint8List bytes) {
    _checkSize(bytes);
    try {
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (envelope['format'] != 'PagaShell' || envelope['version'] != 1) {
        throw const FormatException();
      }
      return envelope;
    } on Object {
      throw const ConfigurationException('配置文件内容无效或引用不完整');
    }
  }

  static bool _isEncrypted(Map<String, dynamic> envelope) {
    try {
      if (envelope['encrypted'] == false) {
        if (envelope['data'] is! Map<String, dynamic> ||
            [
              'kdf',
              'iterations',
              'cipher',
              'salt',
              'nonce',
              'ciphertext',
              'mac',
            ].any(envelope.containsKey)) {
          throw const FormatException();
        }
        return false;
      }
      if ((envelope['encrypted'] != null && envelope['encrypted'] != true) ||
          envelope.containsKey('data') ||
          envelope['kdf'] != 'pbkdf2-sha256' ||
          envelope['iterations'] != _iterations ||
          envelope['cipher'] != 'aes-256-gcm' ||
          base64Decode(envelope['salt'] as String).length != 16 ||
          base64Decode(envelope['nonce'] as String).length != 12 ||
          base64Decode(envelope['mac'] as String).length != 16 ||
          envelope['ciphertext'] is! String) {
        throw const FormatException();
      }
      return true;
    } on Object {
      throw const ConfigurationException('配置文件内容无效或引用不完整');
    }
  }

  static Future<SecretKey> _derive(String password, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Uint8List> _encrypt(String payload, String password) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final cipher = AesGcm.with256bits();
    final box = await cipher.encrypt(
      utf8.encode(payload),
      secretKey: await _derive(password, salt),
      aad: utf8.encode(_aad),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'PagaShell',
          'version': 1,
          'encrypted': true,
          'kdf': 'pbkdf2-sha256',
          'iterations': _iterations,
          'cipher': 'aes-256-gcm',
          'salt': base64Encode(salt),
          'nonce': base64Encode(box.nonce),
          'ciphertext': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      ),
    );
  }

  static Future<Map<String, dynamic>> _decrypt(
    Map<String, dynamic> json,
    String password,
  ) async {
    try {
      final salt = base64Decode(json['salt'] as String);
      final nonce = base64Decode(json['nonce'] as String);
      final mac = base64Decode(json['mac'] as String);
      final data = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(json['ciphertext'] as String),
          nonce: nonce,
          mac: Mac(mac),
        ),
        secretKey: await _derive(password, salt),
        aad: utf8.encode(_aad),
      );
      return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } on Object {
      throw const ConfigurationException('无法解密配置文件，请检查密码或文件是否完整');
    }
  }
}
