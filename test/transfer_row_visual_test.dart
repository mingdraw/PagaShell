import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';

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
}
