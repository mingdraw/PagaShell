import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon_button.dart';
import '../theme/app_theme.dart';

/// 将 Markdown 语法树映射为原生组件；链接与图片保留可复制的文本。
class AgentMessageBody extends StatefulWidget {
  const AgentMessageBody(this.text, {super.key});
  final String text;

  @override
  State<AgentMessageBody> createState() => _AgentMessageBodyState();
}

class _AgentMessageBodyState extends State<AgentMessageBody> {
  late List<md.Node> _nodes;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant AgentMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _parse();
  }

  void _parse() {
    _nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parse(widget.text);
  }

  @override
  Widget build(BuildContext context) =>
      _MarkdownRenderer(context).blocks(_nodes);
}

class _MarkdownRenderer {
  _MarkdownRenderer(this.context);
  final BuildContext context;
  static const _bodyStyle = TextStyle(fontSize: 13, height: 1.65);
  static const _blockTags = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'pre',
    'blockquote',
    'ul',
    'ol',
    'table',
    'hr',
  };

  Widget blocks(List<md.Node> nodes, {TextStyle? style}) {
    final widgets = <Widget>[];
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      widgets.add(_paragraph(List.of(inline), style: style));
      inline.clear();
    }

    for (final node in nodes) {
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flush();
        widgets.add(_block(node, style: style));
      } else {
        inline.add(node);
      }
    }
    flush();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  Widget _block(md.Element element, {TextStyle? style}) {
    final children = element.children ?? const <md.Node>[];
    switch (element.tag) {
      case 'pre':
        final code = children.whereType<md.Element>().firstOrNull;
        final text = code?.textContent ?? element.textContent;
        final language =
            code?.attributes['class']
                ?.split(' ')
                .where((value) => value.startsWith('language-'))
                .firstOrNull
                ?.substring('language-'.length) ??
            '';
        return AgentCodeBlock(
          code: text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
          language: language,
        );
      case 'ul':
      case 'ol':
        return _list(element, style: style);
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppTheme.border(context), width: 3),
            ),
          ),
          child: blocks(
            children,
            style: (style ?? const TextStyle()).copyWith(
              color: shadcn.Theme.of(context).colorScheme.mutedForeground,
            ),
          ),
        );
      case 'table':
        return _table(element);
      case 'hr':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          height: 1,
          color: AppTheme.border(context),
        );
      default:
        if (element.tag.startsWith('h') && element.tag.length == 2) {
          final level = int.tryParse(element.tag.substring(1));
          if (level != null && level >= 1 && level <= 6) {
            return _paragraph(
              children,
              style: (style ?? const TextStyle()).copyWith(
                fontSize: [21.0, 19.0, 17.0, 15.0, 14.0, 13.0][level - 1],
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            );
          }
        }
        return _paragraph(children, style: style);
    }
  }

  Widget _list(md.Element element, {TextStyle? style}) {
    final items = (element.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((node) => node.tag == 'li')
        .toList();
    final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (element.tag == 'ol' ||
                    items[i].attributes['class'] != 'task-list-item')
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 16),
                      child: Text(
                        element.tag == 'ol' ? '${start + i}.' : '•',
                        textAlign: TextAlign.right,
                        style: _bodyStyle.merge(style),
                      ),
                    ),
                  ),
                Expanded(child: blocks(items[i].children ?? [], style: style)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _table(md.Element element) {
    final rows = <md.Element>[];
    void collect(md.Element node) {
      if (node.tag == 'tr') {
        rows.add(node);
      } else {
        for (final child
            in node.children?.whereType<md.Element>() ?? const <md.Element>[]) {
          collect(child);
        }
      }
    }

    collect(element);
    final cells = [
      for (final row in rows)
        (row.children ?? const <md.Node>[]).whereType<md.Element>().toList(),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    final columns = cells.fold(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder.all(color: AppTheme.border(context)),
          children: [
            for (final row in cells)
              TableRow(
                decoration: row.any((cell) => cell.tag == 'th')
                    ? BoxDecoration(color: AppTheme.surface(context))
                    : null,
                children: [
                  for (var i = 0; i < columns; i++)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 80,
                        maxWidth: 220,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: i >= row.length
                            ? const SizedBox.shrink()
                            : _paragraph(
                                row[i].children ?? [],
                                style: row[i].tag == 'th'
                                    ? const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      )
                                    : null,
                                textAlign: switch (row[i].attributes['align']) {
                                  'center' => TextAlign.center,
                                  'right' => TextAlign.right,
                                  _ => TextAlign.left,
                                },
                              ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _paragraph(
    List<md.Node> nodes, {
    TextStyle? style,
    TextAlign textAlign = TextAlign.start,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: shadcn.SelectableText.rich(
      TextSpan(children: [for (final node in nodes) _inline(node)]),
      style: _bodyStyle.merge(style),
      textAlign: textAlign,
    ),
  );

  InlineSpan _inline(md.Node node) {
    if (node is! md.Element) return TextSpan(text: node.textContent);
    final children = [
      for (final child in node.children ?? const <md.Node>[]) _inline(child),
    ];
    switch (node.tag) {
      case 'br':
        return const TextSpan(text: '\n');
      case 'input':
        return TextSpan(
          text: node.attributes.containsKey('checked') ? '☑ ' : '☐ ',
        );
      case 'img':
        final alt = node.attributes['alt'] ?? '';
        return TextSpan(text: '$alt (${node.attributes['src'] ?? ''})');
      case 'a':
        final href = node.attributes['href'] ?? '';
        return TextSpan(
          style: TextStyle(
            color: shadcn.Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
          children: [
            ...children,
            if (href.isNotEmpty && href != node.textContent)
              TextSpan(text: ' ($href)'),
          ],
        );
      default:
        return TextSpan(
          children: children,
          style: switch (node.tag) {
            'strong' => const TextStyle(fontWeight: FontWeight.w600),
            'em' => const TextStyle(fontStyle: FontStyle.italic),
            'del' => const TextStyle(decoration: TextDecoration.lineThrough),
            'code' => TextStyle(
              fontFamily: 'FiraCode Nerd Font Mono',
              fontSize: 12,
              backgroundColor: AppTheme.surface(context),
            ),
            _ => null,
          },
        );
    }
  }
}

class AgentCodeBlock extends StatelessWidget {
  const AgentCodeBlock({required this.code, this.language = '', super.key});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: AppTheme.surface(context),
      border: Border.all(color: AppTheme.border(context)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  language.isEmpty ? '命令'.tr : language,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              AppIconButton(
                semanticLabel: '复制'.tr,
                icon: const Icon(shadcn.LucideIcons.copy, size: 13),
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(10),
          child: shadcn.SelectableText(
            code,
            style: const TextStyle(
              fontFamily: 'FiraCode Nerd Font Mono',
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ),
      ],
    ),
  );
}
