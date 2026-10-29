import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_select_field.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/hosts/host_edit_dialog.dart';
import 'package:pagashell/presentation/shell/connect_flow.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _RecordingEngine implements SshEngine {
  SshGateway? gateway;
  SshCredentials? credentials;
  int calls = 0;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    calls++;
    this.gateway = gateway;
    this.credentials = credentials;
    throw const SshEngineException('测试结束');
  }
}

void main() {
  setUpAll(() async {
    if (Platform.environment['PAGASHELL_GATEWAY_CAPTURE_DIR'] == null) return;
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
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });
  const endpoint = Host(
    id: 'gateway',
    name: 'Production gateway',
    hostname: 'jump.example.test',
    username: 'jump-user',
  );
  const target = Host(
    id: 'service',
    name: 'Internal service',
    hostname: '10.0.0.5',
    username: 'service-user',
  );

  Future<void> pumpApp(WidgetTester tester, {SshEngine? engine}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('gateway-preview'),
        child: PagaShellApp(
          binding: InMemoryBinding(sshEngine: engine ?? _RecordingEngine()),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String label) async {
    await tester.tap(findAppIconButton(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('网关组新建账号密码网关，编辑复用凭证表单且没有高级网关选项', (tester) async {
    await pumpApp(tester);
    expect(find.text('网关'), findsOneWidget);
    await menu(tester, '网关组操作');
    final newGateway = tester.widget<shadcn.MenuButton>(
      find.widgetWithText(shadcn.MenuButton, '新建网关'),
    );
    expect((newGateway.leading! as Icon).icon, shadcn.LucideIcons.network);
    await tester.tap(find.text('新建网关'));
    await tester.pumpAndSettle();
    expect(find.text('高级选项'), findsNothing);
    final type = tester.widget<shadcn.Select<GatewayType>>(
      find.byType(shadcn.Select<GatewayType>),
    );
    expect(type.enabled, isTrue);
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('RDP'), findsNothing);
    expect(find.byKey(const ValueKey('rdp-domain')), findsNothing);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      endpoint.name,
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '网关地址'),
      endpoint.hostname,
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'gateway-secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final gateways = Get.find<GatewayController>();
    expect(gateways.hosts.single.hostname, endpoint.hostname);
    expect(
      await gateways.passwordOf(gateways.hosts.single.id),
      'gateway-secret',
    );
    expect(Get.find<HostController>().hosts, isEmpty);
    await tester.tap(find.text(endpoint.name));
    await tester.pumpAndSettle();
    expect(find.text('编辑网关'), findsOneWidget);
    expect(find.text('已保存；留空保持不变'), findsOneWidget);
    expect(Get.find<SessionController>().sessions, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH 网关保存自定义端口，复制保留账号和密码', (tester) async {
    await pumpApp(tester);
    await menu(tester, '网关组操作');
    await tester.tap(find.text('新建网关'));
    await tester.pumpAndSettle();
    final port = tester.widget<AppTextFormField>(
      find.widgetWithText(AppTextFormField, '端口'),
    );
    expect(port.controller.text, '22');
    await tester.enterText(find.widgetWithText(AppTextFormField, '端口'), '2222');
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'SSH jump',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '网关地址'),
      'jump.test',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '用户名'),
      'operator',
    );
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '密码'),
      'ssh-secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final gateways = Get.find<GatewayController>();
    final original = gateways.hosts.single;
    expect(original.gatewayType, GatewayType.ssh);
    expect(original.port, 2222);
    final context = tester.element(find.text('SSH jump'));
    unawaited(showHostEditDialog(context, copyFrom: original, gateway: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final copy = gateways.hosts.firstWhere((g) => g.id != original.id);
    expect(copy.gatewayType, GatewayType.ssh);
    expect(copy.port, 2222);
    expect(copy.username, 'operator');
    expect(await gateways.passwordOf(copy.id), 'ssh-secret');
    expect(tester.takeException(), isNull);
  });

  testWidgets('网关嵌套拖放和同级排序，禁止拖入服务组，目录删除保留网关', (tester) async {
    await pumpApp(tester);
    final gateways = Get.find<GatewayController>();
    final folders = Get.find<GatewayFolderController>();
    final outer = await folders.create(name: 'Gateway folder');
    final inner = await folders.create(
      name: 'Nested gateway folder',
      parentId: outer.id,
    );
    folders.expanded.add(outer.id);
    await gateways.save(endpoint);
    await gateways.save(endpoint.copyWith(name: 'Another gateway'));
    // 编辑同一 ID 保持位置，不产生新端点。
    expect(gateways.hosts, hasLength(1));
    await tester.pumpAndSettle();
    Future<void> drag(Finder destination) async {
      final source = find.ancestor(
        of: find.text('Another gateway'),
        matching: find.byType(Draggable<HostTreeItem>),
      );
      final gesture = await tester.startGesture(tester.getCenter(source));
      await gesture.moveTo(tester.getCenter(destination));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await drag(find.text('Nested gateway folder'));
    expect(gateways.hosts.single.folderId, inner.id);
    expect(folders.isExpanded(inner.id), isTrue);
    await drag(find.text('服务'));
    expect(gateways.hosts.single.folderId, inner.id);
    expect(Get.find<FolderController>().folders, isEmpty);
    await drag(find.text('网关'));
    expect(gateways.hosts.single.folderId, isNull);
    await expectLater(
      Get.find<GatewayTreeController>().move(
        HostTreeItem.folder(outer.id),
        HostTreePlacement(parentId: inner.id),
      ),
      throwsArgumentError,
    );
    await gateways.moveToFolder(endpoint.id, inner.id);
    await folders.remove(inner.id);
    expect(gateways.hosts.single.folderId, outer.id);
    expect(tester.takeException(), isNull);
  });

  for (final token in ['a', 'a' * 257]) {
    for (final fingerprint in ['', 'ab' * 32]) {
      testWidgets(
        'Page 网关表单接受 ${token.length} 字符令牌、${fingerprint.isEmpty ? 'TCP' : 'TLS'}，编辑保留',
        (tester) async {
          await pumpApp(tester);
          final context = tester.element(find.text('网关'));
          unawaited(showHostEditDialog(context, gateway: true));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(shadcn.Select<GatewayType>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Page').last);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('host-username')), findsNothing);
          expect(find.text('认证方式'), findsNothing);
          expect(
            find.textContaining('WARNING: TLS is disabled.'),
            findsNothing,
          );
          expect(
            tester
                .widget<AppTextFormField>(
                  find.widgetWithText(AppTextFormField, '端口'),
                )
                .controller
                .text,
            '7443',
          );
          await tester.enterText(
            find.widgetWithText(AppTextFormField, '名称'),
            'Office Page',
          );
          await tester.enterText(
            find.widgetWithText(AppTextFormField, '中转 Server 地址'),
            'relay.test',
          );
          await tester.enterText(
            find.byKey(const ValueKey('page-client-id')),
            'office',
          );
          await tester.enterText(
            find.byKey(const ValueKey('page-fingerprint')),
            fingerprint,
          );
          await tester.pump();
          expect(
            find.byKey(const ValueKey('page-plaintext-warning')),
            findsNothing,
          );
          await tester.enterText(
            find.byKey(const ValueKey('host-password')),
            token,
          );
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          final gateways = Get.find<GatewayController>();
          final saved = gateways.hosts.single;
          expect(saved.gatewayType, GatewayType.page);
          expect(saved.pageClientId, 'office');
          expect(saved.pageServerFingerprint, fingerprint);
          expect(saved.identityId, isNull);
          expect(await gateways.passwordOf(saved.id), token);
          unawaited(showHostEditDialog(context, host: saved, gateway: true));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<AppTextFormField>(
                  find.byKey(const ValueKey('host-password')),
                )
                .controller
                .text,
            isEmpty,
          );
          expect(find.text('已保存；留空保持不变'), findsOneWidget);
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(await gateways.passwordOf(saved.id), token);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Page 编辑拒绝无效指纹，清空指纹可保存为 TCP', (tester) async {
    await pumpApp(tester);
    final gateways = Get.find<GatewayController>();
    final page = endpoint.copyWith(
      gatewayType: GatewayType.page,
      port: 7443,
      pageClientId: 'office',
      pageServerFingerprint: 'ab' * 32,
    );
    await gateways.save(page);
    await gateways.savePassword(page.id, 'access');
    final dialog = showHostEditDialog(
      tester.element(find.text('网关')),
      host: page,
      gateway: true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-plaintext-warning')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('page-fingerprint')),
      'invalid',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 Server 提供的 SHA-256 证书指纹'), findsOneWidget);
    expect(gateways.hosts.single.pageServerFingerprint, 'ab' * 32);
    await tester.enterText(
      find.byKey(const ValueKey('page-fingerprint')),
      '  ',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('WARNING: TLS is disabled.'), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await dialog;
    expect(gateways.hosts.single.pageServerFingerprint, isEmpty);
    expect(await gateways.passwordOf(page.id), 'access');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Page 连接入口读取访问令牌，缺失令牌时拒绝连接且不回退直连', (tester) async {
    final engine = _RecordingEngine();
    await pumpApp(tester, engine: engine);
    final gateways = Get.find<GatewayController>();
    final page = endpoint.copyWith(
      gatewayType: GatewayType.page,
      pageClientId: 'office',
      pageServerFingerprint: '',
    );
    await gateways.save(page);
    final configured = target.copyWith(gatewayId: page.id);
    final hosts = Get.find<HostController>();
    await hosts.save(configured);
    await hosts.savePassword(configured.id, 'target-secret');
    await tester.pumpAndSettle();
    await connectToHost(tester.element(find.text('网关')), configured);
    expect(engine.calls, 0);
    await gateways.savePassword(page.id, 'access');
    await connectToHost(tester.element(find.text('网关')), configured);
    expect(engine.calls, 1);
    expect(engine.gateway!.host.gatewayType, GatewayType.page);
    expect(engine.gateway!.host.pageServerFingerprint, isEmpty);
    expect(engine.gateway!.credentials.password, 'access');
    expect(engine.credentials!.password, 'target-secret');
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务高级选项默认收起，保存网关，重开可取消绑定', (tester) async {
    await pumpApp(tester);
    final gateways = Get.find<GatewayController>();
    final hosts = Get.find<HostController>();
    final folders = Get.find<GatewayFolderController>();
    final folder = await folders.create(name: 'Production');
    final nested = await folders.create(
      name: 'Private network',
      parentId: folder.id,
    );
    folders.expanded.clear();
    await gateways.save(endpoint.copyWith(folderId: nested.id));
    await hosts.save(target);
    await tester.pumpAndSettle();
    final context = tester.element(find.text('网关'));
    final dialog = showHostEditDialog(context, host: target);
    await tester.pumpAndSettle();
    expect(find.text('高级选项'), findsOneWidget);
    expect(find.text('密码保存在系统钥匙串，仅用于本服务'), findsNothing);
    expect(find.byType(AppSelectField<String>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('不使用网关（直接连接）'), findsNothing);
    expect(find.byKey(ValueKey('gateway-option-${endpoint.id}')), findsNothing);
    await tester.tap(find.byKey(ValueKey('gateway-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('gateway-option-${endpoint.id}')), findsNothing);
    await tester.tap(find.byKey(ValueKey('gateway-folder-${nested.id}')));
    await tester.pumpAndSettle();
    // 弹层内展开文件夹不改变侧栏状态。
    expect(folders.isExpanded(folder.id), isFalse);
    await tester.tap(find.byKey(ValueKey('gateway-option-${endpoint.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await dialog;
    expect(hosts.hosts.single.gatewayId, endpoint.id);
    final editing = showHostEditDialog(context, host: hosts.hosts.single);
    await tester.pumpAndSettle();
    expect(find.byType(AppSelectField<String>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    final capture = Platform.environment['PAGASHELL_GATEWAY_CAPTURE_DIR'];
    if (capture != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('gateway-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(capture).create(recursive: true);
        await File('$capture/gateway-service-options.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.byType(shadcn.Select<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 重新打开时自动展开所选网关的所有祖先文件夹。
    expect(
      find.byKey(ValueKey('gateway-option-${endpoint.id}')),
      findsOneWidget,
    );
    // 再次点击已选网关取消选择，空值表示直接连接。
    await tester.tap(find.byKey(ValueKey('gateway-option-${endpoint.id}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<shadcn.Select<String>>(find.byType(shadcn.Select<String>))
          .value,
      isNull,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await editing;
    expect(hosts.hosts.single.gatewayId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建服务不选择网关直接保存，凭证登录不显示底部说明', (tester) async {
    await pumpApp(tester);
    final dialog = showHostEditDialog(tester.element(find.text('网关')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '服务地址'),
      target.hostname,
    );
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('不使用网关（直接连接）'), findsNothing);
    expect(
      tester
          .widget<shadcn.Select<String>>(find.byType(shadcn.Select<String>))
          .value,
      isNull,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await dialog;
    expect(Get.find<HostController>().hosts.single.gatewayId, isNull);

    final editing = showHostEditDialog(tester.element(find.text('网关')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号密码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('已有凭证').last);
    await tester.pumpAndSettle();
    expect(find.text('使用所选凭证的用户名与密码或私钥登录，凭证可在多个服务复用'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await editing;
    expect(tester.takeException(), isNull);
  });

  testWidgets('连接入口分别解析网关和目标密码，引用中的网关不可删除', (tester) async {
    final engine = _RecordingEngine();
    await pumpApp(tester, engine: engine);
    final gateways = Get.find<GatewayController>();
    final hosts = Get.find<HostController>();
    await gateways.save(endpoint);
    await gateways.savePassword(endpoint.id, 'gateway-secret');
    final configured = target.copyWith(gatewayId: endpoint.id);
    await hosts.save(configured);
    await hosts.savePassword(target.id, 'target-secret');
    await tester.pumpAndSettle();
    await connectToHost(tester.element(find.text('网关')), configured);
    expect(engine.calls, 1);
    expect(engine.credentials!.password, 'target-secret');
    expect(engine.gateway!.credentials.password, 'gateway-secret');
    expect(engine.gateway!.host.id, endpoint.id);
    await expectLater(
      gateways.remove(endpoint.id),
      throwsA(isA<SshEngineException>()),
    );
    expect(await gateways.passwordOf(endpoint.id), 'gateway-secret');
    await hosts.save(configured.copyWith(gatewayId: null));
    await gateways.remove(endpoint.id);
    expect(await gateways.passwordOf(endpoint.id), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文小窗口高级选项可滚动，保存与取消始终可见', (tester) async {
    await pumpApp(tester);
    tester.view.physicalSize = const Size(800, 600);
    unawaited(Get.updateLocale(const Locale('en', 'US')));
    await tester.pumpAndSettle();
    await Get.find<GatewayController>().save(endpoint);
    await tester.pumpAndSettle();
    final dialog = showHostEditDialog(
      tester.element(find.text('Gateways')),
      host: target.copyWith(gatewayId: endpoint.id),
    );
    await tester.pumpAndSettle();
    expect(find.text('Advanced options'), findsOneWidget);
    expect(find.byType(AppSelectField<String>), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('host-advanced-toggle')),
    );
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(AppSelectField<String>));
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await dialog;
  });

  testWidgets('失效网关阻止连接并保留绑定，用户可明确取消后改为直连', (tester) async {
    final engine = _RecordingEngine();
    await pumpApp(tester, engine: engine);
    final hosts = Get.find<HostController>();
    final configured = target.copyWith(gatewayId: 'retired');
    await hosts.save(configured);
    await hosts.savePassword(configured.id, 'target-secret');
    await tester.pumpAndSettle();
    await connectToHost(tester.element(find.text('网关')), configured);
    await tester.pumpAndSettle();
    expect(engine.calls, 0);
    expect(Get.find<SessionController>().sessions, isEmpty);
    expect(hosts.hosts.single.gatewayId, 'retired');
    expect(find.text('所选网关已不存在'), findsOneWidget);

    final dialog = showHostEditDialog(
      tester.element(find.text('网关')),
      host: configured,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-advanced-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gateway-clear-unavailable')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await dialog;
    expect(hosts.hosts.single.gatewayId, isNull);
    await connectToHost(tester.element(find.text('网关')), hosts.hosts.single);
    expect(engine.calls, 1);
    expect(engine.gateway, isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文小窗口 Page 网关表单可滚动且操作按钮可见', (tester) async {
    await pumpApp(tester);
    tester.view.physicalSize = const Size(800, 600);
    unawaited(Get.updateLocale(const Locale('en', 'US')));
    await tester.pumpAndSettle();
    final dialog = showHostEditDialog(
      tester.element(find.text('Gateways')),
      host: endpoint.copyWith(
        gatewayType: GatewayType.page,
        port: 7443,
        pageClientId: 'office',
        pageServerFingerprint: '',
      ),
      gateway: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Page'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-username')), findsNothing);
    expect(find.textContaining('WARNING: TLS is disabled.'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('page-fingerprint')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('host-password')));
    await tester.pumpAndSettle();
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    final capture = Platform.environment['PAGASHELL_GATEWAY_CAPTURE_DIR'];
    if (capture != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('gateway-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(capture).create(recursive: true);
        await File('$capture/page-gateway-english-small.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await dialog;
  });

  testWidgets('英文小窗口 SSH 网关表单可滚动且操作按钮可见', (tester) async {
    await pumpApp(tester);
    tester.view.physicalSize = const Size(800, 600);
    unawaited(Get.updateLocale(const Locale('en', 'US')));
    await tester.pumpAndSettle();
    final dialog = showHostEditDialog(
      tester.element(find.text('Gateways')),
      host: endpoint,
      gateway: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Gateway type'), findsOneWidget);
    expect(find.text('RDP'), findsNothing);
    expect(find.byKey(const ValueKey('rdp-domain')), findsNothing);
    await tester.ensureVisible(
      find.widgetWithText(AppTextFormField, 'Username'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    final capture = Platform.environment['PAGASHELL_GATEWAY_CAPTURE_DIR'];
    if (capture != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('gateway-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(capture).create(recursive: true);
        await File('$capture/ssh-gateway-english-small.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.byKey(const ValueKey('host-note')));
    await tester.pumpAndSettle();
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await dialog;
  });
}
