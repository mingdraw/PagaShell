import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS 宿主能注册、独立释放并重新注册 RDP 纹理', (tester) async {
    const channel = MethodChannel('pagashell/rdpTexture');
    const first = 0x6fff0101;
    const second = 0x6fff0102;
    await tester.pumpWidget(const SizedBox.shrink());
    try {
      expect(await channel.invokeMethod<bool>('attach', first), isTrue);
      expect(await channel.invokeMethod<bool>('attach', second), isTrue);
      await channel.invokeMethod<void>('detach', first);
      expect(await channel.invokeMethod<bool>('attach', first), isTrue);
    } finally {
      await channel.invokeMethod<void>('detach', first);
      await channel.invokeMethod<void>('detach', second);
    }
  }, skip: !Platform.isMacOS);
}
