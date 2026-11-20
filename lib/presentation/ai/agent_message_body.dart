import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

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

/// While deltas arrive, show selectable plain text without parsing Markdown.
/// Keep the same editing controller so appending text doesn't reset selection.
class AgentStreamingText extends StatefulWidget {
  const AgentStreamingText({
    required this.text,
    required this.streaming,
    required this.style,
    required this.buildFinal,
    super.key,
  });

  final String text;
  final bool streaming;
  final TextStyle style;
  final Widget Function(String) buildFinal;

  @override
  State<AgentStreamingText> createState() => _AgentStreamingTextState();
}

class _AgentStreamingTextState extends State<AgentStreamingText> {
  TextEditingController? _preview;
  FocusNode? _focus;

  bool get _hasSelection {
    final selection = _preview?.selection;
    return _focus?.hasFocus == true &&
        selection != null &&
        selection.isValid &&
        !selection.isCollapsed;
  }

  @override
  void initState() {
    super.initState();
    _syncPreview();
  }

  @override
  void didUpdateWidget(covariant AgentStreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPreview();
  }

  void _syncPreview() {
    if (!widget.streaming && !_hasSelection) return;
    final preview = _preview ??= TextEditingController()
      ..addListener(_selectionChanged);
    _focus ??= FocusNode()..addListener(_selectionChanged);
    final text = widget.text;
    if (preview.text == text) return;
    final selection = preview.selection;
    preview.value = TextEditingValue(
      text: text,
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: selection.baseOffset.clamp(0, text.length),
              extentOffset: selection.extentOffset.clamp(0, text.length),
            )
          : selection,
    );
  }

  void _selectionChanged() {
    // If the stream finished during a selection, defer Markdown until the
    // reader lets go of that selection or leaves the message.
    if (mounted && !widget.streaming) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.streaming && !_hasSelection) {
      return widget.buildFinal(widget.text);
    }
    return shadcn.TextField(
      controller: _preview,
      focusNode: _focus,
      readOnly: true,
      showCursor: false,
      maxLines: null,
      padding: EdgeInsets.zero,
      scrollPadding: EdgeInsets.zero,
      decoration: const BoxDecoration(),
      style: widget.style,
    );
  }

  @override
  void dispose() {
    _preview?.dispose();
    _focus?.dispose();
    super.dispose();
  }
}
