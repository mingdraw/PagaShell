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
  final search = TerminalTextSearch();
  try {
    return await search.find(
      buffer,
      query,
      regex: regex,
      caseSensitive: caseSensitive,
    );
  } finally {
    search.dispose();
  }
}

/// Reuses an isolate during a search session. Only immutable text crosses the
/// isolate boundary; cell coordinates are resolved against still-live rows.
class TerminalTextSearch {
  TerminalTextSearch({this.timeout = const Duration(milliseconds: 650)});

  final Duration timeout;
  final _ports = <ReceivePort>{};
  Isolate? _worker;
  Future<SendPort>? _ready;
  int _generation = 0;
  bool _disposed = false;

  Future<List<TerminalTextMatch>> find(
    Buffer buffer,
    String query, {
    required bool regex,
    required bool caseSensitive,
  }) async {
    if (_disposed || query.isEmpty) return const [];
    final generation = _generation;
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
    final replies = _openPort();
    try {
      final sendPort = await (_ready ??= _start(generation)).timeout(timeout);
      if (generation != _generation) return const [];
      sendPort.send((request, replies.sendPort));
      final reply = await replies.first.timeout(timeout);
      if (generation != _generation) return const [];
      if (reply == null) throw const FormatException();
      final matches = reply as List<_TextMatch>;
      return [
        for (final match in matches)
          ?lines[match.row].range(match.start, match.end),
      ];
    } on Object catch (error) {
      if (generation != _generation) return const [];
      // A pathological RegExp cannot be interrupted cooperatively. Replace the
      // worker after a timeout so subsequent queries can still run.
      if (error is! FormatException) cancel();
      rethrow;
    } finally {
      _closePort(replies);
    }
  }

  ReceivePort _openPort() {
    final port = ReceivePort();
    _ports.add(port);
    return port;
  }

  void _closePort(ReceivePort port) {
    if (_ports.remove(port)) port.close();
  }

  Future<SendPort> _start(int generation) async {
    final ready = _openPort();
    try {
      final worker = await Isolate.spawn(_searchWorker, ready.sendPort);
      if (_generation != generation) {
        worker.kill(priority: Isolate.immediate);
        throw StateError('Terminal search cancelled');
      }
      _worker = worker;
      return (await ready.first) as SendPort;
    } finally {
      _closePort(ready);
    }
  }

  void cancel() {
    _generation++;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _ready = null;
    final ports = _ports.toList();
    _ports.clear();
    for (final port in ports) {
      port.close();
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
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

Future<void> _searchWorker(SendPort ready) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  await for (final Object? message in requests) {
    final (request, reply) = message as (_SearchRequest, SendPort);
    try {
      reply.send(_find(request));
    } on FormatException {
      reply.send(null);
    }
  }
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
