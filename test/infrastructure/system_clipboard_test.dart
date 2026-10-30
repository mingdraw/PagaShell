import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/rdp/rdp_clipboard.dart';
import 'package:pagashell/infrastructure/files/system_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pagashell/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('文件和 Unicode 保留，未变更复用快照，条件写入拒绝不覆盖缓存', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'read') {
        if (calls.length > 1) return null;
        return {
          'changeId': '42',
          'text': null,
          'files': ['/tmp/中文 😀.txt'],
        };
      }
      return null;
    });
    final clipboard = SystemClipboard();
    final first = await clipboard.read();
    expect(first.content.files.single, '/tmp/中文 😀.txt');
    expect(await clipboard.read(), same(first));
    expect((calls[1].arguments as Map)['afterChangeId'], '42');
    expect(
      await clipboard.write(
        const ClipboardContent(text: '新文字'),
        expectedChangeId: '42',
      ),
      isNull,
    );
    expect(await clipboard.read(), same(first));
  });
  test('成功写入沿用原生返回版本，避免下一次读取重复同步', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'write' ? '43' : null,
    );
    final clipboard = SystemClipboard();
    final result = await clipboard.write(
      const ClipboardContent(text: '中文😀\ntext'),
      expectedChangeId: '42',
    );
    expect(result!.changeId, '43');
    expect((await clipboard.read()).content.text, '中文😀\ntext');
  });
  test('文件格式优先，不将路径的文字表示同时写为文本', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'write') {
        expect((call.arguments as Map)['text'], isNull);
        return '44';
      }
      return null;
    });
    final clipboard = SystemClipboard();
    final result = await clipboard.write(
      const ClipboardContent(text: '/tmp/file', files: ['/tmp/file']),
      expectedChangeId: '43',
    );
    expect(result!.content.text, isNull);
    expect((await clipboard.read()).content.files, ['/tmp/file']);
  });
}
