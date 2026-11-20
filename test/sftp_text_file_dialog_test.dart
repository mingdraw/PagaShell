import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/entities/small_text_file.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/sftp/small_text_file_dialog.dart';

import 'support/shadcn_test_app.dart';

const _editor = ValueKey('sftp-text-editor');

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  testWidgets('关闭前确认草稿，快捷键保存 BOM 和单层 CRLF', (tester) async {
    await tester.pumpWidget(const ShadcnTestApp(home: SizedBox.expand()));
    final original = SmallTextFile('\uFEFFa=1\r\nb=2\r\n', DateTime.utc(2026));
    SmallTextFile? usedSnapshot;
    String? saved;
    final result = AppNavigation.dialog<bool>(
      SmallTextFileDialog(
        name: 'config.txt',
        path: '/config.txt',
        read: () async => original,
        save: (snapshot, text) async {
          usedSnapshot = snapshot;
          saved = text;
        },
      ),
    );
    await tester.pumpAndSettle();
    final editor = find.byKey(_editor);
    await tester.enterText(editor, 'a=3\r\nb=4\n');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    expect(saved, isNull);

    await tester.tap(editor);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(usedSnapshot, same(original));
    expect(saved, '\uFEFFa=3\r\nb=4\r\n');
    expect(await result, isTrue);
  });

  testWidgets('矮窗口读取失败后可重试，保存冲突时确认后重载新快照', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(650, 420);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ShadcnTestApp(home: SizedBox.expand()));
    var reads = 0;
    unawaited(
      AppNavigation.dialog<bool>(
        SmallTextFileDialog(
          name: 'test.txt',
          path: '/test.txt',
          read: () async {
            reads++;
            if (reads == 1) throw const SmallTextFileException('无法读取文本，请重试');
            return SmallTextFile(
              'revision $reads',
              DateTime.utc(2026, 1, reads),
            );
          },
          save: (_, _) async =>
              throw const SmallTextFileException('文件已被修改，请重新打开'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final reload = find.byKey(const ValueKey('sftp-text-reload'));
    expect(find.text('无法读取文本，请重试'), findsOneWidget);
    await tester.tap(reload);
    await tester.pumpAndSettle();
    expect(find.text('revision 2'), findsOneWidget);
    await tester.enterText(find.byKey(_editor), 'draft');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sftp-text-save')));
    await tester.pumpAndSettle();
    expect(find.text('文件已被修改，请重新打开'), findsOneWidget);
    await tester.tap(reload);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('revision 3'), findsOneWidget);
    expect(find.text('draft'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
