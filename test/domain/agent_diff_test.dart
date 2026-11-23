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
}
