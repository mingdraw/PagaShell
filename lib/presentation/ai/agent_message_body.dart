import '../components/app_markdown.dart';

/// Agent 回复沿用应用共用的 Markdown 排版。
class AgentMessageBody extends AppMarkdown {
  const AgentMessageBody(super.text, {super.key});
}

typedef AgentCodeBlock = AppMarkdownCodeBlock;
