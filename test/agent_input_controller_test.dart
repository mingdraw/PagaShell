import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/ai/agent_input_controller.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';

import 'support/shadcn_test_app.dart';

const first = Session(
  id: 'alpha',
  host: Host(id: 'alpha', name: '服务甲', hostname: 'alpha.test'),
);
const second = Session(
  id: 'beta',
  host: Host(id: 'beta', name: '服务乙', hostname: 'beta.test'),
);

void edit(AgentInputController input, int start, int end, String text) {
  input.value = TextEditingValue(
    text: input.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

void main() {
  late AgentInputController input;
  setUp(() => input = AgentInputController());
  tearDown(() => input.dispose());

  void append(Session session) => input.insertSession(
    session,
    session.title,
    TextRange.collapsed(input.text.length),
  );

  test('多个引用是输入框真实文本，手工输入相同名称不建立关联', () {
    input.text = '比较 @服务甲 与 ';
    append(first);
    append(second);
    expect(input.text, '比较 @服务甲 与 @服务甲 @服务乙 ');
    expect(input.sessions, [first, second]);
    expect(input.mentions.map((m) => m.range.textInside(input.text)), [
      '@服务甲',
      '@服务乙',
    ]);
    expect(input.selection.extentOffset, input.text.length);
  });

  for (final index in [0, 1, 3]) {
    test('删除引用第 $index 个字符只解除对应关联，补回文字不会恢复', () {
      append(first);
      append(second);
      final original = input.text;
      edit(input, index, index + 1, '');
      expect(input.sessions, [second]);
      expect(input.mentions.single.range.textInside(input.text), '@服务乙');
      edit(input, index, index, original[index]);
      expect(input.text, original);
      expect(input.sessions, [second]);
    });
  }

  test('引用外的编辑移动范围，替换引用内选区解除关联', () {
    append(first);
    append(second);
    edit(input, 0, 0, '检查 ');
    edit(input, input.text.length, input.text.length, '状态');
    expect(input.sessions, [first, second]);
    expect(input.mentions.first.range.textInside(input.text), '@服务甲');
    final last = input.mentions.last.range;
    edit(input, last.start + 1, last.end, '新服务');
    expect(input.sessions, [first]);
    expect(input.text, '检查 @服务甲 @新服务 状态');
  });

  test('删除完整引用时使用真实选区，共同名称前缀不影响下一个引用', () {
    append(first);
    append(second);
    final removedEnd = input.mentions.first.range.end + 1;
    input.selection = TextSelection(baseOffset: 0, extentOffset: removedEnd);
    edit(input, 0, removedEnd, '');
    expect(input.sessions, [second]);
    expect(input.mentions.single.range, const TextRange(start: 0, end: 4));
    expect(input.text, '@服务乙 ');
  });

  test('名称内部插入和尾部续写会解除关联，空格后的普通输入不影响引用', () {
    append(first);
    edit(
      input,
      input.mentions.single.range.end,
      input.mentions.single.range.end,
      'x',
    );
    expect(input.sessions, isEmpty);
    input.clear();
    append(first);
    edit(input, 2, 2, 'x');
    expect(input.sessions, isEmpty);
    input.clear();
    append(first);
    edit(input, input.text.length, input.text.length, '继续检查');
    expect(input.sessions, [first]);
  });

  test('重复引用按会话去重，删除一处仍保留另一处；清空全部解除关联', () {
    append(first);
    append(first);
    expect(input.sessions, [first]);
    edit(input, 0, 1, '');
    expect(input.sessions, [first]);
    input.clear();
    expect(input.sessions, isEmpty);
    expect(input.mentions, isEmpty);
  });

  test('跨引用选区替换同时解除关联，按钮插入替换选区并保留两侧草稿', () {
    input.text = '之前 @搜索 之后';
    input.insertSession(first, first.title, const TextRange(start: 3, end: 6));
    append(second);
    expect(input.text, '之前 @服务甲  之后@服务乙 ');
    edit(input, 4, input.mentions.last.range.end, '内容');
    expect(input.sessions, isEmpty);
    expect(input.text, '之前 @内容 ');
  });

  test('会话失效只取消高亮关联，保留引用原文和其他连接', () {
    append(first);
    append(second);
    final value = input.value;
    input.retainSessions((session) => session.id != first.id);
    expect(input.sessions, [second]);
    expect(input.value, value);
    input.retainSessions((_) => true);
    expect(input.sessions, [second]);
  });

  test('输入法在引用前多步组词保持关联，在引用内部组词立即解除', () {
    input.text = ' ';
    append(first);
    input.selection = const TextSelection.collapsed(offset: 0);
    input.value = const TextEditingValue(
      text: 'ni @服务甲 ',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    expect(input.mentions.single.range, const TextRange(start: 3, end: 7));
    input.value = const TextEditingValue(
      text: '你 @服务甲 ',
      selection: TextSelection.collapsed(offset: 1),
    );
    expect(input.sessions, [first]);
    expect(input.mentions.single.range, const TextRange(start: 2, end: 6));
    input.selection = const TextSelection.collapsed(offset: 4);
    input.value = const TextEditingValue(
      text: '你 @服xin务甲 ',
      selection: TextSelection.collapsed(offset: 7),
      composing: TextRange(start: 4, end: 7),
    );
    expect(input.sessions, isEmpty);
    input.value = const TextEditingValue(
      text: '你 @服新务甲 ',
      selection: TextSelection.collapsed(offset: 5),
    );
    expect(input.sessions, isEmpty);
  });

  testWidgets('只高亮有效引用，兼容输入法组词下划线与 emoji 偏移', (tester) async {
    input.text = '🔍 ';
    append(first);
    edit(input, input.text.length, input.text.length, '中文');
    input.value = input.value.copyWith(
      composing: TextRange(
        start: input.text.length - 2,
        end: input.text.length,
      ),
    );
    late TextSpan span;
    late Color highlight;
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Builder(
          builder: (context) {
            highlight = AppTheme.agentMentionForeground(context);
            span = input.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: true,
            );
            return RichText(text: span);
          },
        ),
      ),
    );
    expect(span.toPlainText(), input.text);
    final spans = span.children!.cast<TextSpan>();
    expect(spans.where((s) => s.style?.color == highlight).single.text, '@服务甲');
    expect(
      spans
          .where((s) => s.style?.decoration == TextDecoration.underline)
          .single
          .text,
      '中文',
    );
    final range = input.mentions.single.range;
    edit(input, range.end - 1, range.end, '');
    expect(input.mentions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
