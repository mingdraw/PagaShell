import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/tray/system_tray.dart';
import 'package:pagashell/infrastructure/tray/native_system_tray.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pagashell/tray');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('NativeSystemTray 序列化菜单并去重，且接收原生点击与菜单回调', () async {
    final tray = NativeSystemTray(channel: channel);
    var activated = 0;
    final selected = <String>[];
    tray.setEventHandler(
      onIconActivated: () => activated++,
      onMenuItemSelected: selected.add,
    );

    await tray.initialize();
    const state = SystemTrayState(
      tooltip: 'PagaShell · MCP :47321',
      hasActiveServices: true,
      items: [
        SystemTrayMenuItem.action(id: 'window.show', label: '显示 PagaShell'),
        SystemTrayMenuItem.separator(),
        SystemTrayMenuItem.submenu(
          label: '本地 MCP 服务',
          children: [
            SystemTrayMenuItem.info('状态：运行中'),
            SystemTrayMenuItem.checkbox(
              id: 'setting.minimizeToTray',
              label: '关闭时最小化到托盘',
              checked: true,
            ),
          ],
        ),
      ],
    );

    await tray.update(state);
    // 相同快照不重复发送原生 IPC。
    await tray.update(state);
    await tray.setBackgroundMode(true);
    await tray.setBackgroundMode(true);

    expect(calls.map((c) => c.method), [
      'initialize',
      'update',
      'setBackgroundMode',
    ]);
    final payload = calls[1].arguments as Map<Object?, Object?>;
    expect(payload['tooltip'], 'PagaShell · MCP :47321');
    expect(payload['hasActiveServices'], isTrue);
    final items = payload['items'] as List<Object?>;
    expect(items, hasLength(3));
    expect((items[0] as Map<Object?, Object?>)['id'], 'window.show');
    expect((items[1] as Map<Object?, Object?>)['kind'], 'separator');
    final submenu = items[2] as Map<Object?, Object?>;
    expect(submenu['kind'], 'submenu');
    expect(submenu['children'] as List<Object?>, hasLength(2));

    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(const MethodCall('onIconActivated')),
          (_) {},
        );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(
            const MethodCall('onMenuItemSelected', {'id': 'app.quit'}),
          ),
          (_) {},
        );
    expect(activated, 1);
    expect(selected, ['app.quit']);

    await tray.dispose();
    expect(calls.last.method, 'dispose');
  });

  test('菜单内容不变时仍向原生托盘同步绿点的显示和隐藏', () async {
    final tray = NativeSystemTray(channel: channel);
    const idle = SystemTrayState(
      tooltip: 'PagaShell',
      items: [],
      hasActiveServices: false,
    );
    const active = SystemTrayState(
      tooltip: 'PagaShell',
      items: [],
      hasActiveServices: true,
    );
    await tray.update(idle);
    await tray.update(active);
    await tray.update(active);
    await tray.update(idle);

    final badgeStates = [
      for (final call in calls)
        if (call.method == 'update')
          (call.arguments as Map<Object?, Object?>)['hasActiveServices'],
    ];
    expect(badgeStates, [false, true, false]);
    await tray.dispose();
  });
}
