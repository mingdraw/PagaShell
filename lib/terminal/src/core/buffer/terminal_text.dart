import 'dart:async';
import 'dart:isolate';

import 'buffer.dart';
import 'cell_offset.dart';
import 'line.dart';

const terminalSearchLimit = 2000;

typedef _TextMatch = ({int row, int start, int end});
typedef _SearchRequest = ({
  List<String> lines,
  String query,
  bool regex,
  bool caseSensitive,
});

class TerminalTextMatch {
  const TerminalTextMatch(this.first, this.start, this.last, this.end);

  final BufferLine first;
  final int start;
  final BufferLine last;
  final int end;
  bool get attached => first.attached && last.attached;

  bool contains(CellOffset cell) =>
      attached &&
      cell.y >= first.index &&
      cell.y <= last.index &&
      (cell.y != first.index || cell.x >= start) &&
      (cell.y != last.index || cell.x < end);
}

class _LogicalLine {
  _LogicalLine(List<BufferLine> source)
    : rows = [for (final line in source) (line: line, version: line.version)] {
    final builder = StringBuffer();
    for (final row in rows) {
      starts.add(builder.length);
      builder.write(row.line.getText());
    }
    text = builder.toString().trimRight();
  }

  final List<({BufferLine line, int version})> rows;
  final starts = <int>[];
  late final String text;

  TerminalTextMatch? range(int start, int end) {
    if (rows.any(
      (row) => !row.line.attached || row.line.version != row.version,
    )) {
      return null;
    }
    final first = starts.lastIndexWhere((offset) => offset <= start);
    final last = starts.lastIndexWhere((offset) => offset < end);
    return TerminalTextMatch(
      rows[first].line,
      rows[first].line.columnForTextOffset(start - starts[first]),
      rows[last].line,
      rows[last].line.columnForTextOffset(end - starts[last], exclusive: true),
    );
  }
}

/// Takes a local snapshot of the scrollback. Hard line breaks delimit matches;
/// soft wraps are joined so search and link detection agree with selection.
Future<List<TerminalTextMatch>> searchTerminalText(
  Buffer buffer,
  String query, {
  required bool regex,
  required bool caseSensitive,
}) async {
  if (query.isEmpty) return const [];
  final lines = <_LogicalLine>[];
  final rows = <BufferLine>[];
  for (var index = 0; index < buffer.height; index++) {
    final row = buffer.lines[index];
    if ((!row.isWrapped || rows.length >= 256) && rows.isNotEmpty) {
      lines.add(_LogicalLine(rows));
      rows.clear();
    }
    rows.add(row);
  }
  if (rows.isNotEmpty) lines.add(_LogicalLine(rows));
  final request = (
    lines: [for (final line in lines) line.text],
    query: query,
    regex: regex,
    caseSensitive: caseSensitive,
  );
  final matches = regex ? await _boundedRegexSearch(request) : _find(request);
  return [
    for (final match in matches)
      ?lines[match.row].range(match.start, match.end),
  ];
}

List<_TextMatch> _find(_SearchRequest request) {
  final pattern = RegExp(
    request.regex ? request.query : RegExp.escape(request.query),
    caseSensitive: request.caseSensitive,
    unicode: true,
  );
  final matches = <_TextMatch>[];
  // Keep the most recent matching rows if the result limit is reached.
  for (var row = request.lines.length - 1; row >= 0; row--) {
    final rowMatches = <_TextMatch>[];
    for (final match in pattern.allMatches(request.lines[row])) {
      if (match.start == match.end) continue;
      rowMatches.add((row: row, start: match.start, end: match.end));
      if (rowMatches.length + matches.length >= terminalSearchLimit) break;
    }
    matches.addAll(rowMatches.reversed);
    if (matches.length >= terminalSearchLimit) break;
  }
  return matches.reversed.toList();
}

Future<List<_TextMatch>> _boundedRegexSearch(_SearchRequest request) async {
  // Compile before starting the worker to report invalid expressions separately.
  RegExp(request.query, caseSensitive: request.caseSensitive, unicode: true);
  final replies = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(_searchWorker, (
      request,
      replies.sendPort,
    ), onExit: replies.sendPort);
    final result = await replies.first.timeout(
      const Duration(milliseconds: 650),
    );
    if (result is! List<_TextMatch>) throw const FormatException();
    return result;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

void _searchWorker((_SearchRequest, SendPort) message) {
  message.$2.send(_find(message.$1));
}

final _linkPattern = RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false);
final _trailingPunctuation = RegExp(r'[.,;:!?]+$');

({Uri url, TerminalTextMatch range})? terminalLinkAt(
  Buffer buffer,
  CellOffset cell,
) {
  if (cell.y < 0 || cell.y >= buffer.height) return null;
  var start = cell.y;
  while (start > 0 && buffer.lines[start].isWrapped && cell.y - start < 64) {
    start--;
  }
  var end = cell.y + 1;
  while (end < buffer.height &&
      buffer.lines[end].isWrapped &&
      end - start < 128) {
    end++;
  }
  final line = _LogicalLine([
    for (var index = start; index < end; index++) buffer.lines[index],
  ]);
  for (final match in _linkPattern.allMatches(line.text)) {
    var value = match[0]!.replaceFirst(_trailingPunctuation, '');
    for (final (open, close) in [('(', ')'), ('[', ']'), ('{', '}')]) {
      while (value.endsWith(close) &&
          close.allMatches(value).length > open.allMatches(value).length) {
        value = value.substring(0, value.length - 1);
      }
    }
    final url = Uri.tryParse(value);
    if (url == null || url.host.isEmpty || url.userInfo.isNotEmpty) continue;
    final range = line.range(match.start, match.start + value.length);
    if (range != null && range.contains(cell)) return (url: url, range: range);
  }
  return null;
}
