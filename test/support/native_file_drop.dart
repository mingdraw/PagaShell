import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟系统侧送达的拖放消息，覆盖插件坐标判断而非直接调用 UI 回调。
Future<void> nativeFileDrop(
  WidgetTester tester,
  Offset position,
  List<Object> files, {
  bool macOS = false,
}) async {
  const codec = StandardMethodCodec();
  void send(String method, Object arguments) {
    tester.binding.channelBuffers.push(
      'desktop_drop',
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  send('entered', [position.dx, position.dy]);
  await tester.pumpAndSettle();
  send(macOS ? 'performOperation_macos' : 'performOperation', files);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}
