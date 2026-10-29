import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/ai/agent_message_body.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pump(WidgetTester tester, String markdown) async {
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 240,
            height: 580,
            child: SingleChildScrollView(child: AgentMessageBody(markdown)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  shadcn.SelectableText paragraph(WidgetTester tester, String text) => tester
      .widgetList<shadcn.SelectableText>(find.byType(shadcn.SelectableText))
      .firstWhere((widget) => widget.textSpan?.toPlainText().trim() == text);

  testWidgets('Markdown 显示标题、行内格式、嵌套列表、引用、任务和转义', (tester) async {
    await pump(tester, '''
## 排障步骤

**粗体**、*斜体*、~~旧方案~~、`ssh -v`、\\*原样星号\\*

3. 检查连接
   - 检查 DNS
   - 检查端口
4. 查看日志

> 引用 **提示**

- [x] 已连接
- [ ] 待排查

---

结束\x20\x20
换行
''');
    expect(paragraph(tester, '排障步骤').style?.fontSize, 19);
    expect(paragraph(tester, '排障步骤').style?.fontWeight, FontWeight.w600);
    final formatted = paragraph(
      tester,
      '粗体、斜体、旧方案、ssh -v、*原样星号*',
    ).textSpan!.children!.whereType<TextSpan>().toList();
    expect(formatted[0].style?.fontWeight, FontWeight.w600);
    expect(formatted[2].style?.fontStyle, FontStyle.italic);
    expect(formatted[4].style?.decoration, TextDecoration.lineThrough);
    expect(formatted[6].style?.fontFamily, 'FiraCode Nerd Font Mono');
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);
    expect(paragraph(tester, '检查 DNS'), isNotNull);
    expect(paragraph(tester, '引用 提示').style?.color, isNotNull);
    expect(paragraph(tester, '☑ 已连接'), isNotNull);
    expect(paragraph(tester, '☐ 待排查'), isNotNull);
    expect(find.text('•'), findsNWidgets(2));
    expect(paragraph(tester, '结束\n换行'), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板的 Markdown 表格保留对齐并横向滚动', (tester) async {
    await pump(tester, '''
| 检查项 | 结果 | 说明 |
| :--- | :---: | ---: |
| **SSH** | 正常 | 这是较长的说明文字，用于检查窄面板中的表格不会挤出边界 |
| RDP | 待检查 | 使用 `3389` 端口 |
''');
    expect(find.byType(Table), findsOneWidget);
    expect(paragraph(tester, '检查项').style?.fontWeight, FontWeight.w600);
    expect(paragraph(tester, '结果').textAlign, TextAlign.center);
    expect(paragraph(tester, '说明').textAlign, TextAlign.right);
    final scrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getTopLeft(find.byType(Table)) + const Offset(10, 10),
        scrollDelta: const Offset(180, 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('标准围栏和缩进代码保留空白、语言与原文复制，消息更新后重解析', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(
      tester,
      '~~~sh\nprintf "<ok>"  \n  echo done\n~~~\n\n    df -h\n',
    );
    final blocks = tester
        .widgetList<AgentCodeBlock>(find.byType(AgentCodeBlock))
        .toList();
    expect(blocks, hasLength(2));
    expect(blocks.first.language, 'sh');
    expect(blocks.first.code, 'printf "<ok>"  \n  echo done');
    expect(blocks.last.code, 'df -h');
    await tester.tap(findAppIconButton('复制').first);
    expect(copied, blocks.first.code);
    await pump(tester, '# 新回复\n\n新内容');
    expect(find.byType(AgentCodeBlock), findsNothing);
    expect(paragraph(tester, '新回复').style?.fontSize, 21);
    expect(paragraph(tester, '新内容'), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('链接与图片呈现可复制标签和地址，HTML 作为文本显示', (tester) async {
    await pump(tester, '''
[文档](https://example.test/docs?a=1&b=2)

![架构图](https://example.test/diagram.png)

<script>nothing()</script>

\\# 原样标题 &amp; &lt;text&gt;
''');
    expect(
      paragraph(tester, '文档 (https://example.test/docs?a=1&b=2)'),
      isNotNull,
    );
    expect(
      paragraph(tester, '架构图 (https://example.test/diagram.png)'),
      isNotNull,
    );
    expect(paragraph(tester, '<script>nothing()</script>'), isNotNull);
    expect(paragraph(tester, '# 原样标题 & <text>'), isNotNull);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
