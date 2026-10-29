import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/identities/identity_edit_dialog.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_vnc_engine.dart';
import 'support/in_memory_binding.dart';

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');
final _captureKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  if (_captureDir.isEmpty) return;
  final locale = Get.locale;
  // Widget-test fonts have no CJK fallback; English keeps captures readable.
  unawaited(Get.updateLocale(const Locale('en', 'US')));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        _captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(_captureDir).create(recursive: true);
      await File('$_captureDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  unawaited(Get.updateLocale(locale ?? const Locale('zh', 'CN')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });
  const host = Host(
    id: 'v',
    name: 'VNC desktop',
    hostname: 'vnc.test',
    port: 5900,
    serviceType: ServiceType.vnc,
    username: '',
  );

  Future<void> pumpApp(WidgetTester tester, FakeVncEngine engine) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: PagaShellApp(
          binding: InMemoryBinding(vncEngine: engine),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('新建 VNC 默认 5900，无用户名和域，复制密码且不显示 SSH 入口', (tester) async {
    await pumpApp(tester, FakeVncEngine());
    unawaited(showHostEditDialog(tester.element(find.text('服务'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSelectField<ServiceType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VNC').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppTextFormField>(find.widgetWithText(AppTextFormField, '端口'))
          .controller
          .text,
      '5900',
    );
    expect(find.byKey(const ValueKey('host-username')), findsNothing);
    expect(find.byKey(const ValueKey('rdp-domain')), findsNothing);
    await _capture(tester, 'vnc-service-form');
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      host.name,
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      host.hostname,
    );
    await tester.enterText(
      find.byKey(const ValueKey('host-password')),
      'test-password',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final hosts = Get.find<HostController>();
    final saved = hosts.hosts.single;
    expect(saved.isVnc, isTrue);
    expect(saved.address, 'vnc.test:5900');
    unawaited(
      showHostEditDialog(tester.element(find.text('服务')), copyFrom: saved),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final copy = hosts.hosts.singleWhere((h) => h.id != saved.id);
    expect(copy.serviceType, ServiceType.vnc);
    expect(await hosts.passwordOf(copy.id), 'test-password');
    await tester.tap(find.text(host.name), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('文件传输'), findsNothing);
    expect(find.text('端口转发'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('凭证可选择 SSH/RDP/VNC，VNC 只显示密码并按类型筛选', (tester) async {
    await pumpApp(tester, FakeVncEngine());
    unawaited(showIdentityEditDialog(tester.element(find.text('凭证'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('identity-service-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VNC').last);
    await tester.pumpAndSettle();
    expect(find.text('用户名'), findsNothing);
    await _capture(tester, 'vnc-credential-form');
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'VNC credential',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'test-only',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final identities = Get.find<IdentityController>();
    expect(identities.identities.single.serviceType, ServiceType.vnc);
    expect(identities.identities.single.username, isEmpty);
    final vncIdentity = identities.identities.single;
    await identities.saveWithPassword(
      name: 'SSH credential',
      username: 'ssh',
      password: 'test-only',
    );
    await identities.saveWithPassword(
      name: 'RDP credential',
      username: 'rdp',
      password: 'test-only',
      serviceType: ServiceType.rdp,
    );
    unawaited(
      showHostEditDialog(
        tester.element(find.text('服务')),
        host: host.copyWith(identityId: vncIdentity.id),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<String>).last);
    await tester.pumpAndSettle();
    final popup = find.byType(shadcn.SelectPopup<String>);
    expect(
      find.descendant(of: popup, matching: find.text('VNC credential')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: popup,
        matching: find.textContaining('SSH credential'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: popup,
        matching: find.textContaining('RDP credential'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('VNC 桌面复用页签、键盘发送 keysym，失焦释放，断线重连和关闭释放', (tester) async {
    final engine = FakeVncEngine();
    await pumpApp(tester, engine);
    final hosts = Get.find<HostController>();
    await hosts.save(host);
    await hosts.savePassword(host.id, 'test-only');
    await connectToHost(tester.element(find.text('服务')), host);
    await tester.pump();
    final sessions = Get.find<SessionController>();
    final id = sessions.sessions.single.id;
    expect(sessions.sessions.single.kind, SessionKind.remoteDesktop);
    expect(sessions.commandSessions, isEmpty);
    final desktop = engine.created.single;
    desktop.output.add(
      RdpFrame(
        width: 64,
        height: 32,
        rgba: Uint8List.fromList(List.filled(64 * 32 * 4, 255)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('VNC · 64 × 32'), findsOneWidget);
    expect(find.byKey(const ValueKey('rdp-resolution-menu')), findsNothing);
    expect(desktop.resizes, isEmpty);
    await _capture(tester, 'vnc-desktop');
    await tester.tap(find.byKey(const ValueKey('rdp-desktop-image')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'A');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(
      desktop.symbols,
      containsAllInOrder([
        (0xffe1, true),
        (65, true),
        (0xffe1, false),
        (65, false),
      ]),
    );
    expect(desktop.symbols, contains((0xffe3, false)));
    expect(desktop.keys, isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await connectToHost(tester.element(find.text('服务')), host);
    expect(engine.created.length, 1);
    await sessions.desktopFailed(id, 'disconnected');
    await tester.pump();
    expect(desktop.closes, 1);
    await sessions.retry(id);
    await tester.pump();
    expect(engine.created.length, 2);
    expect(engine.attempts.last.password, 'test-only');
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(engine.created.last.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('即时连接仅展示 VNC 凭证，绑定提示不包含用户名', (tester) async {
    final engine = FakeVncEngine();
    await pumpApp(tester, engine);
    final identities = Get.find<IdentityController>();
    await identities.saveWithPassword(
      name: 'VNC login',
      username: '',
      password: 'vnc-only-password',
      serviceType: ServiceType.vnc,
    );
    await identities.saveWithPassword(
      name: 'SSH login',
      username: 'root',
      password: 'ssh-only-password',
    );
    await Get.find<HostController>().save(host);
    final connecting = connectToHost(tester.element(find.text('服务')), host);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSelectField<String>));
    await tester.pumpAndSettle();
    final popup = find.byType(shadcn.SelectPopup<String>);
    expect(
      find.descendant(of: popup, matching: find.text('VNC login')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: popup, matching: find.textContaining('SSH login')),
      findsNothing,
    );
    await tester.tap(find.text('VNC login').last);
    await tester.pumpAndSettle();
    expect(find.text('将使用所选凭证连接，并记住此绑定'), findsOneWidget);
    await tester.tap(find.text('连接'));
    await tester.pump();
    await connecting;
    expect(engine.attempts.single.password, 'vnc-only-password');
    await Get.find<SessionController>().closeAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑保持同协议密码，切换到 VNC 不复用原 SSH 密码', (tester) async {
    await pumpApp(tester, FakeVncEngine());
    final hosts = Get.find<HostController>();
    final original = host.copyWith(
      serviceType: ServiceType.ssh,
      username: 'root',
      port: 22,
    );
    await hosts.save(original);
    await hosts.savePassword(original.id, 'ssh-only-password');
    unawaited(
      showHostEditDialog(tester.element(find.text('服务')), host: original),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await hosts.passwordOf(original.id), 'ssh-only-password');
    unawaited(
      showHostEditDialog(tester.element(find.text('服务')), host: original),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSelectField<ServiceType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VNC').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(hosts.hosts.single.serviceType, ServiceType.vnc);
    expect(await hosts.passwordOf(original.id), isNull);
    expect(tester.takeException(), isNull);
  });

  test('关闭正在连接的 VNC 取消连接并释放迟到句柄，拒绝 SSH 功能', () async {
    final engine = FakeVncEngine()..pending = Completer<RdpEngineSession>();
    InMemoryBinding(vncEngine: engine).dependencies();
    final controller = Get.find<SessionController>();
    final opening = controller.open(
      host,
      const SshCredentials.password('test-only'),
    );
    await controller.closeAll();
    await engine.cancellation;
    final late = FakeVncSession();
    engine.pending!.complete(late);
    await opening;
    expect(late.closes, 1);
    await expectLater(
      controller.open(
        host,
        const SshCredentials.password('test-only'),
        kind: SessionKind.fileTransfer,
      ),
      throwsA(isA<SshEngineException>()),
    );
    expect(
      () => controller.openForward(host),
      throwsA(isA<SshEngineException>()),
    );
    expect(controller.sessions, isEmpty);
  });
}
