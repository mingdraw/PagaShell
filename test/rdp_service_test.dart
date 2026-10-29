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
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_rdp_engine.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

void main() {
  setUpAll(() async {
    if (Platform.environment['PAGASHELL_RDP_CAPTURE_DIR'] == null) return;
    for (final font in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
    final cjk = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (cjk.existsSync()) {
      await (FontLoader(
        'PingFang SC',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['PAGASHELL_RDP_CAPTURE_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('rdp-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  tearDown(() {
    Get.reset();
    Get.locale = null;
  });
  Future<void> pumpApp(WidgetTester tester, FakeRdpEngine engine) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('rdp-preview'),
        child: PagaShellApp(
          binding: InMemoryBinding(rdpEngine: engine),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('服务选择 RDP 默认 3389，保存复制保留域和密码且无需 helper', (tester) async {
    await pumpApp(tester, FakeRdpEngine());
    unawaited(showHostEditDialog(tester.element(find.text('服务'))));
    await tester.pumpAndSettle();
    expect(find.text('服务类型'), findsOneWidget);
    await tester.tap(find.byType(AppSelectField<ServiceType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RDP').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppTextFormField>(find.widgetWithText(AppTextFormField, '端口'))
          .controller
          .text,
      '3389',
    );
    expect(find.textContaining('Windows 跳板机需运行'), findsNothing);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'Windows',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      'windows.test',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('rdp-domain')));
    await tester.enterText(find.byKey(const ValueKey('rdp-domain')), 'CORP');
    await tester.ensureVisible(find.byKey(const ValueKey('host-password')));
    await tester.enterText(
      find.byKey(const ValueKey('host-password')),
      'secret',
    );
    expect(find.text('保存').hitTestable(), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final hosts = Get.find<HostController>();
    final original = hosts.hosts.single;
    expect(original.serviceType, ServiceType.rdp);
    expect(original.rdpDomain, 'CORP');
    unawaited(
      showHostEditDialog(
        tester.element(find.text('Windows')),
        copyFrom: original,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final copy = hosts.hosts.firstWhere((h) => h.id != original.id);
    expect(copy.serviceType, ServiceType.rdp);
    expect(copy.rdpDomain, 'CORP');
    expect(await hosts.passwordOf(copy.id), 'secret');
    await tester.tap(find.text('Windows'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('文件传输'), findsNothing);
    expect(find.text('端口转发'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接 RDP 服务创建桌面标签并复用，关闭其他标签不影响桌面', (tester) async {
    final engine = FakeRdpEngine();
    await pumpApp(tester, engine);
    const host = Host(
      id: 'w',
      name: 'Windows',
      hostname: 'windows.test',
      port: 3389,
      serviceType: ServiceType.rdp,
    );
    final hosts = Get.find<HostController>();
    await hosts.save(host);
    await hosts.savePassword(host.id, 'secret');
    await tester.pumpAndSettle();
    await connectToHost(tester.element(find.text('服务')), host);
    // Indeterminate progress intentionally remains until the first frame.
    await tester.pump();
    final sessions = Get.find<SessionController>();
    expect(sessions.sessions.single.kind, SessionKind.remoteDesktop);
    expect(find.byType(RdpDesktopPanel), findsOneWidget);
    await connectToHost(tester.element(find.text('服务')), host);
    expect(engine.created.length, 1);
    await connectToHost(tester.element(find.text('服务')), host, forceNew: true);
    await tester.pump();
    expect(engine.created.length, 2);
    await sessions.closeOthers(sessions.sessions.last.id);
    await tester.pump();
    expect(engine.created.first.closes, 1);
    expect(engine.created.last.closes, 0);
    await sessions.closeAll();
    await tester.pumpAndSettle();
    expect(engine.created.last.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH 服务切换 RDP 要求选择 RDP 凭证', (tester) async {
    await pumpApp(tester, FakeRdpEngine());
    final identity = await Get.find<IdentityController>().saveWithPassword(
      name: 'Windows login',
      username: 'operator',
      password: 'secret',
    );
    final rdpIdentity = await Get.find<IdentityController>().saveWithPassword(
      name: 'Windows RDP',
      username: 'operator',
      password: 'secret',
      serviceType: ServiceType.rdp,
    );
    final host = Host(
      id: 'switch',
      name: 'Switch',
      hostname: 'windows.test',
      identityId: identity.id,
    );
    await Get.find<HostController>().save(host);
    await tester.pumpAndSettle();
    unawaited(showHostEditDialog(tester.element(find.text('服务')), host: host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSelectField<ServiceType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RDP').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请选择凭证'), findsOneWidget);
    await tester.tap(find.byType(shadcn.Select<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows RDP（operator）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = Get.find<HostController>().hosts.single;
    expect(saved.isRdp, isTrue);
    expect(saved.identityId, rdpIdentity.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文小窗口 RDP 服务表单可滚动，保存取消可见', (tester) async {
    await pumpApp(tester, FakeRdpEngine());
    unawaited(Get.updateLocale(const Locale('en', 'US')));
    await tester.pumpAndSettle();
    unawaited(
      showHostEditDialog(
        tester.element(find.text('Services')),
        host: const Host(
          id: 'w',
          name: 'Windows',
          hostname: 'windows.test',
          port: 3389,
          serviceType: ServiceType.rdp,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Service type'), findsOneWidget);
    expect(find.text('Save').hitTestable(), findsOneWidget);
    await capture(tester, 'rdp-service-english-top');
    await tester.ensureVisible(find.byKey(const ValueKey('host-note')));
    await tester.pumpAndSettle();
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    await capture(tester, 'rdp-service-english-bottom');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('缩放桌面正确映射键鼠，失焦释放按键', (tester) async {
    final session = FakeRdpSession();
    final errors = <String>[];
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SizedBox(
          width: 640,
          height: 400,
          child: RdpDesktopPanel(
            session: session,
            active: true,
            onError: errors.add,
          ),
        ),
      ),
    );
    session.output.add(
      RdpFrame(
        width: 64,
        height: 32,
        rgba: Uint8List.fromList(List.filled(64 * 32 * 4, 255)),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final image = find.byKey(const ValueKey('rdp-desktop-image'));
    expect(image, findsOneWidget);
    await tester.tapAt(tester.getCenter(image));
    await tester.pump();
    expect(
      session.pointers.any((p) => p.$1 == 32 && p.$2 == 16 && p.$3 == 0x9000),
      isTrue,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(session.keys, contains((0x4b, true, true)));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(session.keys, contains((0x1d, false, false)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(errors, isEmpty);
    expect(rdpScanCode(PhysicalKeyboardKey.keyA), 0x1e);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });
}
