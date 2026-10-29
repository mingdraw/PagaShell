import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/terminal/batch_command_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _Session extends FakeSftpSession {
  final written = <String>[];

  @override
  void write(String data) => written.add(data);
}

class _Engine implements SshEngine {
  final sessions = <_Session>[];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final session = _Session();
    sessions.add(session);
    return session;
  }
}

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDir.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
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
}

Finder _inDialog(Finder finder) =>
    find.descendant(of: find.byType(BatchCommandDialog), matching: finder);

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(findAppIconButton('会话列表'.tr));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('批量执行命令'.tr));
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
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 从页签菜单选择终端并发送多行命令，保持未选中页签不变', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _Engine();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PagaShellApp(
            binding: InMemoryBinding(sshEngine: engine),
            platform: TargetPlatform.macOS,
          ),
        ),
      );
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      final controller = Get.find<SessionController>();
      const credentials = SshCredentials.password(
        'test-only',
        username: 'rocky',
      );
      final first = await controller.open(
        const Host(id: 'web', name: 'web-01', hostname: 'web.test'),
        credentials,
      );
      final second = await controller.open(
        const Host(id: 'db', name: 'db-02', hostname: 'db.test'),
        credentials,
      );
      await controller.open(
        const Host(id: 'other', name: 'other-03', hostname: 'other.test'),
        credentials,
      );
      await controller.open(
        const Host(id: 'files', name: 'files-only', hostname: 'files.test'),
        credentials,
        kind: SessionKind.fileTransfer,
      );
      controller.openForward(
        const Host(id: 'tunnel', name: 'tunnel-only', hostname: 'tunnel.test'),
      );
      await tester.pumpAndSettle();
      await _openDialog(tester);
      expect(find.byType(BatchCommandDialog), findsOneWidget);
      expect(_inDialog(find.text('files-only')), findsNothing);
      expect(_inDialog(find.text('tunnel-only')), findsNothing);
      expect(_inDialog(find.text('rocky@web.test')), findsOneWidget);
      expect(_inDialog(find.text('root@web.test')), findsNothing);
      final execute = find.byKey(const ValueKey('batch-command-execute'));
      expect(tester.widget<shadcn.PrimaryButton>(execute).onPressed, isNull);
      final input = _inDialog(find.byType(EditableText));
      await tester.enterText(input, 'pwd');
      expect(
        tester.widget<EditableText>(input).textInputAction,
        TextInputAction.newline,
      );
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
      await tester.enterText(
        _inDialog(find.byType(EditableText)),
        'pwd\nwhoami',
      );
      await tester.pump();
      expect(
        engine.sessions.every((session) => session.written.isEmpty),
        isTrue,
      );
      expect(tester.widget<shadcn.PrimaryButton>(execute).onPressed, isNull);

      await tester.tap(_inDialog(find.text('全选'.tr)));
      await tester.pumpAndSettle();
      expect(
        _inDialog(find.text('已选择 @count 个终端'.trParams({'count': '3'}))),
        findsOneWidget,
      );
      await tester.tap(_inDialog(find.text('全选'.tr)));
      await tester.pumpAndSettle();
      expect(tester.widget<shadcn.PrimaryButton>(execute).onPressed, isNull);
      for (final id in [first, second]) {
        await tester.tap(find.byKey(ValueKey('batch-target-$id')));
      }
      await tester.pumpAndSettle();
      expect(
        _inDialog(find.text('已选择 @count 个终端'.trParams({'count': '2'}))),
        findsOneWidget,
      );
      await _capture(tester, key, 'batch-command-${locale.languageCode}-1280');

      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(execute.hitTestable(), findsOneWidget);
      await _capture(tester, key, 'batch-command-${locale.languageCode}-800');
      tester.view.physicalSize = const Size(640, 480);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(execute.hitTestable(), findsOneWidget);
      await tester.tap(execute);
      await tester.pumpAndSettle();
      expect(find.byType(BatchCommandDialog), findsNothing);
      expect(engine.sessions[0].written, ['pwd\rwhoami\r']);
      expect(engine.sessions[1].written, ['pwd\rwhoami\r']);
      expect(engine.sessions[2].written, isEmpty);
      expect(engine.sessions[3].written, isEmpty);
      expect(tester.takeException(), isNull);
      expect(
        find.text('命令已发送至 @count 个终端'.trParams({'count': '2'})),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('打开弹窗后连接关闭会更新目标，空目标禁用执行，取消不发送', (tester) async {
    final engine = _Engine();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(sshEngine: engine)),
    );
    await tester.pumpAndSettle();
    final controller = Get.find<SessionController>();
    final id = await controller.open(
      const Host(id: 'web', name: 'web-01', hostname: 'web.test'),
      const SshCredentials.password('test-only'),
    );
    // 保留一个非终端页签，断开终端后菜单与弹窗仍可展示。
    controller.openForward(
      const Host(id: 'tunnel', name: 'tunnel-only', hostname: 'tunnel.test'),
    );
    await tester.pumpAndSettle();
    await _openDialog(tester);
    await tester.tap(find.byKey(ValueKey('batch-target-$id')));
    await tester.enterText(_inDialog(find.byType(EditableText)), 'whoami');
    await tester.pumpAndSettle();
    await tester.runAsync(() => controller.close(id));
    await tester.pumpAndSettle();
    expect(_inDialog(find.text('当前没有已连接的 SSH 终端'.tr)), findsOneWidget);
    expect(
      tester
          .widget<shadcn.PrimaryButton>(
            find.byKey(const ValueKey('batch-command-execute')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(_inDialog(find.text('取消'.tr)));
    await tester.pumpAndSettle();
    expect(find.byType(BatchCommandDialog), findsNothing);
    expect(engine.sessions.single.written, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
