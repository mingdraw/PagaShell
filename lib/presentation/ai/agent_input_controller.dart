import 'package:flutter/widgets.dart';

import '../../application/session/session.dart';
import '../theme/app_theme.dart';

class AgentSessionMention {
  const AgentSessionMention({required this.range, required this.session});

  final TextRange range;
  final Session session;
}

/// 引用保留真实文本和会话身份；只有从候选中选择才建立关联。
class AgentInputController extends TextEditingController {
  List<AgentSessionMention> _mentions = [];

  List<AgentSessionMention> get mentions => List.unmodifiable(_mentions);

  List<Session> get sessions =>
      {for (final mention in _mentions) mention.session.id: mention.session}
          .values
          .toList();

  Map<String, String> get referenceLabels => {
    for (final mention in _mentions)
      mention.session.id: mention.range.textInside(text),
  };

  bool containsMentionAt(int offset) => _mentions.any(
    (mention) => offset > mention.range.start && offset <= mention.range.end,
  );

  @override
  set value(TextEditingValue next) {
    _mentions = _rebase(next);
    super.value = next;
  }

  List<AgentSessionMention> _rebase(TextEditingValue next) {
    final previous = value.text;
    if (previous == next.text) return _mentions;

    // 优先采用真实选区/光标确定编辑位置。相邻引用常有相同前缀，仅比较
    // 文本最长前后缀会把「删除第一个引用」误判成同时修改第二个引用。
    List<AgentSessionMention>? editAt(int start, int end) {
      final insertedEnd = next.text.length - (previous.length - end);
      if (start < 0 ||
          end > previous.length ||
          insertedEnd < start ||
          insertedEnd > next.text.length ||
          previous.substring(0, start) != next.text.substring(0, start) ||
          previous.substring(end) != next.text.substring(insertedEnd)) {
        return null;
      }
      return _afterEdit(start, end, next.text.substring(start, insertedEnd));
    }

    final selection = value.selection;
    if (selection.isValid && selection.end <= previous.length) {
      List<AgentSessionMention>? edited;
      if (!selection.isCollapsed) {
        edited = editAt(selection.start, selection.end);
      } else if (next.selection.isValid && next.selection.isCollapsed) {
        final caret = selection.extentOffset;
        final nextCaret = next.selection.extentOffset;
        final delta = next.text.length - previous.length;
        if (delta > 0 && nextCaret == caret + delta) {
          edited = editAt(caret, caret);
        } else if (delta < 0 && nextCaret == caret + delta) {
          edited = editAt(nextCaret, caret);
        } else if (delta < 0 && nextCaret == caret) {
          edited = editAt(caret, caret - delta);
        }
      }
      if (edited != null) return edited;
    }
    var start = 0;
    while (start < previous.length &&
        start < next.text.length &&
        previous.codeUnitAt(start) == next.text.codeUnitAt(start)) {
      start++;
    }
    var end = previous.length;
    var nextEnd = next.text.length;
    while (end > start &&
        nextEnd > start &&
        previous.codeUnitAt(end - 1) == next.text.codeUnitAt(nextEnd - 1)) {
      end--;
      nextEnd--;
    }
    return _afterEdit(start, end, next.text.substring(start, nextEnd));
  }

  List<AgentSessionMention> _afterEdit(int start, int end, String inserted) {
    final delta = inserted.length - (end - start);
    return [
      for (final mention in _mentions)
        if (mention.range.end <= start &&
            // 在名称末尾继续输入字符也视为修改引用，正常输入从尾随空格后开始。
            !(mention.range.end == start &&
                start == end &&
                inserted.isNotEmpty &&
                !RegExp(r'^\s').hasMatch(inserted)))
          mention
        else if (mention.range.start >= end)
          AgentSessionMention(
            range: TextRange(
              start: mention.range.start + delta,
              end: mention.range.end + delta,
            ),
            session: mention.session,
          ),
      // 与编辑范围相交的引用直接失效；撤销或手动补回名称不会重新绑定。
    ];
  }

  void insertSession(Session session, String label, TextRange replacement) {
    final token = '@$label';
    final inserted = '$token ';
    _mentions = [
      ..._afterEdit(replacement.start, replacement.end, inserted),
      AgentSessionMention(
        range: TextRange(
          start: replacement.start,
          end: replacement.start + token.length,
        ),
        session: session,
      ),
    ]..sort((a, b) => a.range.start.compareTo(b.range.start));
    super.value = TextEditingValue(
      text: text.replaceRange(replacement.start, replacement.end, inserted),
      selection: TextSelection.collapsed(
        offset: replacement.start + inserted.length,
      ),
    );
  }

  /// 关闭或重连的引用保留文字，取消高亮与旧连接关联。
  void retainSessions(bool Function(Session) isAvailable) {
    final retained = _mentions.where((m) => isAvailable(m.session)).toList();
    if (retained.length == _mentions.length) return;
    _mentions = retained;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_mentions.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final boundaries = {
      0,
      text.length,
      for (final mention in _mentions) ...[
        mention.range.start,
        mention.range.end,
      ],
      if (composing.isValid) ...[composing.start, composing.end],
    }.toList()..sort();
    final highlight = AppTheme.agentMentionForeground(context);
    final children = <TextSpan>[];
    for (var i = 0; i < boundaries.length - 1; i++) {
      final mentioned = _mentions.any(
        (mention) =>
            boundaries[i] >= mention.range.start &&
            boundaries[i] < mention.range.end,
      );
      children.add(
        TextSpan(
          text: text.substring(boundaries[i], boundaries[i + 1]),
          style: TextStyle(
            color: mentioned ? highlight : null,
            backgroundColor: mentioned
                ? highlight.withValues(alpha: 0.12)
                : null,
            decoration:
                composing.isValid &&
                    boundaries[i] >= composing.start &&
                    boundaries[i] < composing.end
                ? TextDecoration.underline
                : null,
          ),
        ),
      );
    }
    return TextSpan(style: style, children: children);
  }
}
