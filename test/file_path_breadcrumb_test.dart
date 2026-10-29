import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/sftp/file_path_breadcrumb.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pumpPath(
    WidgetTester tester, {
    required String path,
    required double width,
    bool remote = false,
    ValueChanged<String>? onNavigate,
    double textScale = 1,
  }) => tester.pumpWidget(
    ShadcnTestApp(
      home: shadcn.Scaffold(
        child: Center(
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: SizedBox(
                width: width,
                child: FilePathBreadcrumb(
                  path: path,
                  remote: remote,
                  onNavigate: onNavigate,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void expectNoHorizontalOverflow(WidgetTester tester) {
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  }

  testWidgets('短路径完整展示，祖先目录可点击', (tester) async {
    String? target;
    await pumpPath(
      tester,
      path: '/home/user',
      width: 500,
      onNavigate: (path) => target = path,
    );
    expect(find.text('/'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('user'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-overflow')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sftp-path-segment-/home')));
    expect(target, '/home');
    expectNoHorizontalOverflow(tester);
  });

  for (final remote in [false, true]) {
    testWidgets('${remote ? '远程' : '本地'}长路径折叠中间层，保留父目录和当前目录', (tester) async {
      String? target;
      await pumpPath(
        tester,
        path: '/Users/zhongxuming/Downloads/engtek',
        width: 220,
        remote: remote,
        onNavigate: (path) => target = path,
      );
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('engtek'), findsOneWidget);
      expect(find.text('zhongxuming'), findsNothing);
      expect(find.byKey(const ValueKey('sftp-path-overflow')), findsOneWidget);
      expectNoHorizontalOverflow(tester);
      await tester.tap(
        find.byKey(
          const ValueKey('sftp-path-segment-/Users/zhongxuming/Downloads'),
        ),
      );
      expect(target, '/Users/zhongxuming/Downloads');
      await tester.tap(find.byKey(const ValueKey('sftp-path-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('zhongxuming'));
      await tester.pumpAndSettle();
      expect(target, '/Users/zhongxuming');
    });
  }

  testWidgets('父目录和当前目录的长名称都可见，省略文字且不溢出', (tester) async {
    const path =
        '/first/second/parent-directory-with-a-long-name/current-directory-with-a-long-name';
    await pumpPath(tester, path: path, width: 180, onNavigate: (_) {});
    expect(find.text('parent-directory-with-a-long-name'), findsOneWidget);
    expect(find.text('current-directory-with-a-long-name'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-overflow')), findsOneWidget);
    expectNoHorizontalOverflow(tester);
  });

  testWidgets('窗口变宽后原路径恢复完整展示', (tester) async {
    const path = '/first/second/parent/current';
    await pumpPath(tester, path: path, width: 180);
    expect(find.byKey(const ValueKey('sftp-path-overflow')), findsOneWidget);
    await pumpPath(tester, path: path, width: 700);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-overflow')), findsNothing);
    expectNoHorizontalOverflow(tester);
  });

  for (final path in [
    r'C:\Users\username\Downloads\current',
    r'\\server\share\first\Downloads\current',
  ]) {
    testWidgets('Windows 路径折叠后导航仍使用原有根目录：$path', (tester) async {
      String? target;
      await pumpPath(
        tester,
        path: path,
        width: 190,
        onNavigate: (path) => target = path,
      );
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('current'), findsOneWidget);
      expectNoHorizontalOverflow(tester);
      final parent = path.substring(0, path.lastIndexOf(r'\'));
      await tester.tap(find.byKey(ValueKey('sftp-path-segment-$parent')));
      expect(target, parent);
    });
  }

  testWidgets('放大文字后也不溢出，加载时禁用省略号和目录导航', (tester) async {
    await pumpPath(
      tester,
      path: '/first/second/Downloads/current',
      width: 200,
      textScale: 1.5,
    );
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('current'), findsOneWidget);
    expectNoHorizontalOverflow(tester);
    final overflow = tester.widget<shadcn.TextButton>(
      find.byKey(const ValueKey('sftp-path-overflow')),
    );
    expect(overflow.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('sftp-path-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });
}
