import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/mcp/mcp_server_controller.dart';
import 'package:pagashell/domain/mcp/mcp_models.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

void main() {
  String? clipboardText;

  setUp(() {
    clipboardText = null;
    Get.locale = AppTranslations.defaultLocale;
    Get.fallbackLocale = AppTranslations.defaultLocale;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
            return null;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  Future<void> openAiSettingsTab(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('设置 → AI 设置 渲染本地 MCP 服务，支持启停、改端口、切只读、令牌显隐/重置、复制 Codex 配置及审计日志', (
    tester,
  ) async {
    await openAiSettingsTab(tester);

    final mcp = Get.find<McpServerController>();
    expect(find.byKey(const ValueKey('mcp-settings-section')), findsOneWidget);
    expect(find.text('本地 MCP 服务'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('mcp-token-generate'))),
      isA<AppIconButton>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('mcp-copy-codex'))),
      isA<shadcn.GhostButton>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('mcp-copy-json'))),
      isA<shadcn.GhostButton>(),
    );

    // 1. 无需填写 AI 模型 API Key 即可直接开启本地 MCP 服务
    await tester.ensureVisible(
      find.byKey(const ValueKey('mcp-enabled-switch')),
    );
    await tester.tap(find.byKey(const ValueKey('mcp-enabled-switch')));
    await tester.pumpAndSettle();
    expect(mcp.running.value, isTrue);
    expect(find.text('运行中'), findsOneWidget);
    expect(mcp.token.value, isNotNull);

    // 2. 令牌默认脱敏显示，点击眼睛切换明文
    final initialToken = mcp.token.value!;
    expect(find.text(initialToken), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('mcp-token-visibility')),
    );
    await tester.tap(find.byKey(const ValueKey('mcp-token-visibility')));
    await tester.pumpAndSettle();
    expect(find.text(initialToken), findsOneWidget);

    // 3. 复制 Codex 配置 (TOML) 与通用 MCP JSON
    await tester.ensureVisible(find.byKey(const ValueKey('mcp-copy-codex')));
    await tester.tap(find.byKey(const ValueKey('mcp-copy-codex')));
    await tester.pumpAndSettle();
    expect(clipboardText, contains('[mcp_servers.pagashell]'));
    expect(clipboardText, contains('Bearer $initialToken'));

    await tester.tap(find.byKey(const ValueKey('mcp-copy-json')));
    await tester.pumpAndSettle();
    expect(clipboardText, contains('"mcpServers"'));
    expect(clipboardText, contains('Bearer $initialToken'));

    // 4. 修改监听端口
    await tester.ensureVisible(find.byKey(const ValueKey('mcp-port-input')));
    await tester.enterText(
      find.byKey(const ValueKey('mcp-port-input')),
      '48123',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp-port-apply')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(mcp.boundPort.value, 48123);
    expect(mcp.config.port, 48123);
    expect(find.text('http://127.0.0.1:48123/mcp'), findsOneWidget);

    // 等待前置提示条自动消失，避免遮挡下拉框点击区域。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    // 5. 切换访问权限为只读模式
    final selectFinder = find.byType(shadcn.Select<McpAccessMode>);
    await Scrollable.ensureVisible(
      tester.element(selectFinder),
      alignment: 0.3,
    );
    await tester.pumpAndSettle();
    await tester.tap(selectFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('只读模式').last);
    await tester.pumpAndSettle();
    expect(mcp.config.accessMode, McpAccessMode.readOnly);

    // 6. 重置令牌弹窗确认
    expect(
      tester.widget(find.byKey(const ValueKey('mcp-token-rotate'))),
      isA<AppIconButton>(),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('mcp-token-rotate')));
    await tester.tap(find.byKey(const ValueKey('mcp-token-rotate')));
    await tester.pumpAndSettle();
    expect(find.text('重置 MCP 令牌？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-token-rotate-confirm')));
    await tester.pumpAndSettle();
    expect(mcp.token.value, isNot(initialToken));

    // 7. 审计记录展开与清空
    mcp.auditLogs.add(
      McpAuditEntry(
        timestamp: DateTime(2026, 11, 24, 14, 0, 1),
        toolName: 'inspect_server_profile',
        target: 'prod-db · ops@10.0.0.10',
        status: McpAuditStatus.success,
        durationMs: 42,
        summary: 'ok',
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('mcp-audit-toggle')));
    await tester.tap(find.byKey(const ValueKey('mcp-audit-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('inspect_server_profile'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-audit-clear')));
    await tester.pumpAndSettle();
    expect(mcp.auditLogs, isEmpty);
    expect(find.text('暂无外部工具调用记录'), findsOneWidget);

    // 推进时钟让提示条的自动关闭定时器自然结束。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('英文界面下本地 MCP 设置文案完整翻译', (tester) async {
    Get.locale = AppTranslations.englishLocale;
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI settings'));
    await tester.pumpAndSettle();

    expect(find.text('Local MCP Server'), findsOneWidget);
    expect(find.text('Copy Codex Config'), findsOneWidget);
    expect(find.text('Copy MCP JSON'), findsOneWidget);
    expect(find.text('Recent Tool Calls'), findsOneWidget);
  });
}
