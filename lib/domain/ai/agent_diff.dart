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

List<String> _lines(String text) {
  if (text.isEmpty) return const [];
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final newline = text.indexOf('\n', start);
    if (newline < 0) {
      lines.add(text.substring(start));
      break;
    }
    lines.add(text.substring(start, newline + 1));
    start = newline + 1;
  }
  return lines;
}

const _maxMyersDistance = 1500;

/// Myers O((M + N) * D) shortest edit script with line-hash prefiltering.
/// Falls back to a single remove/add block only when the edit distance itself
/// exceeds [_maxMyersDistance], rather than failing on large files with small
/// edits near both ends.
Iterable<DiffLine> _changes(List<String> oldLines, List<String> newLines) {
  final m = oldLines.length;
  final n = newLines.length;
  if (m == 0) {
    return [for (final line in newLines) DiffLine(DiffLineKind.added, line)];
  }
  if (n == 0) {
    return [for (final line in oldLines) DiffLine(DiffLineKind.removed, line)];
  }
  final maxD = min(m + n, _maxMyersDistance);
  final offset = maxD;
  final v = Int32List(2 * maxD + 1);
  final oldHashes = Int32List(m);
  for (var i = 0; i < m; i++) {
    oldHashes[i] = oldLines[i].hashCode;
  }
  final newHashes = Int32List(n);
  for (var j = 0; j < n; j++) {
    newHashes[j] = newLines[j].hashCode;
  }
  final trace = <Int32List>[];
  var foundD = -1;
  for (var d = 0; d <= maxD; d++) {
    for (var k = -d; k <= d; k += 2) {
      final int startX;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        startX = v[offset + k + 1];
      } else {
        startX = v[offset + k - 1] + 1;
      }
      var x = startX;
      var y = x - k;
      while (x < m &&
          y < n &&
          oldHashes[x] == newHashes[y] &&
          oldLines[x] == newLines[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= m && y >= n) {
        foundD = d;
        break;
      }
    }
    if (foundD >= 0) break;
    final snapshot = Int32List(2 * d + 1);
    snapshot.setRange(0, snapshot.length, v, offset - d);
    trace.add(snapshot);
  }
  if (foundD < 0) {
    return [
      for (final line in oldLines) DiffLine(DiffLineKind.removed, line),
      for (final line in newLines) DiffLine(DiffLineKind.added, line),
    ];
  }
  final reversed = <DiffLine>[];
  var x = m;
  var y = n;
  for (var d = foundD; d > 0; d--) {
    final prev = trace[d - 1];
    final prevOffset = d - 1;
    final k = x - y;
    final int prevK;
    if (k == -d ||
        (k != d && prev[prevOffset + k - 1] < prev[prevOffset + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = prev[prevOffset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
      reversed.add(DiffLine(DiffLineKind.context, oldLines[x]));
    }
    if (x > prevX) {
      x--;
      reversed.add(DiffLine(DiffLineKind.removed, oldLines[x]));
    } else if (y > prevY) {
      y--;
      reversed.add(DiffLine(DiffLineKind.added, newLines[y]));
    }
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    reversed.add(DiffLine(DiffLineKind.context, oldLines[x]));
  }
  return reversed.reversed;
}
