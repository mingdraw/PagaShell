import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagashell/infrastructure/files/io_local_file_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('macOS 沙盒中的用户目录通道返回真实主目录', () async {
    final home = await const MethodChannel('pagashell/files')
        .invokeMethod<String>('getUserHomeDirectory');
    expect(home, isNotNull);
    expect(home, isNotEmpty);
    expect(home!.startsWith('/'), isTrue);
    expect(home, isNot(contains('/Library/Containers/')));
    final containerHome = Platform.environment['HOME'];
    if (containerHome != null &&
        containerHome.contains('/Library/Containers/')) {
      expect(home, isNot(containerHome));
    }
    expect(IoLocalFileRepository(userHomeDirectory: home).homeDirectory, home);
  }, skip: !Platform.isMacOS);
}
