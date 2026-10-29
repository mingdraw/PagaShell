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
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/host_tree_item.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/identities/identity_edit_dialog.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/shell/shell_page.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

// 可选截图用于人工布局检查，不依赖平台截图或 golden 基线。
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

Future<void> _checkPasswordFieldSize(
  WidgetTester tester,
  String passwordLabel,
) async {
  final reference = find.descendant(
    of: find.widgetWithText(AppTextFormField, '用户名'.tr),
    matching: find.byType(shadcn.TextField),
  );
  final password = find.descendant(
    of: find.widgetWithText(AppTextFormField, passwordLabel),
    matching: find.byType(shadcn.TextField),
  );
  final referenceSize = tester.getSize(reference);
  expect(tester.getSize(password), referenceSize);
  await tester.enterText(password, 'layout-check');
  final toggle = find.descendant(
    of: password,
    matching: find.byType(AppIconButton),
  );
  for (final obscure in [false, true]) {
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.getSize(password), referenceSize);
    final field = tester.widget<shadcn.TextField>(password);
    expect(field.obscureText, obscure);
    expect(field.controller!.text, 'layout-check');
  }
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

  for (final size in [const Size(800, 600), const Size(1280, 800)]) {
    testWidgets('终端 $size 非整行回滚时绘制不越过视口边界', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PagaShellApp(
            binding: InMemoryBinding(),
            platform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final terminal = Terminal();
      for (var line = 0; line < 200; line++) {
        // 使用独特的单元格底色检查实际绘制范围，不依赖字体或字形位置。
        terminal.write('\x1b[48;2;252;25;161moutput row $line\x1b[0m\r\n');
      }
      final sessions = Get.find<SessionController>();
      sessions.sessions.add(
        Session(
          id: 'bounds',
          host: const Host(
            id: 'bounds',
            name: '终端边界',
            hostname: 'example.test',
          ),
          phase: SessionPhase.ready,
          terminal: terminal,
        ),
      );
      sessions.activeSessionId.value = 'bounds';
      await tester.pumpAndSettle();
      final view = find.byType(TerminalView);
      final state = tester.state<TerminalViewState>(view);
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(of: view, matching: find.byType(Scrollable)),
          )
          .position;
      expect(
        scroll.maxScrollExtent,
        greaterThan(state.renderTerminal.lineHeight * 10),
      );
      scroll.jumpTo(state.renderTerminal.lineHeight * 1.9);
      await tester.pump();
      final rect = tester.getRect(view);
      final counts = await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var inside = 0;
          var outside = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final offset = (y * image.width + x) * 4;
              if (bytes.getUint32(offset) != 0xFC19A1FF) continue;
              if (rect.contains(Offset(x + 0.5, y + 0.5))) {
                inside++;
              } else {
                outside++;
              }
            }
          }
          return (inside, outside);
        } finally {
          image.dispose();
        }
      });
      expect(counts!.$1, greaterThan(0));
      expect(counts.$2, 0, reason: '滚动行只能绘制在终端视口内部');
      await _capture(tester, key, 'terminal-bounds-${size.width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('图标按钮按配置显示 shadcn 提示，保留无障碍名称和点击行为', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
      final sessions = Get.find<SessionController>();
      sessions.sessions.add(
        const Session(
          id: 'hover-preview',
          host: Host(
            id: 'hover-host',
            name: '192.168.100.221',
            hostname: 'example.test',
          ),
          phase: SessionPhase.failed,
          error: '连接失败',
        ),
      );
      sessions.activeSessionId.value = 'hover-preview';
      await tester.pumpAndSettle();
      final labels = tester
          .widgetList<AppIconButton>(find.byType(AppIconButton))
          .map((button) => button.semanticLabel)
          .where((label) => label.isNotEmpty)
          .toSet();
      expect(labels, containsAll(['服务组操作', '关闭标签']));
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final label in labels) {
        final button = findAppIconButton(label);
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(label))
              .flagsCollection
              .isButton,
          isTrue,
        );
        await mouse.moveTo(tester.getCenter(button));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 250));
        final tooltip = tester.widget<AppIconButton>(button).tooltip;
        if (tooltip == null) {
          expect(find.byType(shadcn.TooltipContainer), findsNothing);
        } else {
          expect(find.byType(shadcn.TooltipContainer), findsOneWidget);
          expect(find.text(tooltip), findsOneWidget);
        }
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
      }

      await tester.tap(findAppIconButton('服务组操作'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(shadcn.MenuButton, '新建文件夹'));
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(findAppIconButton('关闭标签'));
      await tester.pumpAndSettle();
      expect(sessions.sessions, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('操作菜单只高亮当前项，支持键盘导航和取消', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PagaShellApp(
          binding: InMemoryBinding(),
          platform: TargetPlatform.macOS,
        ),
      ),
    );
    final hosts = Get.find<HostController>();
    await hosts.save(
      const Host(id: 'preview', name: 'web-01', hostname: 'example.test'),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.addPointer(location: tester.getCenter(find.text('web-01')));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(find.byIcon(shadcn.LucideIcons.ellipsis), findsNothing);
    await mouse.down(tester.getCenter(find.text('web-01')));
    await mouse.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _capture(tester, key, 'zh-1280-host-menu');

    bool highlighted(String label) => tester
        .widgetList<shadcn.OverflowDecoratedBox>(
          find.descendant(
            of: find.widgetWithText(shadcn.MenuButton, label),
            matching: find.byType(shadcn.OverflowDecoratedBox),
          ),
        )
        .any(
          (box) =>
              box.decoration is BoxDecoration &&
              (((box.decoration as BoxDecoration).color?.a ?? 0) > 0),
        );

    await mouse.moveTo(tester.getCenter(find.text('编辑')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await _capture(tester, key, 'zh-1280-host-menu-hover');
    expect(highlighted('新建会话'), isFalse);
    expect(highlighted('编辑'), isTrue);
    expect(highlighted('删除'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(highlighted('编辑'), isFalse);
    expect(highlighted('复制'), isTrue);
    expect(highlighted('删除'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(highlighted('复制'), isFalse);
    expect(highlighted('删除'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(shadcn.MenuButton), findsNothing);
    expect(hosts.hosts, hasLength(1));

    await mouse.moveTo(tester.getCenter(find.text('web-01')));
    await mouse.down(tester.getCenter(find.text('web-01')));
    await mouse.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.moveTo(tester.getCenter(find.text('编辑')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(hosts.hosts, hasLength(1));
    await tester.tap(find.text('web-01'), buttons: kSecondaryMouseButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新建会话'), findsOneWidget);
    expect(find.text('文件传输'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final locale in AppTranslations.supportedLocales) {
    for (final size in [const Size(800, 600), const Size(1280, 800)]) {
      testWidgets('${locale.languageCode} $size 欢迎页、快速连接与表单无溢出，操作可见', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        Get.locale = locale;
        final key = GlobalKey();
        final prefix = '${locale.languageCode}-${size.width.toInt()}';
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: PagaShellApp(
              binding: InMemoryBinding(),
              platform: TargetPlatform.macOS,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('搜索服务'.tr), findsOneWidget);
        expect(
          find.widgetWithText(shadcn.PrimaryButton, '快速连接'.tr).hitTestable(),
          findsOneWidget,
        );
        await _capture(tester, key, '$prefix-workspace');

        final hosts = Get.find<HostController>();
        const previewHosts = [
          Host(
            id: 'quick-app',
            name: 'app-01',
            hostname: '192.0.2.10',
            username: 'deploy',
          ),
          Host(
            id: 'quick-db',
            name: 'db-02-production-with-a-long-descriptive-host-name',
            hostname: 'database.production.example.test',
          ),
        ];
        for (final host in previewHosts) {
          await hosts.save(host);
        }
        await tester.pumpAndSettle();
        for (final host in previewHosts) {
          final source = find.ancestor(
            of: find.text(host.name),
            matching: find.byType(Draggable<HostTreeItem>),
          );
          final sourceSize = tester.getSize(source);
          final draggable = tester.widget<Draggable<HostTreeItem>>(source);
          final drag = await tester.startGesture(
            tester.getCenter(find.text(host.name)),
          );
          await drag.moveBy(const Offset(100, 0));
          await tester.pump();
          final feedbackSize = tester.getSize(
            find.byWidget(draggable.feedback),
          );
          expect(feedbackSize, sourceSize);
          expect(tester.takeException(), isNull);
          await _capture(tester, key, '$prefix-drag-${host.id}');
          await drag.cancel();
          await tester.pumpAndSettle();
        }
        await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '快速连接'.tr));
        await tester.pumpAndSettle();
        for (final host in previewHosts) {
          expect(find.text(host.address).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await _capture(tester, key, '$prefix-quick-connect');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('输入服务名称 / 地址，回车连接…'.tr), findsNothing);
        for (final host in previewHosts) {
          await hosts.remove(host.id);
        }
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(shadcn.OutlineButton, '新建服务'.tr));
        await tester.pumpAndSettle();
        final save = find.widgetWithText(shadcn.PrimaryButton, '保存'.tr);
        expect(find.text('留空则使用服务地址'.tr), findsOneWidget);
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _checkPasswordFieldSize(tester, '密码'.tr);
        await _capture(tester, key, '$prefix-host');
        await tester.tap(find.text('取消'.tr));
        await tester.pumpAndSettle();

        unawaited(
          showIdentityEditDialog(tester.element(find.byType(ShellPage))),
        );
        await tester.pumpAndSettle();
        await _checkPasswordFieldSize(tester, '密码'.tr);
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, '$prefix-password-identity');
        await tester.tap(find.text('取消'.tr));
        await tester.pumpAndSettle();

        unawaited(
          showIdentityEditDialog(
            tester.element(find.byType(ShellPage)),
            identity: const Identity(
              id: 'preview',
              name: 'deploy',
              username: 'deploy',
              authType: AuthType.privateKey,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        // 较长表单可滚动到最后的敏感字段，操作区不随内容移出视口。
        await tester.ensureVisible(find.text('私钥口令（可选）'.tr));
        await tester.pumpAndSettle();
        await _checkPasswordFieldSize(tester, '私钥口令（可选）'.tr);
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, '$prefix-private-key');
        await tester.tap(find.text('取消'.tr));
        await tester.pumpAndSettle();

        await tester.tap(findAppIconButton('服务组操作'.tr));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('新建文件夹'.tr));
        await tester.pumpAndSettle();
        final folderCard = find.descendant(
          of: find.byType(AppDialog),
          matching: find.byType(shadcn.Card),
        );
        final folderDialogSize = tester.getSize(folderCard);
        expect(folderDialogSize.width, lessThan(400));
        expect(folderDialogSize.height, lessThan(260));
        final confirm = find.widgetWithText(shadcn.PrimaryButton, '确定'.tr);
        expect(confirm.hitTestable(), findsOneWidget);
        await _capture(tester, key, '$prefix-folder');
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.text('必填'.tr), findsOneWidget);
        expect(tester.getSize(folderCard).height, lessThan(300));
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'.tr));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
