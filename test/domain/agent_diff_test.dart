import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ai/agent_diff.dart';

void main() {
  test('requires one exact match per edit, including overlapping matches', () {
    expect(
      applyTextFileEdits('one\ntwo\n', const [
        TextFileEdit('one', '1'),
        TextFileEdit('1\ntwo', 'two'),
      ]),
      'two\n',
    );
    expect(
      () => applyTextFileEdits('aaa', const [TextFileEdit('aa', 'b')]),
      throwsFormatException,
    );
    expect(
      () => applyTextFileEdits('a', const [TextFileEdit('x', 'b')]),
      throwsFormatException,
    );
    expect(
      () => applyTextFileEdits('a', const [TextFileEdit('', 'b')]),
      throwsFormatException,
    );
  });

  test(
    'unified diff preserves ranges, context and unterminated last lines',
    () {
      final diff = UnifiedDiff.between('a\nb\nc\nd\n', 'a\nb\nC\nd\n');
      expect(diff.added, 1);
      expect(diff.removed, 1);
      expect(
        diff.toText('/tmp/config'),
        contains('@@ -1,4 +1,4 @@\n a\n b\n-c\n+C\n d\n'),
      );
      expect(
        UnifiedDiff.between('', 'new').toText('/tmp/config'),
        contains('@@ -0,0 +1,1 @@\n+new\n\\ No newline at end of file'),
      );
      expect(
        UnifiedDiff.between('old\n', '').toText('/tmp/config'),
        contains('@@ -1,1 +0,0 @@\n-old'),
      );
      expect(UnifiedDiff.between('a', 'a').hunks, isEmpty);
      final original = List.generate(24, (i) => 'line $i').join('\n');
      final updated = original
          .replaceFirst('line 2\n', 'new 2\n')
          .replaceFirst('line 18\n', 'new 18\n');
      expect(UnifiedDiff.between(original, updated).hunks, hasLength(2));
    },
  );

  test(
    'Myers diff keeps minimal hunks on large configs with edits near both ends',
    () {
      final originalLines = List.generate(2000, (i) => 'option_$i = $i\n');
      final updatedLines = List<String>.of(originalLines)
        ..[5] = 'option_5 = tuned_5\n'
        ..[1995] = 'option_1995 = tuned_1995\n';
      final diff = UnifiedDiff.between(
        originalLines.join(),
        updatedLines.join(),
      );
      expect(diff.added, 2);
      expect(diff.removed, 2);
      expect(diff.hunks, hasLength(2));
      final rendered = diff.toText('/etc/mysql/mysqld.cnf');
      expect(rendered, contains('-option_5 = 5\n+option_5 = tuned_5\n'));
      expect(
        rendered,
        contains('-option_1995 = 1995\n+option_1995 = tuned_1995\n'),
      );
    },
  );
}
