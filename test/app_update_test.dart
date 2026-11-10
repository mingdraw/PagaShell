import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/updates/app_update_controller.dart';
import 'package:pagashell/core/app_info.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/updates/app_release.dart';
import 'package:pagashell/presentation/components/app_markdown.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/settings/settings_dialog.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/update_fixtures.dart';

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');
const _markdownNotes = '''
## 更新亮点

**修复终端显示**，支持 `Markdown` 更新说明。

- 优化文件夹图标
- [x] 保留系统 Logo 原色

1. 打开设置
2. 检查更新

> 安装前请保存远端工作。

| 功能 | 变化 |
| --- | --- |
| SSH | 优化终端 |
| SFTP | 改进传输 |

```sh
ssh user@example.test
uname -a
```

[版本详情](https://github.com/mingdraw/PagaShell/releases)
''';

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

class _UiUpdates extends AppUpdateController {
  _UiUpdates({required super.connect, required super.settings})
    : super(
        createDownloadConnect: AppConnect.new,
        installer: TestUpdateInstaller(),
      );
  int installCalls = 0;
  int cancelCalls = 0;
  final downloading = Completer<void>();
  @override
  Future<void> install(AppRelease release) async {
    installCalls++;
    phase.value = UpdatePhase.downloading;
    progress.value = 0.4;
    await downloading.future;
    phase.value = UpdatePhase.idle;
  }

  @override
  Future<void> cancelDownload() async {
    cancelCalls++;
    downloading.complete();
  }
}

class _UpdateBinding extends InMemoryBinding {
  _UpdateBinding({
    bool automatic = false,
    String latest = '0.3.0',
    String notes = '修复终端问题',
    this.sessions,
  }) : connect = UpdateConnect(
         handler: () => Response(
           statusCode: 200,
           body: releaseJson(version: latest)..['body'] = notes,
         ),
       ),
       super(
         settingsRepository: InMemorySettingsRepository(
           automaticUpdates: automatic,
         ),
       );
  final UpdateConnect connect;
  final SessionController? sessions;
  late final _UiUpdates updates;
  @override
  void dependencies() {
    super.dependencies();
    if (sessions != null) Get.replace<SessionController>(sessions!);
    updates = Get.put<_UiUpdates>(
      _UiUpdates(connect: connect, settings: Get.find<SettingsController>()),
    );
    Get.put<AppUpdateController>(updates);
  }
}

class _NoEngine extends Fake implements SshEngine {}

class _ExitSessions extends SessionController {
  _ExitSessions(this.events) : super(engine: _NoEngine());
  final List<String> events;
  bool restoreFails = false;
  @override
  Future<void> closeAll() async {
    events.add('close-sessions');
    if (restoreFails) throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
  }
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'FiraCode Nerd Font Mono':
          'assets/fonts/FiraCodeNerdFontMono-Regular.ttf',
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

  setUp(() => Get.locale = AppTranslations.defaultLocale);
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  Future<void> pump(
    WidgetTester tester,
    _UpdateBinding binding, {
    Size size = const Size(1280, 800),
    GlobalKey? captureKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: PagaShellApp(binding: binding, platform: defaultTargetPlatform),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      binding.connect.dispose();
    });
  }

  testWidgets('关于页更新开关可保存，关闭时仍可手动检查、下载并取消', (tester) async {
    final binding = _UpdateBinding();
    await pump(tester, binding);
    expect(binding.connect.calls, 0);
    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('check-for-updates')), findsNothing);
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('automatic-updates-switch'));
    expect(tester.widget<shadcn.Switch>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      (binding.settingsRepository as InMemorySettingsRepository)
          .automaticUpdates,
      isTrue,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      (binding.settingsRepository as InMemorySettingsRepository)
          .automaticUpdates,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('check-for-updates')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.3.0'), findsOneWidget);
    expect(find.text('修复终端问题'), findsOneWidget);
    expect(binding.updates.installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('install-app-update')));
    await tester.pump();
    expect(binding.updates.installCalls, 1);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('暂不更新'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cancel-update-download')));
    await tester.pumpAndSettle();
    expect(binding.updates.cancelCalls, 1);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(find.byType(SettingsDialog), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('启动检查发现新版先询问，不自动下载安装', (tester) async {
    final binding = _UpdateBinding(automatic: true);
    await pump(tester, binding);
    expect(binding.connect.calls, 1);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    expect(binding.updates.installCalls, 0);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(await binding.updates.checkOnStartup(), isNull);
    expect(binding.connect.calls, 1);
  });

  for (final dark in [false, true]) {
    testWidgets('${dark ? '深色' : '浅色'}更新说明渲染 Markdown，长内容滚动且操作保持可见', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final capture = GlobalKey();
      final binding = _UpdateBinding(
        automatic: true,
        notes:
            '$_markdownNotes\n${List.generate(12, (i) => '- 更多优化 ${i + 1}').join('\n')}',
      );
      await pump(
        tester,
        binding,
        size: const Size(640, 480),
        captureKey: capture,
      );
      final dialog = find.byKey(const ValueKey('app-update-dialog'));
      final notes = find.byKey(const ValueKey('app-update-notes'));
      expect(notes, findsOneWidget);
      expect(find.text('更新亮点'), findsOneWidget);
      expect(find.text('修复终端显示，支持 Markdown 更新说明。'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(
        find.text('版本详情 (https://github.com/mingdraw/PagaShell/releases)'),
        findsOneWidget,
      );
      final code = tester.widget<AppMarkdownCodeBlock>(
        find.byType(AppMarkdownCodeBlock),
      );
      expect(code.code, 'ssh user@example.test\nuname -a');
      expect(code.language, 'sh');
      expect(find.text(_markdownNotes), findsNothing);
      final install = find.byKey(const ValueKey('install-app-update'));
      expect(install.hitTestable(), findsOneWidget);
      expect(find.text('暂不更新').hitTestable(), findsOneWidget);
      await _capture(
        tester,
        capture,
        'update-markdown-${dark ? 'dark' : 'light'}-top',
      );
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: dialog,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('更多优化 12').hitTestable(), findsOneWidget);
      expect(install.hitTestable(), findsOneWidget);
      expect(find.text('暂不更新').hitTestable(), findsOneWidget);
      expect(binding.updates.installCalls, 0);
      await _capture(
        tester,
        capture,
        'update-markdown-${dark ? 'dark' : 'light'}-bottom',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('暂不更新'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    });
  }

  testWidgets('手动检查最新版会在关于页显示结果', (tester) async {
    final binding = _UpdateBinding(latest: '0.2.1');
    await pump(tester, binding);
    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-for-updates')));
    await tester.pumpAndSettle();
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    for (final dark in [false, true]) {
      testWidgets(
        '关于页 ${locale.languageCode} ${dark ? '深色' : '浅色'} 介绍、项目链接和更新入口',
        (tester) async {
          tester.platformDispatcher.platformBrightnessTestValue = dark
              ? Brightness.dark
              : Brightness.light;
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          const channel = MethodChannel('plugins.flutter.io/url_launcher');
          final calls = <MethodCall>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              calls.add(call);
              return true;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final capture = GlobalKey();
          await pump(
            tester,
            _UpdateBinding(),
            size: const Size(800, 600),
            captureKey: capture,
          );
          unawaited(Get.updateLocale(locale));
          await tester.pumpAndSettle();
          unawaited(showSettingsDialog());
          await tester.pumpAndSettle();
          expect(find.text('关于'.tr), findsOneWidget);
          expect(
            find.byKey(const ValueKey('automatic-updates-switch')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('check-for-updates')), findsNothing);
          await tester.tap(find.text('关于'.tr));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('about-settings')), findsOneWidget);
          expect(find.text(AppInfo.name), findsOneWidget);
          expect(find.text(AppInfo.repository), findsOneWidget);
          expect(find.text('本地优先的远程服务管理工具'.tr), findsOneWidget);
          expect(
            find.byKey(const ValueKey('automatic-updates-switch')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('check-for-updates')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('ai-model-save')), findsNothing);
          expect(find.byKey(const ValueKey('ai-model-test')), findsNothing);
          await _capture(
            tester,
            capture,
            'about-${locale.languageCode}-${dark ? 'dark' : 'light'}-top',
          );
          final project = find.byKey(const ValueKey('about-github-link'));
          await tester.ensureVisible(project);
          await tester.pumpAndSettle();
          await tester.tap(project);
          await tester.pumpAndSettle();
          expect(calls, hasLength(1));
          expect(calls.single.method, 'launch');
          expect(
            calls.single.arguments,
            containsPair('url', AppInfo.repository),
          );
          expect(calls.single.arguments, containsPair('useWebView', false));
          expect(calls.single.arguments, containsPair('useSafariVC', false));
          final check = find.byKey(const ValueKey('check-for-updates'));
          await tester.ensureVisible(check);
          await tester.pumpAndSettle();
          expect(check.hitTestable(), findsOneWidget);
          expect(find.text('关闭'.tr).hitTestable(), findsOneWidget);
          await _capture(
            tester,
            capture,
            'about-${locale.languageCode}-${dark ? 'dark' : 'light'}-updates',
          );
          expect(tester.takeException(), isNull);
          AppNavigation.closeDialog<void>();
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('项目主页打开失败时提示复制地址，关于页仍可使用', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pump(tester, _UpdateBinding());
    unawaited(showSettingsDialog());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('about-github-link')));
    await tester.pumpAndSettle();
    expect(find.text('无法打开项目主页，请复制地址后在浏览器中打开'), findsOneWidget);
    expect(find.text(AppInfo.repository), findsOneWidget);
    expect(
      find.byKey(const ValueKey('check-for-updates')).hitTestable(),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 更新退出先关闭会话，提交后再销毁原生窗口', (tester) async {
      final events = <String>[];
      final sessions = _ExitSessions(events);
      final binding = _UpdateBinding(sessions: sessions);
      final messenger = tester.binding.defaultBinaryMessenger;
      for (final name in ['pagashell/window', 'window_manager']) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'destroy') events.add(name);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      await pump(tester, binding);
      final result = await binding.updates.exitForUpdate!(() async {
        events.add('commit');
      });
      expect(result, isTrue);
      expect(events, [
        'close-sessions',
        'commit',
        platform == TargetPlatform.windows
            ? 'pagashell/window'
            : 'window_manager',
      ]);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('代理恢复失败时更新退出不提交，也不销毁窗口', (tester) async {
    final events = <String>[];
    final sessions = _ExitSessions(events)..restoreFails = true;
    final binding = _UpdateBinding(sessions: sessions);
    await pump(tester, binding);
    expect(
      await binding.updates.exitForUpdate!(() async {
        events.add('commit');
      }),
      isFalse,
    );
    await tester.pump();
    expect(events, ['close-sessions']);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
