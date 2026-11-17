import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/in_memory_local_file_repository.dart';
import 'support/shadcn_test_app.dart';

void main() {
  setUpAll(() async {
    await (FontLoader('packages/shadcn_flutter/GeistSans')..addFont(
          rootBundle.load(
            'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
          ),
        ))
        .load();
  });
  tearDown(Get.reset);

  testWidgets('真实字体下文件名与末尾标签使用相同基线并居中于进度条', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = Get.put(TransferController());
    final task = TransferTask(
      id: 'visual',
      sessionId: 's1',
      kind: TransferKind.upload,
      fileName: 'scm-service-warehouse.jar',
      localPath: '/local/source',
      remotePath: '/remote/target',
    );
    task.status.value = TransferStatus.done;
    task.transferred.value = 100;
    task.total.value = 100;
    controller.tasks.add(task);
    final engine = FakeSftpSession();
    addTearDown(engine.close);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 's1',
            host: const Host(id: 'h1', name: 'test', hostname: 'test'),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: InMemoryLocalFileRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    final nameFinder = find.text(task.fileName);
    final transferRow = find
        .ancestor(of: nameFinder, matching: find.byType(Row))
        .first;
    final sizeFinder = find.descendant(
      of: transferRow,
      matching: find.text('100 B'),
    );
    final label = tester.getRect(nameFinder);
    final sizeLabel = tester.getRect(sizeFinder);
    final bar = tester.getRect(
      find.byKey(const ValueKey('sftp-transfer-progress-visual')),
    );
    final nameParagraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: nameFinder, matching: find.byType(RichText)),
    );
    final sizeParagraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: sizeFinder, matching: find.byType(RichText)),
    );
    expect(label.center.dy, closeTo(bar.center.dy, 0.01));
    expect(sizeLabel.center.dy, closeTo(bar.center.dy, 0.01));
    expect(label.height, closeTo(sizeLabel.height, 0.01));
    expect(
      label.top +
          nameParagraph.getDryBaseline(
            nameParagraph.constraints,
            TextBaseline.alphabetic,
          )!,
      closeTo(
        sizeLabel.top +
            sizeParagraph.getDryBaseline(
              sizeParagraph.constraints,
              TextBaseline.alphabetic,
            )!,
        0.01,
      ),
      reason: '文件名与末尾标签共用文字排版和垂直居中方式',
    );
  });

  testWidgets('失败原因在路径同行靠右，窄窗口省略且保留完整提示', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = Get.put(TransferController());
    final task = TransferTask(
      id: 'failed-visual',
      sessionId: 's1',
      kind: TransferKind.download,
      fileName: 'long-file-name.zip',
      localPath: '/local/target.zip',
      remotePath: '/remote/very-long-directory-name/long-file-name.zip',
    );
    final reason = List.filled(12, '远程服务读取失败').join('，');
    task.status.value = TransferStatus.failed;
    task.transferred.value = 25;
    task.total.value = 100;
    task.error.value = reason;
    controller.tasks.add(task);
    final engine = FakeSftpSession();
    addTearDown(engine.close);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: SftpPanel(
          session: Session(
            id: 's1',
            host: const Host(id: 'h1', name: 'test', hostname: 'test'),
            phase: SessionPhase.ready,
            engineSession: engine,
          ),
          localFiles: InMemoryLocalFileRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('sftp-transfer-row-failed-visual'));
    final path = find.byKey(const ValueKey('sftp-transfer-path-failed-visual'));
    final error = find.byKey(
      const ValueKey('sftp-transfer-error-failed-visual'),
    );
    final size = find.byKey(
      const ValueKey('sftp-transfer-label-failed-visual'),
    );
    final bar = find.byKey(
      const ValueKey('sftp-transfer-progress-failed-visual'),
    );
    for (final width in [1200.0, 600.0]) {
      tester.view.physicalSize = Size(width, 600);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(size).data, '25 B');
      expect(tester.widget<Text>(error).data, reason);
      expect(tester.widget<Text>(error).overflow, TextOverflow.ellipsis);
      expect(tester.getSize(error).width, lessThanOrEqualTo(220));
      expect(
        tester.getCenter(error).dy,
        closeTo(tester.getCenter(path).dy, 0.5),
      );
      expect(tester.getRect(path).right, lessThan(tester.getRect(error).left));
      expect(
        tester.getRect(error).right,
        closeTo(tester.getRect(row).right - 12, 0.5),
      );
      expect(
        tester.getRect(error).top,
        greaterThan(tester.getRect(bar).bottom),
      );
      expect(
        find.ancestor(of: error, matching: find.byType(shadcn.Tooltip)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    task.error.value = ' ';
    await tester.pump();
    expect(tester.widget<Text>(error).data, '传输未完成，请检查连接后重试');
    task.status.value = TransferStatus.done;
    await tester.pump();
    expect(error, findsNothing);
    expect(tester.widget<Text>(size).data, '25 B');
  });
}
