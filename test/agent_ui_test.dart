import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/ai/ai_model.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/ai/agent_input_controller.dart';
import 'package:pagashell/presentation/ai/agent_message_body.dart';
import 'package:pagashell/presentation/ai/agent_workspace.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/shell/widgets/window_controls.dart';
import 'package:pagashell/presentation/shell/widgets/workspace.dart';
import 'package:pagashell/presentation/terminal/server_status_panel.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:xterm/xterm.dart';

import 'support/fake_ai_connect.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

class _Binding extends InMemoryBinding {
  _Binding(this.connect);
  final GetConnect connect;
  @override
  void dependencies() {
    super.dependencies();
    Get.replace<GetConnect>(connect, tag: 'ai');
  }
}

class _SshSession extends Fake implements SshEngineSession {
  @override
  Future<void> close() async {}
}

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

void main() {
  setUpAll(() async {
    // 尺寸与溢出断言始终使用应用字体，不依赖是否导出截图。
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
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
  tearDown(() async {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  Future<GlobalKey> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    FakeAiConnect? connect,
    TargetPlatform platform = TargetPlatform.macOS,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PagaShellApp(
          binding: _Binding(
            connect ?? FakeAiConnect((_) => openAiReply('Hello')),
          ),
          platform: platform,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> openModelEditor(WidgetTester tester) async {
    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 设置'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpModelOptions(WidgetTester tester) async {
    // shadcn 锚定弹层打开时持续追踪位置，不会进入 pumpAndSettle 的静止状态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> configure(WidgetTester tester) async {
    await openModelEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-url')),
      'https://api.test/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-id')),
      'test-model',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-key')),
      'test-key',
    );
    await tester.tap(find.byKey(const ValueKey('ai-model-save')));
    await tester.pumpAndSettle();
    expect(Get.find<AiSettingsController>().state.value.models, hasLength(1));
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '关闭'));
    await tester.pumpAndSettle();
  }

  testWidgets('模型配置支持 Responses、空地址、Key 前置、刷新选择和手动输入', (tester) async {
    final connect = FakeAiConnect(
      (_) => responsesReply([responsesText('OK')]),
      getHandler: (_) => const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {'id': 'provider-beta'},
            {'id': 'provider-alpha'},
          ],
        },
      ),
    );
    final capture = await pump(tester, connect: connect);
    await openModelEditor(tester);
    final url = find.byKey(const ValueKey('ai-model-url'));
    final key = find.byKey(const ValueKey('ai-model-key'));
    final model = find.byKey(const ValueKey('ai-model-id'));
    expect(tester.widget<AppTextFormField>(url).controller.text, isEmpty);
    expect(find.text('https://api.openai.com/v1'), findsWidgets);
    expect(tester.getRect(key).top, lessThan(tester.getRect(model).top));
    final modelInput = tester.getRect(
      find.descendant(of: model, matching: find.byType(shadcn.TextField)),
    );
    for (final field in [url, key]) {
      final input = tester.getRect(
        find.descendant(of: field, matching: find.byType(shadcn.TextField)),
      );
      expect(modelInput.height, closeTo(input.height, 0.01));
      expect(modelInput.width, input.width);
    }
    final refresh = tester.getRect(
      find.byKey(const ValueKey('ai-model-refresh')),
    );
    expect(refresh.center.dy, tester.getRect(find.text('默认模型 ID')).center.dy);
    expect(refresh.right, modelInput.right);
    expect(refresh.bottom, lessThan(modelInput.top));
    expect(
      find.byKey(const ValueKey('ai-model-test')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('最大输出 Token'), findsNothing);
    await tester.tap(find.byType(shadcn.Select<AiApiFormat>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI Responses').last);
    await tester.pumpAndSettle();
    expect(tester.widget<AppTextFormField>(url).controller.text, isEmpty);
    expect(find.byKey(const ValueKey('ai-add-model')), findsNothing);
    expect(find.byKey(const ValueKey('ai-model-name')), findsNothing);
    await tester.enterText(url, 'https://provider.test/custom/v1/responses');
    await tester.enterText(key, 'draft-key');
    await _capture(tester, capture, 'ai-model-form-responses');
    await tester.tap(find.byKey(const ValueKey('ai-model-refresh')));
    await pumpModelOptions(tester);
    expect(connect.requests.single.method, 'GET');
    expect(Uri.parse(connect.requests.single.url!).path, '/custom/v1/models');
    expect(
      connect.requests.single.headers!['Authorization'],
      'Bearer draft-key',
    );
    expect(find.text('provider-beta').hitTestable(), findsOneWidget);
    await _capture(tester, capture, 'ai-model-dropdown');
    await tester.tap(find.text('provider-beta').hitTestable());
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppTextFormField>(model).controller.text,
      'provider-beta',
    );
    expect(find.text('provider-alpha').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-model-options')));
    await pumpModelOptions(tester);
    expect(find.text('provider-alpha').hitTestable(), findsOneWidget);
    await tester.tap(find.text('provider-alpha').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(model, 'manual-model-id');
    await tester.tap(find.byKey(const ValueKey('ai-model-save')));
    await tester.pumpAndSettle();
    final saved = Get.find<AiSettingsController>().state.value.selectedModel!;
    expect(saved.format, AiApiFormat.openaiResponses);
    expect(saved.model, 'manual-model-id');
    expect(saved.toJson(), isNot(contains('maxTokens')));
    expect(find.text('AI 设置已保存').hitTestable(), findsOneWidget);
    expect(tester.widget<AppTextFormField>(key).controller.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-model-refresh')));
    await pumpModelOptions(tester);
    expect(connect.requests.last.headers!['Authorization'], 'Bearer draft-key');
    await tester.tap(find.text('provider-beta').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(
      Get.find<AiSettingsController>().state.value.selectedModel!.model,
      'manual-model-id',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('底部测试使用未保存配置，显示结果且不保存模型，可在测试中取消', (tester) async {
    final pending = Completer<Response<dynamic>>();
    final lateReply = Completer<Response<dynamic>>();
    var requests = 0;
    final connect = FakeAiConnect(
      (_) => switch (++requests) {
        1 => pending.future,
        2 => const Response<dynamic>(statusCode: 401, body: 'private-key'),
        _ => lateReply.future,
      },
    );
    final capture = await pump(tester, connect: connect);
    await openModelEditor(tester);
    final testButton = find.byKey(const ValueKey('ai-model-test'));
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(connect.requests, isEmpty);
    expect(find.text('请输入有效的 API 地址，不含账号、查询参数或片段'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-url')),
      'https://draft.test/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-key')),
      'private-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-id')),
      'draft-model',
    );
    // 测试直接使用当前表单，无需先保存。
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(find.text('正在测试'), findsOneWidget);
    expect(tester.widget<shadcn.OutlineButton>(testButton).onPressed, isNull);
    expect(
      tester
          .widget<shadcn.PrimaryButton>(
            find.byKey(const ValueKey('ai-model-save')),
          )
          .onPressed,
      isNull,
    );
    expect(connect.requests, hasLength(1));
    expect(
      connect.requests.single.url,
      'https://draft.test/v1/chat/completions',
    );
    expect(connect.requests.single.body['model'], 'draft-model');
    expect(
      connect.requests.single.headers!['Authorization'],
      'Bearer private-key',
    );
    expect(Get.find<AiSettingsController>().state.value.models, isEmpty);
    pending.complete(openAiReply('OK'));
    await tester.pumpAndSettle();
    expect(find.text('AI 模型连接成功').hitTestable(), findsOneWidget);
    expect(Get.find<AgentController>().entries, isEmpty);
    await _capture(tester, capture, 'ai-model-connection-success');
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-id')),
      'another-model',
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 模型连接成功'), findsNothing);
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(find.text('AI API 认证失败，请检查 API Key'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains('private-key') ?? false),
      ),
      findsNothing,
    );
    expect(Get.find<AiSettingsController>().state.value.models, isEmpty);
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    lateReply.complete(openAiReply('Late OK'));
    await tester.pumpAndSettle();
    expect(find.text('AI 模型连接成功'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换 API 配置丢弃迟到模型列表，刷新失败仍可手动保存', (tester) async {
    final pending = Completer<Response<dynamic>>();
    var requests = 0;
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (_) => ++requests == 1
          ? pending.future
          : const Response<dynamic>(statusCode: 404, body: 'private-key'),
    );
    await pump(tester, connect: connect);
    await openModelEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-url')),
      'https://old.test/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-key')),
      'private-key',
    );
    await tester.tap(find.byKey(const ValueKey('ai-model-refresh')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-url')),
      'https://new.test/v1',
    );
    pending.complete(
      const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {'id': 'old-model'},
          ],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('old-model'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-model-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('模型列表获取失败，请检查 API 地址或手动填写模型 ID'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-model-id')),
      'typed-model',
    );
    await tester.tap(find.byKey(const ValueKey('ai-model-save')));
    await tester.pumpAndSettle();
    expect(
      Get.find<AiSettingsController>().state.value.selectedModel!.model,
      'typed-model',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [false, true]) {
    testWidgets('Agent ${dark ? '深色' : '浅色'}窄栏回复使用 Markdown，恢复历史继续显示格式', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      const reply = '''
### 检查结果

**SSH** 已连接，*建议*按步骤排查。

1. 查看 `systemctl status sshd`
2. 检查防火墙规则

> 终端输出不等于命令已经执行成功。

| 检查项 | 状态 |
| :--- | ---: |
| SSH | 正常 |
| RDP | 待检查 |

```sh
df -h
ss -lntp
```
''';
      final capture = await pump(
        tester,
        size: const Size(800, 600),
        connect: FakeAiConnect((_) => openAiReply(reply)),
      );
      await configure(tester);
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-input')),
        '**保留我的原文**',
      );
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pumpAndSettle();
      expect(find.text('检查结果'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(
        tester.widget<AgentCodeBlock>(find.byType(AgentCodeBlock)).code,
        'df -h\nss -lntp',
      );
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('agent-messages')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await _capture(
        tester,
        capture,
        'agent-markdown-bottom-${dark ? 'dark' : 'light'}',
      );
      scrollable.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('**保留我的原文**'), findsOneWidget);
      await _capture(
        tester,
        capture,
        'agent-markdown-top-${dark ? 'dark' : 'light'}',
      );
      final agent = Get.find<AgentController>();
      final saved = agent.currentConversationId.value!;
      await tester.tap(find.byKey(const ValueKey('agent-new-chat')));
      await tester.pumpAndSettle();
      expect(agent.openConversation(saved), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('检查结果'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('设置创建模型后聊天可发送，左右收缩保留输入和聊天，拖动保存宽度', (tester) async {
    final key = await pump(
      tester,
      connect: FakeAiConnect(
        (_) => openAiReply('Use a separate SFTP tab.\n```sh\ndf -h\n```'),
      ),
    );
    await configure(tester);
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-panel')).hitTestable(),
      findsOneWidget,
    );
    final input = find.byKey(const ValueKey('agent-input'));
    await tester.enterText(input, 'Explain SFTP');
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(find.text('Explain SFTP'), findsOneWidget);
    expect(find.byType(AgentCodeBlock), findsOneWidget);
    await tester.enterText(input, 'Unsent draft');
    final width = tester
        .getSize(find.byKey(const ValueKey('agent-panel')))
        .width;
    await tester.drag(
      find.byKey(const ValueKey('agent-resize-handle')),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();
    expect(
      Get.find<AiSettingsController>().state.value.panelWidth,
      greaterThan(width),
    );
    await _capture(tester, key, 'agent-workspace');
    await tester.tap(findAppIconButton('收起 Agent'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-panel')).hitTestable(),
      findsNothing,
    );
    await _capture(tester, key, 'agent-collapsed');
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppTextFormField>(input).controller.text,
      'Unsent draft',
    );
    expect(find.text('Explain SFTP'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Agent 标题显示设置模型，无刷新和模型下拉，输入框可选择思考强度', (tester) async {
    final connect = FakeAiConnect(
      (_) => openAiReply('OK'),
      getHandler: (_) => const Response<dynamic>(
        statusCode: 200,
        body: {
          'data': [
            {'id': 'api-beta'},
            {'id': 'api-alpha'},
          ],
        },
      ),
    );
    final capture = await pump(tester, connect: connect);
    await configure(tester);
    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();
    final agent = Get.find<AgentController>();
    expect(agent.currentModel!.model, 'test-model');
    expect(find.text('test-model').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-model-select')), findsNothing);
    expect(find.byKey(const ValueKey('agent-model-refresh')), findsNothing);
    expect(find.byKey(const ValueKey('agent-model-name')), findsOneWidget);
    final title = tester.getRect(find.text('Agent').first);
    final model = tester.getRect(
      find.byKey(const ValueKey('agent-model-name')),
    );
    expect(model.left, greaterThan(title.right));
    expect(model.center.dy, closeTo(title.center.dy, 1));
    expect(
      find.byKey(const ValueKey('agent-history')).hitTestable(),
      findsOneWidget,
    );
    expect(
      Get.find<AiSettingsController>().state.value.apiConfig!.model,
      'test-model',
    );
    final reasoning = find.byKey(const ValueKey('agent-reasoning-select'));
    final input = find.descendant(
      of: find.byKey(const ValueKey('agent-input')),
      matching: find.byType(shadcn.TextField),
    );
    expect(tester.getRect(input).contains(tester.getCenter(reasoning)), isTrue);
    await tester.tap(reasoning);
    await pumpModelOptions(tester);
    expect(find.text('最高').hitTestable(), findsOneWidget);
    await _capture(tester, capture, 'agent-reasoning-options');
    await tester.tap(find.text('高').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('高').hitTestable(), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('agent-input')),
      'Think about SSH',
    );
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(connect.requests.last.body['model'], 'test-model');
    expect(connect.requests.last.body['reasoning_effort'], 'high');
    await _capture(tester, capture, 'agent-model-reasoning');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final english in [false, true]) {
    testWidgets('历史对话可找回续聊和删除，800×600 ${english ? '英文' : '中文'}布局', (
      tester,
    ) async {
      final connect = FakeAiConnect((_) => openAiReply('Saved reply'));
      final capture = await pump(
        tester,
        connect: connect,
        size: const Size(800, 600),
      );
      await configure(tester);
      if (english) {
        unawaited(Get.updateLocale(const Locale('en', 'US')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      final agent = Get.find<AgentController>();
      await tester.enterText(
        find.byKey(const ValueKey('agent-input')),
        'First saved chat',
      );
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pumpAndSettle();
      final first = agent.currentConversationId.value!;
      await tester.tap(find.byKey(const ValueKey('agent-new-chat')));
      await tester.pumpAndSettle();
      expect(agent.entries, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('agent-input')),
        'Second saved chat',
      );
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pumpAndSettle();
      final second = agent.currentConversationId.value!;
      await tester.tap(find.byKey(const ValueKey('agent-history')));
      await tester.pumpAndSettle();
      expect(find.text('First saved chat').hitTestable(), findsOneWidget);
      expect(find.text('Second saved chat').hitTestable(), findsOneWidget);
      expect(find.text(english ? 'Close' : '关闭').hitTestable(), findsOneWidget);
      await _capture(tester, capture, 'agent-history-${english ? 'en' : 'zh'}');
      await tester.tap(find.byKey(ValueKey('agent-history-open-$first')));
      await tester.pumpAndSettle();
      expect(agent.currentConversationId.value, first);
      expect(agent.entries.first.text, 'First saved chat');
      await tester.enterText(
        find.byKey(const ValueKey('agent-input')),
        'Continue saved chat',
      );
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pumpAndSettle();
      expect(
        jsonEncode(connect.requests.last.body),
        contains('First saved chat'),
      );
      expect(
        jsonEncode(connect.requests.last.body),
        isNot(contains('Second saved chat')),
      );
      await tester.tap(find.byKey(const ValueKey('agent-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('agent-history-delete-$first')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('agent-history-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(agent.currentConversationId.value, isNull);
      expect(agent.entries, isEmpty);
      expect(find.byKey(ValueKey('agent-history-open-$first')), findsNothing);
      await tester.tap(find.byKey(ValueKey('agent-history-delete-$second')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('agent-history-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(english ? 'No chat history yet' : '暂无历史对话'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.widgetWithText(shadcn.OutlineButton, english ? 'Close' : '关闭'),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('系统退出请求会停止当前请求并完成对话保存', (tester) async {
    final response = Completer<Response<dynamic>>();
    await pump(tester, connect: FakeAiConnect((_) => response.future));
    await configure(tester);
    await tester.tap(find.byKey(const ValueKey('agent-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-input')),
      'Save before exit',
    );
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pump();
    final agent = Get.find<AgentController>();
    expect(agent.busy.value, isTrue);
    final exit = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(await exit, ui.AppExitResponse.exit);
    expect(agent.busy.value, isFalse);
    expect(agent.conversations.single.messages.first.text, 'Save before exit');
    response.complete(openAiReply('Late exit response'));
    await tester.pumpAndSettle();
    expect(agent.entries, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final english in [false, true]) {
    testWidgets('会话 Popover ${english ? '英文' : '中文'}支持末项滚动定位、RDP 和快速重新打开', (
      tester,
    ) async {
      final capture = await pump(tester, size: const Size(800, 600));
      await configure(tester);
      if (english) {
        unawaited(Get.updateLocale(const Locale('en')));
        await tester.pumpAndSettle();
      }
      final sessions = Get.find<SessionController>();
      sessions.sessions.addAll([
        for (var i = 0; i < 9; i++)
          Session(
            id: 'ssh-$i',
            host: Host(id: 'ssh-$i', name: 'Server $i', hostname: '$i.test'),
            phase: SessionPhase.ready,
            engineSession: _SshSession(),
            terminal: Terminal(onOutput: (_) {}),
          ),
        const Session(
          id: 'rdp',
          kind: SessionKind.remoteDesktop,
          phase: SessionPhase.ready,
          host: Host(
            id: 'rdp',
            name: 'Windows desktop',
            hostname: 'desktop.test',
            serviceType: ServiceType.rdp,
            port: 3389,
          ),
        ),
      ]);
      sessions.activeSessionId.value = 'ssh-0';
      await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
      // 候选专用 RDP 快照未挂真实桌面，后台占位动画持续调度帧。
      await pumpModelOptions(tester);
      final input = find.byKey(const ValueKey('agent-input'));
      final popover = find.byKey(const ValueKey('agent-mention-popover'));
      final last = find.byKey(const ValueKey('agent-mention-rdp'));
      await tester.enterText(input, '@');
      await pumpModelOptions(tester);
      expect(last.hitTestable(), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await pumpModelOptions(tester);
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.widget<shadcn.SelectedButton>(last).value, isTrue);
      expect(
        find
            .text('Windows desktop · ${english ? 'Remote desktop' : '远程桌面'}')
            .hitTestable(),
        findsOneWidget,
      );
      await _capture(
        tester,
        capture,
        'agent-mention-scroll-${english ? 'en' : 'zh'}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpModelOptions(tester);
      expect(
        find.byKey(const ValueKey('agent-mention-ssh-0')).hitTestable(),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpModelOptions(tester);
      expect(popover, findsNothing);
      await tester.pump();
      expect(popover, findsNothing);
      await tester.enterText(input, '@Windows');
      await pumpModelOptions(tester);
      expect(popover, findsOneWidget);
      expect(last.hitTestable(), findsOneWidget);
      // 关闭动画尚未结束时再打开，也不复用旧弹层的 GlobalKey。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.enterText(input, '@desktop.test');
      await pumpModelOptions(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpModelOptions(tester);
      final agent = Get.find<AgentController>();
      expect(agent.selectedSessions.single.id, 'rdp');
      expect(agent.entries, isEmpty);
      // 曾经按 Escape 关闭过相同查询，完成选择后再次输入 @ 仍可打开。
      await tester.enterText(input, '@');
      await pumpModelOptions(tester);
      expect(popover, findsOneWidget);
      expect(tester.getSize(popover).width, 300);
      await _capture(
        tester,
        capture,
        'agent-mention-group-${english ? 'en' : 'zh'}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpModelOptions(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform Agent 独立于主区域，滑动收放且窗口按钮位置不变', (tester) async {
      final key = await pump(tester, platform: platform);
      final viewport = find.byKey(const ValueKey('agent-sidebar-viewport'));
      final workspace = find.byType(Workspace);
      final panel = find.byKey(const ValueKey('agent-panel'));
      final closedBounds = tester.getRect(workspace);
      final windowButtons = platform == TargetPlatform.macOS
          ? null
          : tester.getRect(find.byType(WindowButtons));
      expect(tester.getSize(viewport).width, 0);
      expect(
        tester.getRect(find.byKey(const ValueKey('agent-toggle'))).right,
        windowButtons?.left ?? tester.view.physicalSize.width,
      );

      await tester.tap(findAppIconButton('AI Agent'));
      await tester.pump();
      await tester.pump(AppTheme.sidebarTransitionDuration ~/ 2);
      final openingWidth = tester.getSize(viewport).width;
      final panelWidth = tester.getSize(panel).width;
      expect(openingWidth, greaterThan(0));
      expect(openingWidth, lessThan(panelWidth));
      expect(tester.getSize(panel).width, panelWidth);
      expect(tester.getRect(workspace).right, lessThan(closedBounds.right));
      await _capture(tester, key, 'agent-slide-opening-${platform.name}');
      await tester.pumpAndSettle();

      final openedBounds = tester.getRect(workspace);
      final openedWidth = tester.getSize(viewport).width;
      expect(openedBounds.left, closedBounds.left);
      expect(openedBounds.top, closedBounds.top);
      expect(openedBounds.bottom, closedBounds.bottom);
      expect(openedBounds.right, tester.getRect(viewport).left);
      expect(tester.getRect(panel).top, AppTheme.windowHeaderHeight);
      final collapse = find.byKey(const ValueKey('agent-toggle'));
      expect(tester.getRect(collapse).left, tester.getRect(panel).left);
      expect(
        find.descendant(
          of: collapse,
          matching: find.byIcon(shadcn.LucideIcons.panelRightClose),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: panel, matching: find.byType(Workspace)),
        findsNothing,
      );
      expect(
        find.ancestor(of: panel, matching: find.byType(shadcn.TabPane<String>)),
        findsNothing,
      );
      if (windowButtons != null) {
        expect(tester.getRect(find.byType(WindowButtons)), windowButtons);
      }
      await _capture(tester, key, 'agent-independent-${platform.name}');

      await tester.tap(findAppIconButton('收起 Agent'));
      await tester.pump();
      await tester.pump(AppTheme.sidebarTransitionDuration ~/ 2);
      expect(tester.getSize(viewport).width, greaterThan(0));
      expect(tester.getSize(viewport).width, lessThan(openedWidth));
      expect(tester.getSize(panel).width, panelWidth);
      expect(tester.getRect(workspace).right, greaterThan(openedBounds.right));
      if (windowButtons != null) {
        expect(tester.getRect(find.byType(WindowButtons)), windowButtons);
      }
      await tester.pumpAndSettle();
      expect(tester.getSize(viewport).width, 0);
      expect(tester.getRect(workspace), closedBounds);
      expect(findAppIconButton('AI Agent').hitTestable(), findsOneWidget);
      expect(panel.hitTestable(), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('sidebar-toggle'))).left,
        platform == TargetPlatform.macOS ? AppTheme.macWindowControlsWidth : 0,
      );
      await _capture(tester, key, 'header-both-collapsed-${platform.name}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$platform 800x600 Agent 展开及设置长表单按钮可见，中英文无溢出', (tester) async {
      final key = await pump(
        tester,
        size: const Size(800, 600),
        platform: platform,
        connect: FakeAiConnect(
          (_) => openAiReply('OK'),
          getHandler: (_) => const Response<dynamic>(
            statusCode: 200,
            body: {
              'data': [
                {'id': 'model-alpha'},
                {'id': 'model-beta'},
              ],
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-panel')).hitTestable(),
        findsOneWidget,
      );
      final workspace = tester.getRect(find.byType(Workspace));
      final rightBar = tester.getRect(
        find.byKey(const ValueKey('agent-sidebar-viewport')),
      );
      expect(workspace.right, rightBar.left);
      expect(
        workspace.width,
        greaterThanOrEqualTo(AppTheme.agentMinWorkspaceWidth),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-viewport'))).width,
        0,
      );
      expect(Get.find<SettingsController>().sidebarState.value.visible, isTrue);
      await _capture(tester, key, 'agent-small-${platform.name}');
      await tester.tap(findAppIconButton('AI 设置'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'agent-settings-${platform.name}');
      expect(
        find.byKey(const ValueKey('ai-model-save')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-model-test')).hitTestable(),
        findsOneWidget,
      );
      await _capture(tester, key, 'agent-model-form-${platform.name}');
      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(shadcn.Select<Locale>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await tester.tap(find.text('English').last);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.text('General'), findsOneWidget);
      expect(find.text('AI settings'), findsOneWidget);
      await tester.tap(find.text('AI settings'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-model-url')),
        'https://api.test/v1',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('ai-model-key')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-model-key')),
        'test-key',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('ai-model-id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-model-refresh')));
      await pumpModelOptions(tester);
      expect(find.text('model-alpha').hitTestable(), findsOneWidget);
      await _capture(
        tester,
        key,
        'ai-model-dropdown-small-en-${platform.name}',
      );
      await tester.tap(find.text('model-alpha').hitTestable());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-model-id')),
        'manual-small',
      );
      expect(
        find.byKey(const ValueKey('ai-model-save')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('ai-model-test')));
      await tester.pumpAndSettle();
      expect(
        find.text('AI model connected successfully').hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-model-test')).hitTestable(),
        findsOneWidget,
      );
      await _capture(tester, key, 'ai-model-test-small-en-${platform.name}');
      await tester.tap(find.byKey(const ValueKey('ai-model-save')));
      await tester.pumpAndSettle();
      expect(
        Get.find<AiSettingsController>().state.value.selectedModel!.model,
        'manual-small',
      );
      await tester.tap(find.widgetWithText(shadcn.OutlineButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.text('Your operations assistant'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-reasoning-select')));
      await pumpModelOptions(tester);
      await tester.tap(find.text('Extra high').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Extra high').hitTestable(), findsOneWidget);
      await _capture(tester, key, 'agent-reasoning-small-en-${platform.name}');
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-viewport'))).width,
        AppTheme.sidebarWidth,
      );
      expect(Get.find<SettingsController>().sidebarState.value.visible, isTrue);
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sidebar-toggle')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('agent-sidebar-viewport')))
            .width,
        0,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-viewport'))).width,
        AppTheme.sidebarWidth,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Agent 收起后主区域恢复全部宽度，窗口切换保留终端及聊天草稿', (tester) async {
    await pump(tester);
    final terminal = Terminal()..write('preserved terminal output');
    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 'preserve',
        host: const Host(id: 'preserve', name: 'Server', hostname: 'test'),
        phase: SessionPhase.ready,
        terminal: terminal,
      ),
    );
    sessions.activeSessionId.value = 'preserve';
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(
      tester.getRect(find.byType(Workspace)).right,
      tester.getRect(find.byType(AgentWorkspace)).right,
    );
    expect(
      tester.getRect(find.byType(Workspace)).left,
      tester.getSize(find.byKey(const ValueKey('sidebar-viewport'))).width,
    );
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-input')),
      'keep draft',
    );
    for (final size in [const Size(800, 600), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        tester.state<TerminalViewState>(find.byType(TerminalView)),
        same(state),
      );
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
        same(terminal),
      );
      expect(
        tester
            .widget<AppTextFormField>(find.byKey(const ValueKey('agent-input')))
            .controller
            .text,
        'keep draft',
      );
      await tester.tap(findAppIconButton('收起 Agent'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(Workspace)).right,
        tester.getRect(find.byType(AgentWorkspace)).right,
      );
      expect(
        tester.getRect(find.byType(Workspace)).left,
        tester.getSize(find.byKey(const ValueKey('sidebar-viewport'))).width,
      );
      final pane = tester.widget<shadcn.TabPane<String>>(
        find.byType(shadcn.TabPane<String>),
      );
      expect(
        tester.getRect(find.byType(ServerStatusPanel)),
        tester.getRect(find.byWidget(pane.child)),
      );
      expect(
        tester.state<TerminalViewState>(find.byType(TerminalView)),
        same(state),
      );
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppTextFormField>(find.byKey(const ValueKey('agent-input')))
            .controller
            .text,
        'keep draft',
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('@ 分组 Popover 使用会话页签命名和独立宽度，选择目标沿用审核模式', (tester) async {
    final capture = await pump(tester, size: const Size(800, 600));
    await configure(tester);
    final sessions = Get.find<SessionController>();
    final first = Session(
      id: 'first',
      host: const Host(
        id: 'first',
        name: 'Server alpha',
        hostname: 'alpha.test',
      ),
      phase: SessionPhase.ready,
      engineSession: _SshSession(),
      terminal: Terminal(onOutput: (_) {}),
    );
    final second = Session(
      id: 'second',
      host: const Host(
        id: 'second',
        name: 'Server beta',
        hostname: 'beta.test',
      ),
      phase: SessionPhase.ready,
      engineSession: _SshSession(),
      terminal: Terminal(onOutput: (_) {}),
    );
    sessions.sessions.addAll([
      first,
      second,
      const Session(
        id: 'connecting',
        phase: SessionPhase.failed,
        host: Host(
          id: 'connecting',
          name: 'Connecting',
          hostname: 'connecting.test',
        ),
      ),
    ]);
    sessions.activeSessionId.value = second.id;
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('agent-input'));
    expect(find.byKey(const ValueKey('agent-share-context')), findsNothing);
    expect(Get.find<AgentController>().selectedSessions, isEmpty);
    final addContext = find.byKey(const ValueKey('agent-add-context'));
    final controller =
        tester.widget<AppTextFormField>(input).controller
            as AgentInputController;
    expect(
      tester.getRect(input).contains(tester.getCenter(addContext)),
      isTrue,
    );
    await tester.tap(addContext);
    await pumpModelOptions(tester);
    expect(find.text('Server alpha · 终端').hitTestable(), findsOneWidget);
    expect(find.text('Server beta · 终端').hitTestable(), findsOneWidget);
    expect(controller.text, isEmpty);
    await _capture(tester, capture, 'agent-context-plus-small');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-mention-popover')), findsNothing);
    await tester.enterText(input, 'Keep this draft');
    controller.selection = const TextSelection(baseOffset: 5, extentOffset: 9);
    await tester.pump();
    await tester.tap(addContext);
    await pumpModelOptions(tester);
    await tester.tap(find.text('Server alpha · 终端').hitTestable());
    await tester.pumpAndSettle();
    expect(Get.find<AgentController>().selectedSessions.single.id, first.id);
    expect(controller.text, 'Keep @Server alpha  draft');
    expect(controller.selection.extentOffset, 'Keep @Server alpha '.length);
    expect(
      controller.mentions.single.range.textInside(controller.text),
      '@Server alpha',
    );
    await tester.enterText(input, 'Check @alpha');
    await pumpModelOptions(tester);
    final popover = find.byKey(const ValueKey('agent-mention-popover'));
    expect(
      find.byKey(const ValueKey('agent-mention-group-sessions')),
      findsOneWidget,
    );
    expect(tester.getSize(popover).width, 300);
    expect(tester.getSize(popover).width, isNot(tester.getSize(input).width));
    expect(find.text('Server alpha · 终端').hitTestable(), findsOneWidget);
    expect(find.text('Server beta · 终端').hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-mention-connecting')),
      findsNothing,
    );
    await _capture(tester, capture, 'agent-session-mentions-small');
    sessions.sessions.remove(first);
    await pumpModelOptions(tester);
    expect(find.text('Server alpha · 终端').hitTestable(), findsNothing);
    sessions.sessions.add(first);
    await pumpModelOptions(tester);
    expect(find.text('Server alpha · 终端').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final agent = Get.find<AgentController>();
    expect(agent.selectedSessions.single.id, first.id);
    expect(agent.entries, isEmpty);
    expect(controller.text, 'Check @Server alpha ');
    expect(find.byKey(const ValueKey('agent-selected-session')), findsNothing);
    final reasoning = find.byKey(const ValueKey('agent-reasoning-select'));
    final access = find.byKey(const ValueKey('agent-access-select'));
    final field = find.descendant(
      of: input,
      matching: find.byType(shadcn.TextField),
    );
    expect(tester.getRect(field).contains(tester.getCenter(reasoning)), isTrue);
    expect(tester.getRect(field).contains(tester.getCenter(access)), isTrue);
    await tester.tap(access);
    await pumpModelOptions(tester);
    await tester.tap(find.text('完全访问').hitTestable());
    await tester.pumpAndSettle();
    expect(agent.accessMode.value, AgentAccessMode.fullAccess);
    await _capture(tester, capture, 'agent-session-access-small');
    await tester.enterText(input, '${controller.text}@beta');
    await pumpModelOptions(tester);
    await tester.tap(find.text('Server beta · 终端').hitTestable());
    await tester.pumpAndSettle();
    expect(agent.selectedSessions.map((s) => s.id), [first.id, second.id]);
    expect(controller.text, 'Check @Server alpha @Server beta ');
    expect(controller.mentions, hasLength(2));
    expect(agent.accessMode.value, AgentAccessMode.fullAccess);
    // 删除第一个引用中的任意字符，只解除这个引用；第二个范围随文本移动。
    final firstMention = controller.mentions.first.range;
    controller.selection = TextSelection.collapsed(offset: firstMention.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await pumpModelOptions(tester);
    expect(agent.selectedSessions.single.id, second.id);
    expect(
      controller.mentions.single.range.textInside(controller.text),
      '@Server beta',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _capture(tester, capture, 'agent-inline-multiple-mentions-small');
    await tester.enterText(input, 'Keep @beta');
    await pumpModelOptions(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(agent.selectedSessions.single.id, second.id);
    expect(controller.text, 'Keep @Server beta ');
    await tester.enterText(input, 'line-one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(agent.entries, isEmpty);
    expect(
      tester.widget<AppTextFormField>(input).controller.text,
      'line-one\n',
    );
    await tester.enterText(input, 'line-one\nline-two');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(agent.entries.first.text, 'line-one\nline-two');
    expect(tester.widget<AppTextFormField>(input).controller.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('agent-new-chat')));
    await tester.pumpAndSettle();
    expect(agent.accessMode.value, AgentAccessMode.fullAccess);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('@ 候选随连续输入和退格实时过滤，支持空格与中文组词且保留焦点', (tester) async {
    await pump(tester, size: const Size(800, 600));
    await configure(tester);
    Get.find<SessionController>().sessions.addAll([
      for (final (id, name) in [
        ('alpha', 'Web 服务 Alpha'),
        ('beta', 'Web 服务 Beta'),
        ('db', 'Database'),
      ])
        Session(
          id: id,
          host: Host(id: id, name: name, hostname: '$id.example'),
          phase: SessionPhase.ready,
          engineSession: _SshSession(),
          terminal: Terminal(),
        ),
    ]);
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('agent-input'));
    final controller =
        tester.widget<AppTextFormField>(input).controller
            as AgentInputController;
    final focus = tester
        .widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)),
        )
        .focusNode;
    final popover = find.byKey(const ValueKey('agent-mention-popover'));
    final alpha = find.byKey(const ValueKey('agent-mention-alpha'));
    final beta = find.byKey(const ValueKey('agent-mention-beta'));
    final db = find.byKey(const ValueKey('agent-mention-db'));
    await tester.showKeyboard(input);
    Future<void> type(
      String text, {
      TextRange composing = TextRange.empty,
    }) async {
      // 只在开始时请求焦点，后续输入通过同一个平台输入连接连续更新。
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: composing,
        ),
      );
      await pumpModelOptions(tester);
      expect(focus.hasFocus, isTrue);
    }

    await type('@');
    expect(alpha, findsOneWidget);
    expect(beta, findsOneWidget);
    expect(db, findsOneWidget);
    for (final text in ['@W', '@We', '@Web']) {
      await type(text);
      expect(alpha, findsOneWidget);
      expect(beta, findsOneWidget);
      expect(db, findsNothing);
    }
    await type('@Web 服', composing: const TextRange(start: 5, end: 6));
    expect(popover, findsOneWidget);
    expect(alpha, findsOneWidget);
    expect(beta, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.sessions, isEmpty);
    expect(Get.find<AgentController>().entries, isEmpty);
    await type('@Web 服务 Alph');
    expect(alpha, findsOneWidget);
    expect(beta, findsNothing);
    for (var index = 0; index < 4; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await pumpModelOptions(tester);
    }
    expect(controller.text, '@Web 服务 ');
    expect(alpha, findsOneWidget);
    expect(beta, findsOneWidget);
    await type('@不存在');
    expect(popover, findsOneWidget);
    expect(find.text('没有匹配的会话'), findsOneWidget);
    await type('@BETA.EXAMPLE');
    expect(beta, findsOneWidget);
    expect(alpha, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.sessions.single.id, 'beta');
    expect(controller.text, '@Web 服务 Beta ');
    await type('${controller.text}继续描述');
    expect(popover, findsNothing);
    await type('${controller.text} @alpha');
    expect(alpha, findsOneWidget);
    expect(beta, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.sessions.map((s) => s.id), ['beta', 'alpha']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('输入框多个高亮引用发送各会话上下文，删改后不再关联该会话', (tester) async {
    final connect = FakeAiConnect((_) => openAiReply('已读取引用的会话。'));
    final capture = await pump(
      tester,
      size: const Size(800, 600),
      connect: connect,
    );
    await configure(tester);
    final sessions = Get.find<SessionController>();
    Session session(String id, String name) => Session(
      id: id,
      host: Host(id: id, name: name, hostname: '$id.test'),
      phase: SessionPhase.ready,
      engineSession: _SshSession(),
      terminal: Terminal()..write('$id-terminal-output\r\n'),
    );
    final alpha = session('alpha', '服务甲');
    final beta = session('beta', '服务乙');
    sessions.sessions.addAll([alpha, beta, session('private', '未引用服务')]);
    sessions.activeSessionId.value = 'private';
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('agent-input'));
    final controller =
        tester.widget<AppTextFormField>(input).controller
            as AgentInputController;
    await tester.enterText(input, '比较 @甲');
    await pumpModelOptions(tester);
    await tester.tap(find.text('服务甲 · 终端').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(input, '${controller.text}@乙');
    await pumpModelOptions(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, '比较 @服务甲 @服务乙 ');
    expect(controller.sessions.map((s) => s.id), ['alpha', 'beta']);
    expect(find.byKey(const ValueKey('agent-selected-session')), findsNothing);
    await Get.find<SettingsController>().setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await _capture(tester, capture, 'agent-inline-mentions-dark');
    await Get.find<SettingsController>().setThemeMode(AppThemeMode.light);
    await tester.pumpAndSettle();
    await _capture(tester, capture, 'agent-inline-mentions-light');
    expect(controller.sessions.map((s) => s.id), ['alpha', 'beta']);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final payload = jsonEncode(connect.requests.single.body);
    expect(payload, contains('alpha-terminal-output'));
    expect(payload, contains('beta-terminal-output'));
    expect(payload, isNot(contains('private-terminal-output')));
    expect(controller.text, isEmpty);
    expect(controller.sessions, isEmpty);
    expect(Get.find<AgentController>().selectedSessions, isEmpty);

    await tester.tap(find.byKey(const ValueKey('agent-new-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-add-context')));
    await pumpModelOptions(tester);
    await tester.tap(find.text('服务甲 · 终端').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-add-context')));
    await pumpModelOptions(tester);
    await tester.tap(find.text('服务乙 · 终端').hitTestable());
    await tester.pumpAndSettle();
    final range = controller.mentions.first.range;
    controller.selection = TextSelection.collapsed(offset: range.start + 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumpModelOptions(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.text, '@服甲 @服务乙 ');
    expect(controller.sessions.single.id, 'beta');
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    final afterEdit = jsonEncode(connect.requests.last.body);
    expect(afterEdit, isNot(contains('alpha-terminal-output')));
    expect(afterEdit, contains('beta-terminal-output'));
    expect(afterEdit, isNot(contains('private-terminal-output')));

    await tester.enterText(input, '保持 @甲');
    await pumpModelOptions(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.enterText(input, '${controller.text}@乙');
    await pumpModelOptions(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final draft = controller.value;
    // 同 ID 重连不能继承旧句柄；只解除该处高亮，关闭另一会话也保留原文。
    sessions.sessions[0] = session('alpha', '服务甲');
    await tester.pumpAndSettle();
    expect(controller.sessions.single.id, 'beta');
    expect(controller.value, draft);
    sessions.sessions.removeWhere((session) => session.id == 'beta');
    await tester.pumpAndSettle();
    expect(controller.mentions, isEmpty);
    expect(controller.value, draft);
    sessions.sessions.add(beta);
    await tester.pumpAndSettle();
    expect(controller.mentions, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同名会话引用的类型和序号随消息传给模型，逆序选择仍准确对应', (tester) async {
    final connect = FakeAiConnect((_) => openAiReply('已读取。'));
    await pump(tester, connect: connect);
    await configure(tester);
    Get.find<SessionController>().sessions.addAll([
      for (final id in ['first', 'second'])
        Session(
          id: id,
          host: Host(id: id, name: '同名服务', hostname: 'same.test'),
          phase: SessionPhase.ready,
          engineSession: _SshSession(),
          terminal: Terminal(),
        ),
    ]);
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    for (final ordinal in [2, 1]) {
      await tester.tap(find.byKey(const ValueKey('agent-add-context')));
      await pumpModelOptions(tester);
      await tester.tap(find.text('同名服务 · 终端 · $ordinal').hitTestable());
      await tester.pumpAndSettle();
    }
    final controller =
        tester
                .widget<AppTextFormField>(
                  find.byKey(const ValueKey('agent-input')),
                )
                .controller
            as AgentInputController;
    expect(controller.referenceLabels, {
      'second': '@同名服务 · 终端 · 2',
      'first': '@同名服务 · 终端 · 1',
    });
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    final messages = connect.requests.single.body['messages'] as List<dynamic>;
    final system = (messages.first as Map)['content'] as String;
    final line = system
        .split('\n')
        .singleWhere((s) => s.startsWith('CURRENT_CONTEXT: '));
    final context =
        jsonDecode(line.substring('CURRENT_CONTEXT: '.length)) as Map;
    final references = context['sessions'] as List<dynamic>;
    expect(
      {
        for (final dynamic item in references)
          (item as Map)['session_id']: item['reference'],
      },
      {'second': '@同名服务 · 终端 · 2', 'first': '@同名服务 · 终端 · 1'},
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform Enter 发送、Shift+Enter 换行、中文组词 Enter 不误发送', (
      tester,
    ) async {
      await pump(tester, platform: platform);
      await configure(tester);
      await tester.tap(find.byKey(const ValueKey('agent-toggle')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('agent-input'));
      final controller = tester.widget<AppTextFormField>(input).controller;
      await tester.enterText(input, 'one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(controller.text, 'one\n');
      final agent = Get.find<AgentController>();
      expect(agent.entries, isEmpty);
      await tester.enterText(input, 'one\ntwo');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(agent.entries.first.text, 'one\ntwo');
      expect(controller.text, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        agent.entries.where((entry) => entry.kind == AgentEntryKind.user),
        hasLength(1),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pumpAndSettle();
      expect(
        agent.entries
            .where((entry) => entry.kind == AgentEntryKind.user)
            .last
            .text,
        '中文',
      );
      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Agent 完全访问不弹批准框，发送后自动读取输出并继续', (tester) async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                {
                  'id': 'input',
                  'type': 'function',
                  'function': {
                    'name': 'propose_ssh_command',
                    'arguments':
                        '{"command":"ss -lntp","purpose":"Check port 80"}',
                  },
                },
              ],
            )
          : openAiReply('nginx owns port 80.'),
    );
    await pump(tester, connect: connect);
    await configure(tester);
    final written = <String>[];
    final terminal = Terminal();
    terminal.onOutput = (input) {
      written.add(input);
      terminal.write('nginx LISTEN :80\r\n');
    };
    Get.find<SessionController>().sessions.add(
      Session(
        id: 'ssh',
        host: const Host(id: 'ssh', name: 'Server', hostname: 'server.test'),
        phase: SessionPhase.ready,
        engineSession: _SshSession(),
        terminal: terminal,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('agent-input')), '@');
    await pumpModelOptions(tester);
    await tester.tap(find.text('Server · 终端').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-access-select')));
    await pumpModelOptions(tester);
    await tester.tap(find.text('完全访问').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-input')),
      '@Server Check port 80',
    );
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(written, ['ss -lntp\r']);
    expect(find.byKey(const ValueKey('agent-confirm-command')), findsNothing);
    expect(find.text('nginx owns port 80.'), findsOneWidget);
    expect(
      jsonEncode(connect.requests.last.body),
      contains('nginx LISTEN :80'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Agent 命令经二次确认发送到固定 SSH 终端', (tester) async {
    var count = 0;
    final connect = FakeAiConnect(
      (_) => ++count == 1
          ? openAiReply(
              '',
              calls: [
                {
                  'id': 'proposal',
                  'type': 'function',
                  'function': {
                    'name': 'propose_ssh_command',
                    'arguments': '{"command":"df -h","purpose":"Check disk"}',
                  },
                },
              ],
            )
          : openAiReply('Review the command below.'),
    );
    await pump(tester, connect: connect);
    await configure(tester);
    final written = <String>[];
    final sessions = Get.find<SessionController>();
    final terminal = Terminal();
    terminal.onOutput = (input) {
      written.add(input);
      terminal.write('\r\ndisk-observed-output\r\n');
    };
    sessions.sessions.add(
      Session(
        id: 'ssh',
        host: const Host(id: 'ssh', name: 'Server', hostname: 'server.test'),
        phase: SessionPhase.ready,
        engineSession: _SshSession(),
        terminal: terminal,
      ),
    );
    sessions.activeSessionId.value = 'ssh';
    await tester.tap(find.byKey(const ValueKey('agent-toggle')).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('agent-input')), '@Serv');
    await pumpModelOptions(tester);
    await tester.tap(find.text('Server · 终端').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-input')),
      '@Server Check disk',
    );
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(written, isEmpty);
    await tester.ensureVisible(find.text('发送到终端'));
    await tester.tap(find.text('发送到终端'));
    await tester.pumpAndSettle();
    expect(written, isEmpty);
    expect(find.textContaining('Server · root@server.test'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-confirm-command')));
    await tester.pumpAndSettle();
    expect(written, ['df -h\r']);
    expect(
      jsonEncode(connect.requests.last.body),
      contains('disk-observed-output'),
    );
    expect(
      Get.find<AgentController>().entries
          .firstWhere((e) => e.command != null)
          .command!
          .state
          .value,
      AgentCommandState.sent,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
