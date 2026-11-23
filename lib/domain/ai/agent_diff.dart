import 'dart:math';
import 'dart:typed_data';

class TextFileEdit {
  const TextFileEdit(this.oldText, this.newText);
  final String oldText, newText;
}

String applyTextFileEdits(String original, List<TextFileEdit> edits) {
  var result = original;
  for (final edit in edits) {
    if (edit.oldText.isEmpty) throw const FormatException('待替换文本不能为空');
    final index = result.indexOf(edit.oldText);
    if (index < 0) throw const FormatException('未找到待替换文本，请重新读取文件');
    if (result.indexOf(edit.oldText, index + 1) != -1) {
      throw const FormatException('待替换文本出现多次，请提供更具体的片段');
    }
    result = result.replaceRange(
      index,
      index + edit.oldText.length,
      edit.newText,
    );
    if (result.length > 2 * 1024 * 1024) {
      throw const FormatException('文本文件不能超过 2 MiB');
    }
  }
  return result;
}

enum DiffLineKind { context, added, removed }

class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffLineKind kind;

  /// Includes the line ending when present.
  final String text;
}

class DiffHunk {
  const DiffHunk(
    this.oldStart,
    this.newStart,
    this.oldCount,
    this.newCount,
    this.lines,
  );
  final int oldStart, newStart, oldCount, newCount;
  final List<DiffLine> lines;
}

class UnifiedDiff {
  UnifiedDiff._(this.hunks, this.added, this.removed);
  final List<DiffHunk> hunks;
  final int added, removed;

  String toText(String path, {int maxChars = 24000}) {
    if (hunks.isEmpty) return '';
    final result = StringBuffer('--- $path\n+++ $path\n');
    for (final hunk in hunks) {
      result.writeln(
        '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
      );
      for (final line in hunk.lines) {
        final prefix = switch (line.kind) {
          DiffLineKind.context => ' ',
          DiffLineKind.added => '+',
          DiffLineKind.removed => '-',
        };
        if (result.length + line.text.length + 1 > maxChars) {
          result.writeln('…');
          return result.toString();
        }
        result.write(prefix);
        result.write(line.text);
        if (!line.text.endsWith('\n')) {
          result.writeln();
          result.writeln(r'\ No newline at end of file');
        }
      }
    }
    return result.toString();
  }

  factory UnifiedDiff.between(
    String original,
    String updated, {
    int context = 3,
  }) {
    final oldLines = _lines(original);
    final newLines = _lines(updated);
    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }
    var oldEnd = oldLines.length;
    var newEnd = newLines.length;
    while (oldEnd > prefix &&
        newEnd > prefix &&
        oldLines[oldEnd - 1] == newLines[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    final leading = max(0, prefix - context);
    final lines = [
      for (var i = leading; i < prefix; i++)
        DiffLine(DiffLineKind.context, oldLines[i]),
      ..._changes(
        oldLines.sublist(prefix, oldEnd),
        newLines.sublist(prefix, newEnd),
      ),
      for (var i = oldEnd; i < min(oldEnd + context, oldLines.length); i++)
        DiffLine(DiffLineKind.context, oldLines[i]),
    ];
    final ranges = <(int, int)>[];
    var added = 0;
    var removed = 0;
    for (var i = 0; i < lines.length; i++) {
      switch (lines[i].kind) {
        case DiffLineKind.context:
          continue;
        case DiffLineKind.added:
          added++;
        case DiffLineKind.removed:
          removed++;
      }
      final start = max(0, i - context);
      final end = min(lines.length, i + context + 1);
      if (ranges.isNotEmpty && start <= ranges.last.$2) {
        ranges[ranges.length - 1] = (ranges.last.$1, end);
      } else {
        ranges.add((start, end));
      }
    }
    var oldStart = leading + 1;
    var newStart = leading + 1;
    var position = 0;
    final hunks = <DiffHunk>[];
    for (final (start, end) in ranges) {
      while (position < start) {
        final line = lines[position++];
        if (line.kind != DiffLineKind.added) oldStart++;
        if (line.kind != DiffLineKind.removed) newStart++;
      }
      final hunkLines = lines.sublist(start, end);
      final oldCount = hunkLines
          .where((line) => line.kind != DiffLineKind.added)
          .length;
      final newCount = hunkLines
          .where((line) => line.kind != DiffLineKind.removed)
          .length;
      hunks.add(
        DiffHunk(
          oldCount == 0 ? oldStart - 1 : oldStart,
          newCount == 0 ? newStart - 1 : newStart,
          oldCount,
          newCount,
          List.unmodifiable(hunkLines),
        ),
      );
      position = end;
      oldStart += oldCount;
      newStart += newCount;
    }
    return UnifiedDiff._(List.unmodifiable(hunks), added, removed);
  }
}

List<String> _lines(String text) => [
  for (final match in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text)) match[0]!,
];

Iterable<DiffLine> _changes(
  List<String> oldLines,
  List<String> newLines,
) sync* {
  final m = oldLines.length;
  final n = newLines.length;
  // Common prefixes/suffixes are already removed. For a very large
  // replacement, show a single delete/add region without quadratic work.
  if (m == 0 || n == 0 || (m + 1) * (n + 1) > 1000000) {
    yield* oldLines.map((line) => DiffLine(DiffLineKind.removed, line));
    yield* newLines.map((line) => DiffLine(DiffLineKind.added, line));
    return;
  }
  final width = n + 1;
  final table = Uint32List((m + 1) * width);
  for (var i = m - 1; i >= 0; i--) {
    for (var j = n - 1; j >= 0; j--) {
      final at = i * width + j;
      table[at] = oldLines[i] == newLines[j]
          ? 1 + table[at + width + 1]
          : max(table[at + width], table[at + 1]);
    }
  }
  var i = 0;
  var j = 0;
  while (i < m || j < n) {
    if (i < m && j < n && oldLines[i] == newLines[j]) {
      yield DiffLine(DiffLineKind.context, oldLines[i++]);
      j++;
    } else if (i < m &&
        (j == n || table[(i + 1) * width + j] >= table[i * width + j + 1])) {
      yield DiffLine(DiffLineKind.removed, oldLines[i++]);
    } else {
      yield DiffLine(DiffLineKind.added, newLines[j++]);
    }
  }
}
