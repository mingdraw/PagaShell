import '../components/app_markdown.dart';

/// Agent 回复沿用应用共用的 Markdown 排版。
class AgentMessageBody extends AppMarkdown {
  const AgentMessageBody(
    super.text, {
    super.onInsertToTerminal,
    super.defaultCodeLabel = '代码',
    super.key,
  });
}

typedef AgentCodeBlock = AppMarkdownCodeBlock;
