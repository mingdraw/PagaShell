import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/sftp/local_file_controller.dart';
import 'package:pagashell/application/sftp/sftp_controller.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/local_file_entry.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_list_row.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/sftp/file_browser_pane.dart';
import 'package:pagashell/presentation/sftp/sftp_panel.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/fake_sftp_session.dart';
import 'support/in_memory_local_file_repository.dart';
import 'support/native_file_drop.dart';
import 'support/shadcn_test_app.dart';

SftpDirEntry _file(String name, int size) =>
    SftpDirEntry(name: name, isDir: false, size: size);

class _PendingUploadSession extends FakeSftpSession {
  _PendingUploadSession({required super.localFiles});
  final progress = StreamController<SftpTransferProgress>();

  void disposeUpload() => unawaited(progress.close());

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) {
    uploads.add((localPath, remotePath));
    return progress.stream;
  }
}

class _RetryUploadSession extends FakeSftpSession {
  _RetryUploadSession({required super.localFiles});
  final attempts = <StreamController<SftpTransferProgress>>[];

  void disposeUploads() {
    for (final attempt in attempts) {
      unawaited(attempt.close());
    }
  }

  @override
  Stream<SftpTransferProgress> upload(String localPath, String remotePath) {
    uploads.add((localPath, remotePath));
    final attempt = StreamController<SftpTransferProgress>();
    attempts.add(attempt);
    return attempt.stream;
  }
}

void main() {
  setUpAll(DesktopDrop.instance.init);
  tearDown(Get.reset);

  const host = Host(id: 'h1', name: 'web-01', hostname: '10.0.0.5');

  Future<FakeSftpSession> pumpPanel(
    WidgetTester tester, {
    InMemoryLocalFileRepository? files,
    LocalDirectoryPicker directoryPicker = getDirectoryPath,
    shadcn.ThemeData? theme,
    bool active = true,
    FakeSftpSession? sshEngine,
  }) async {
    Get.put(TransferController());
    final localFiles = files ?? InMemoryLocalFileRepository();
    final engine = sshEngine ?? FakeSftpSession(localFiles: localFiles);
    final session = Session(
      id: 's1',
      host: host,
      phase: SessionPhase.ready,
      engineSession: engine,
    );
    await tester.pumpWidget(
      ShadcnTestApp(
        theme: theme,
        home: shadcn.Scaffold(
          child: SftpPanel(
            session: session,
            localFiles: localFiles,
            directoryPicker: directoryPicker,
            active: active,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return engine;
  }

  Finder pane(String side) => find.byKey(ValueKey('sftp-$side-pane'));

  Finder pathSegment(String side, String path) => find.descendant(
    of: pane(side),
    matching: find.byKey(ValueKey('sftp-path-segment-$path')),
  );

  Finder fileIn(String side, String name) =>
      find.descendant(of: pane(side), matching: find.text(name));

  Set<String> selectedPaths(String side) => find
      .descendant(of: pane(side), matching: find.byType(AppSurfaceAction))
      .evaluate()
      .map((element) => element.widget as AppSurfaceAction)
      .where((row) => row.selected)
      .map((row) => (row.key! as ValueKey<String>).value)
      .toSet();

  Future<void> selectFile(WidgetTester tester, String side, String name) async {
    await tester.tap(fileIn(side, name));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  LocalFileController localController(WidgetTester tester) =>
      Get.find<LocalFileController>(
        tag:
            'sftp-s1-${identityHashCode(tester.state(find.byType(SftpPanel)))}',
      );

  Future<void> openLocalDownloads(WidgetTester tester) async {
    await tester.tap(fileIn('local', 'downloads'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(fileIn('local', 'downloads'));
    await tester.pumpAndSettle();
  }

  Future<void> dragFile(
    WidgetTester tester,
    Finder source,
    Offset target,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(source));
    await gesture.moveBy(const Offset(15, 0));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('外部多文件拖到远程空白区上传到当前目录并刷新列表', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/100% + 中文.txt', 10)
      ..putFile('/external/.hidden.txt', 20);
    final engine = await pumpPanel(tester, files: files);
    await nativeFileDrop(
      tester,
      tester.getBottomRight(pane('remote')) - const Offset(20, 30),
      [
        '/external/100% + 中文.txt',
        '/external/.hidden.txt',
        '/external/.hidden.txt',
      ],
    );
    expect(engine.uploads, [
      ('/external/100% + 中文.txt', '/home/test/100% + 中文.txt'),
      ('/external/.hidden.txt', '/home/test/.hidden.txt'),
    ]);
    expect(fileIn('remote', '100% + 中文.txt'), findsOneWidget);
    expect(fileIn('remote', '.hidden.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部文件拖到远程文件夹行使用该文件夹，目录条目不作为文件上传', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/a.txt', 10);
    final engine = await pumpPanel(tester, files: files);
    await nativeFileDrop(tester, tester.getCenter(fileIn('remote', 'logs')), [
      {'path': '/external/folder', 'isDirectory': true},
      {'path': '/external/a.txt'},
    ], macOS: true);
    expect(engine.uploads, [('/external/a.txt', '/home/test/logs/a.txt')]);
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    expect(fileIn('remote', 'a.txt'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('外部多文件同名冲突复用跳过及后续相同操作规则', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/a.txt', 10)
      ..putFile('/external/b.txt', 20)
      ..putFile('/external/new.txt', 30);
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.addAll([_file('a.txt', 1), _file('b.txt', 2)]);
    await nativeFileDrop(
      tester,
      tester.getBottomRight(pane('remote')) - const Offset(20, 30),
      ['/external/a.txt', '/external/b.txt', '/external/new.txt'],
    );
    expect(find.text('覆盖「a.txt」？'), findsOneWidget);
    await tester.tap(find.text('后续文件采用相同操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(engine.uploads, [('/external/new.txt', '/home/test/new.txt')]);
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('外部拖到本地、后台标签或弹框遮挡区域不上传', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/a.txt', 10);
    final engine = await pumpPanel(tester, files: files, active: false);
    await nativeFileDrop(tester, tester.getCenter(pane('remote')), [
      '/external/a.txt',
    ]);
    expect(engine.uploads, isEmpty);
    final panel = tester.widget<SftpPanel>(find.byType(SftpPanel));
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: SftpPanel(session: panel.session, localFiles: files),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await nativeFileDrop(tester, tester.getCenter(pane('local')), [
      '/external/a.txt',
    ]);
    expect(engine.uploads, isEmpty);
    await tester.tap(findAppIconButton('新建目录'));
    await tester.pumpAndSettle();
    await nativeFileDrop(tester, tester.getCenter(pane('remote')), [
      '/external/a.txt',
    ]);
    expect(engine.uploads, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('外部拖到工具栏不会命中已滚出列表的目录行', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/a.txt', 10);
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.addAll(
      List.generate(30, (index) => _file('file-$index', 1)),
    );
    await tester.tap(findAppIconButton('刷新').last);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.descendant(of: pane('remote'), matching: find.byType(ListView)),
    );
    list.controller!.jumpTo(100);
    await tester.pump();
    await nativeFileDrop(
      tester,
      tester.getTopLeft(pane('remote')) + const Offset(100, 20),
      ['/external/a.txt'],
    );
    expect(engine.uploads, [('/external/a.txt', '/home/test/a.txt')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS 拖入文件权限保持到上传取消，且只释放一次', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/a.txt', 10);
    final engine = _PendingUploadSession(localFiles: files);
    addTearDown(engine.disposeUpload);
    final calls = <String>[];
    const channel = MethodChannel('desktop_drop');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pumpPanel(tester, files: files, sshEngine: engine);
    await nativeFileDrop(tester, tester.getCenter(pane('remote')), [
      {
        'path': '/external/a.txt',
        'apple-bookmark': Uint8List.fromList([1, 2, 3]),
      },
    ], macOS: true);
    expect(calls, ['startAccessingSecurityScopedResource']);
    final controller = Get.find<TransferController>();
    await tester.runAsync(() => controller.cancel(controller.tasks.single.id));
    await tester.pumpAndSettle();
    expect(calls, [
      'startAccessingSecurityScopedResource',
      'stopAccessingSecurityScopedResource',
    ]);
    controller.clearFinished();
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
  });

  testWidgets('失败保留红色进度条，图标重试重新授权，成功保留绿色进度条并刷新列表', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..fs['/external'] = []
      ..putFile('/external/retry.txt', 100);
    final engine = _RetryUploadSession(localFiles: files);
    addTearDown(engine.disposeUploads);
    const channel = MethodChannel('desktop_drop');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pumpPanel(tester, files: files, sshEngine: engine);
    await nativeFileDrop(tester, tester.getCenter(pane('remote')), [
      {
        'path': '/external/retry.txt',
        'apple-bookmark': Uint8List.fromList([4, 5, 6]),
      },
    ], macOS: true);
    final controller = Get.find<TransferController>();
    final task = controller.tasks.single;
    engine.attempts.first.add(
      const SftpTransferProgress(transferred: 25, total: 100),
    );
    await tester.pump();
    await tester.runAsync(() async {
      engine.attempts.first.addError(const SshEngineException('写入远程文件失败'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    final bar = find.byKey(ValueKey('sftp-transfer-progress-${task.id}'));
    final colors = shadcn.Theme.of(tester.element(bar)).colorScheme;
    var indicator = tester.widget<shadcn.LinearProgressIndicator>(bar);
    expect(indicator.value, 0.25);
    expect(
      shadcn.ComponentTheme.maybeOf<shadcn.LinearProgressIndicatorTheme>(
        tester.element(bar),
      )!.color,
      colors.destructive,
    );
    expect(find.text('写入远程文件失败'), findsOneWidget);
    final failureLabel = find.byKey(ValueKey('sftp-transfer-label-${task.id}'));
    expect(
      tester.getRect(failureLabel).left,
      greaterThan(tester.getRect(bar).right),
    );
    expect(tester.widget<Text>(failureLabel).style!.color, colors.destructive);
    final row = find.byKey(ValueKey('sftp-transfer-row-${task.id}'));
    final fileName = find.descendant(
      of: row,
      matching: find.text(task.fileName),
    );
    expect(tester.widget<Text>(fileName).style!.color, colors.destructive);
    final action = find.byKey(ValueKey('sftp-transfer-action-${task.id}'));
    expect(
      tester.getRect(action).right,
      lessThan(tester.getRect(fileName).left),
    );
    expect(
      find.descendant(
        of: action,
        matching: find.byIcon(shadcn.LucideIcons.circleAlert),
      ),
      findsOneWidget,
    );
    final centerY = tester.getCenter(row).dy;
    expect(tester.getCenter(failureLabel).dy, closeTo(centerY, 0.5));
    expect(tester.getCenter(bar).dy, closeTo(centerY, 0.5));
    expect(
      tester
          .getCenter(find.byKey(ValueKey('sftp-transfer-name-${task.id}')))
          .dy,
      closeTo(centerY, 0.5),
    );
    expect(
      tester.getCenter(findAppIconButton('重试传输')).dy,
      closeTo(centerY, 0.5),
    );
    task.error.value = List.filled(20, '写入远程文件失败').join('，');
    await tester.pumpAndSettle();
    expect(tester.getSize(failureLabel).width, lessThanOrEqualTo(220));
    expect(tester.getSize(bar).width, greaterThan(0));
    expect(tester.takeException(), isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(action));
    await tester.pump();
    expect(
      find.descendant(
        of: findAppIconButton('重试传输'),
        matching: find.byIcon(shadcn.LucideIcons.rotateCw),
      ),
      findsOneWidget,
    );
    await tester.tap(findAppIconButton('重试传输'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(task.status.value, TransferStatus.running);
    expect(controller.tasks, [task]);
    expect(findAppIconButton('重试传输'), findsNothing);
    expect(find.text('写入远程文件失败'), findsNothing);
    expect(engine.uploads, [
      ('/external/retry.txt', '/home/test/retry.txt'),
      ('/external/retry.txt', '/home/test/retry.txt'),
    ]);
    expect(calls, [
      'startAccessingSecurityScopedResource',
      'stopAccessingSecurityScopedResource',
      'startAccessingSecurityScopedResource',
    ]);
    engine.fs['/home/test']!.add(_file('retry.txt', 100));
    await tester.runAsync(() async {
      engine.attempts.last.add(
        const SftpTransferProgress(transferred: 100, total: 100),
      );
      await engine.attempts.last.close();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    indicator = tester.widget<shadcn.LinearProgressIndicator>(bar);
    expect(indicator.value, 1);
    expect(
      shadcn.ComponentTheme.maybeOf<shadcn.LinearProgressIndicatorTheme>(
        tester.element(bar),
      )!.color,
      StatusColors.ready,
    );
    expect(tester.widget<Text>(fileName).style!.color, StatusColors.ready);
    expect(
      find.descendant(
        of: action,
        matching: find.byIcon(shadcn.LucideIcons.circleCheck),
      ),
      findsOneWidget,
    );
    expect(fileIn('remote', 'retry.txt'), findsOneWidget);
    expect(findAppIconButton('重试传输'), findsNothing);
    expect(calls.last, 'stopAccessingSecurityScopedResource');
    expect(calls, hasLength(4));
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('传输中最前方图标悬停变为 x，使用 text 图标按钮且点击可停止', (tester) async {
    final engine = _PendingUploadSession(
      localFiles: InMemoryLocalFileRepository(),
    );
    addTearDown(engine.disposeUpload);
    await pumpPanel(tester, sshEngine: engine);
    final controller = Get.find<TransferController>();
    final task = controller.startUpload(
      sessionId: 's1',
      engineSession: engine,
      localPath: '/local/upload.txt',
      remotePath: '/home/test/upload.txt',
    );
    engine.progress.add(
      const SftpTransferProgress(transferred: 25, total: 100),
    );
    await tester.pump();
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    final action = find.byKey(ValueKey('sftp-transfer-action-${task.id}'));
    final row = find.byKey(ValueKey('sftp-transfer-row-${task.id}'));
    final fileName = find.descendant(
      of: row,
      matching: find.text(task.fileName),
    );
    expect(
      tester.getRect(action).right,
      lessThan(tester.getRect(fileName).left),
    );
    expect(
      find.descendant(
        of: action,
        matching: find.byIcon(shadcn.LucideIcons.upload),
      ),
      findsOneWidget,
    );
    final button = tester.widget<shadcn.IconButton>(
      find.descendant(
        of: findAppIconButton('停止传输'),
        matching: find.byType(shadcn.IconButton),
      ),
    );
    expect(button.variance, shadcn.ButtonVariance.text);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(action));
    await tester.pump();
    expect(
      find.descendant(of: action, matching: find.byIcon(shadcn.LucideIcons.x)),
      findsOneWidget,
    );
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(
      find.descendant(
        of: action,
        matching: find.byIcon(shadcn.LucideIcons.upload),
      ),
      findsOneWidget,
    );
    await mouse.moveTo(tester.getCenter(action));
    await tester.pump();
    await tester.tap(findAppIconButton('停止传输'));
    await tester.pumpAndSettle();
    expect(task.status.value, TransferStatus.cancelled);
    expect(findAppIconButton('停止传输'), findsNothing);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('双栏按左本地右远程布局，列表占满可用高度', (tester) async {
    await pumpPanel(tester);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('远程文件'), findsOneWidget);
    expect(fileIn('local', 'upload.txt'), findsOneWidget);
    expect(fileIn('remote', 'readme.txt'), findsOneWidget);
    final local = tester.getRect(pane('local'));
    final remote = tester.getRect(pane('remote'));
    expect(local.top, remote.top);
    expect(local.right, lessThan(remote.left));
    expect(local.height, greaterThan(300));
    expect(find.byIcon(shadcn.LucideIcons.ellipsis), findsNothing);
    expect(find.text('拖拽文件到另一侧传输，双击文件夹打开'), findsNothing);
  });

  testWidgets('两侧文件鼠标按下立即选中，连续多选不等待双击判定或背景动画', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
    await pumpPanel(tester, files: files);
    for (final (side, name, path) in [
      ('local', 'a.txt', '/local/a.txt'),
      ('remote', 'readme.txt', '/home/test/readme.txt'),
    ]) {
      final gesture = await tester.startGesture(
        tester.getCenter(fileIn(side, name)),
      );
      await tester.pump();
      expect(selectedPaths(side), {'sftp-$side-row-$path'});
      final row = find.byKey(ValueKey('sftp-$side-row-$path'));
      final box = tester.widget<shadcn.OverflowDecoratedBox>(
        find
            .descendant(
              of: row,
              matching: find.byType(shadcn.OverflowDecoratedBox),
            )
            .first,
      );
      expect(
        (box.decoration as BoxDecoration).color,
        AppTheme.fileSelectionBackground(tester.element(row)),
      );
      await gesture.up();
      await tester.pump();
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(fileIn('local', 'upload.txt'));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(selectedPaths('local'), hasLength(2));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  });

  testWidgets('任务仅显示进度和已传输大小，标题总速率响应更新且只统计本标签', (tester) async {
    await pumpPanel(tester);
    final controller = Get.find<TransferController>();
    TransferTask task(String id, String session, double speed) {
      final value = TransferTask(
        id: id,
        sessionId: session,
        kind: TransferKind.upload,
        fileName: '$id.txt',
        remotePath: '/$id.txt',
        localPath: '/local/$id.txt',
      );
      value.total.value = 8192;
      value.bytesPerSecond.value = speed;
      return value;
    }

    final first = task('first', 's1', 1024);
    final second = task('second', 's1', 2048);
    first.transferred.value = 1024;
    second.transferred.value = 2048;
    controller.tasks.addAll([first, second, task('other', 's2', 8192)]);
    await tester.pumpAndSettle();
    expect(find.text('总速率 3.0 KB/s'), findsOneWidget);
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    expect(find.text('1.0 KB/s'), findsNothing);
    expect(find.text('2.0 KB/s'), findsNothing);
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(
      tester
          .widget<shadcn.LinearProgressIndicator>(
            find.byKey(const ValueKey('sftp-transfer-progress-first')),
          )
          .value,
      0.125,
    );
    first.bytesPerSecond.value = 512;
    second.status.value = TransferStatus.done;
    await tester.pumpAndSettle();
    expect(find.text('总速率 512 B/s'), findsOneWidget);
    expect(find.text('512 B/s'), findsNothing);
    expect(find.text('2.0 KB/s'), findsNothing);
    expect(formatTransferRate(1024 * 1024), '1.0 MB/s');
    expect(formatTransferRate(double.nan), '0 B/s');
  });

  testWidgets('两侧右键上传下载有图标，本地右键提供重命名和删除', (tester) async {
    await pumpPanel(tester);
    for (final (side, name, command, icon) in [
      ('local', 'upload.txt', '上传', shadcn.LucideIcons.upload),
      ('remote', 'readme.txt', '下载', shadcn.LucideIcons.download),
    ]) {
      await tester.tap(fileIn(side, name), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      final item = find.widgetWithText(shadcn.MenuButton, command);
      expect(item, findsOneWidget);
      expect(
        find.descendant(of: item, matching: find.byIcon(icon)),
        findsOneWidget,
      );
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('本地右键重命名和删除操作本地文件，取消删除保留文件', (tester) async {
    final files = InMemoryLocalFileRepository();
    final engine = await pumpPanel(tester, files: files);
    await tester.tap(
      fileIn('local', 'upload.txt'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'renamed.txt',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(fileIn('local', 'upload.txt'), findsNothing);
    expect(fileIn('local', 'renamed.txt'), findsOneWidget);
    expect(
      files.fs['/local']!
          .singleWhere((entry) => entry.name == 'renamed.txt')
          .path,
      '/local/renamed.txt',
    );
    for (final cancel in [true, false]) {
      await tester.tap(
        fileIn('local', 'renamed.txt'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除「renamed.txt」？'), findsOneWidget);
      await tester.tap(find.text(cancel ? '取消' : '删除'));
      await tester.pumpAndSettle();
      expect(
        fileIn('local', 'renamed.txt'),
        cancel ? findsOneWidget : findsNothing,
      );
    }
    expect(engine.removed, isEmpty);
    expect(fileIn('remote', 'readme.txt'), findsOneWidget);
  });

  testWidgets('本地隐藏文件和目录默认不可见，开关显示后关闭会清除隐藏文件选择', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/.secret', 10);
    files.fs['/local']!.add(
      const LocalFileEntry(
        path: '/local/.hidden-folder',
        name: '.hidden-folder',
        isDir: true,
        size: 0,
      ),
    );
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.add(_file('.remote-secret', 2));
    await tester.tap(findAppIconButton('刷新').last);
    await tester.pumpAndSettle();
    expect(fileIn('local', '.secret'), findsNothing);
    expect(fileIn('local', '.hidden-folder'), findsNothing);
    expect(fileIn('remote', '.remote-secret'), findsOneWidget);
    final toggle = find.descendant(
      of: pane('local'),
      matching: find.byType(shadcn.Switch),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(fileIn('local', '.secret'), findsOneWidget);
    expect(fileIn('local', '.hidden-folder'), findsOneWidget);
    await selectFile(tester, 'local', '.secret');
    expect(selectedPaths('local'), hasLength(1));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(fileIn('local', '.secret'), findsNothing);
    expect(selectedPaths('local'), isEmpty);
    expect(
      localController(tester).entries.any((entry) => entry.name == '.secret'),
      isTrue,
    );
  });

  testWidgets('同名弹框使用标准标题和按钮大小', (tester) async {
    const name = 'scm-service-main.jar';
    final files = InMemoryLocalFileRepository()..putFile('/local/$name', 10);
    final engine = await pumpPanel(tester, files: files);
    await tester.tap(findAppIconButton('新建目录'));
    await tester.pumpAndSettle();
    final standardButtonHeight = tester
        .getSize(find.widgetWithText(shadcn.OutlineButton, '取消'))
        .height;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    engine.fs['/home/test']!.add(_file(name, 2));
    await selectFile(tester, 'local', name);
    await tester.tap(findAppIconButton('上传所选文件'));
    await tester.pumpAndSettle();
    for (final label in ['取消', '跳过', '覆盖']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is shadcn.OutlineButton || widget is shadcn.PrimaryButton,
        ),
      );
      expect(tester.getSize(button).height, standardButtonHeight);
    }
    final title = tester.element(find.text('覆盖「$name」？'));
    expect(DefaultTextStyle.of(title).style.fontSize, 18);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  for (final modifier in [
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.controlLeft,
  ]) {
    testWidgets('${modifier.keyLabel} 多选可批量上传，普通单击替换选择', (tester) async {
      final files = InMemoryLocalFileRepository()
        ..putFile('/local/a.txt', 10)
        ..putFile('/local/b.txt', 20);
      final engine = await pumpPanel(tester, files: files);
      await selectFile(tester, 'local', 'a.txt');
      await tester.sendKeyDownEvent(modifier);
      await selectFile(tester, 'local', 'b.txt');
      await tester.sendKeyUpEvent(modifier);
      expect(selectedPaths('local'), hasLength(2));
      await tester.tap(findAppIconButton('上传所选文件'));
      await tester.pumpAndSettle();
      expect(engine.uploads, [
        ('/local/a.txt', '/home/test/a.txt'),
        ('/local/b.txt', '/home/test/b.txt'),
      ]);
      await selectFile(tester, 'local', 'upload.txt');
      expect(selectedPaths('local'), {'sftp-local-row-/local/upload.txt'});
      expect(selectedPaths('remote'), isEmpty);
    });
  }

  for (final dark in [true, false]) {
    testWidgets('${dark ? '深色' : '浅色'}主题下两侧多选行显示独立背景与文字颜色', (tester) async {
      final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
      await pumpPanel(
        tester,
        files: files,
        theme: dark ? AppTheme.shadcnDark : AppTheme.shadcnLight,
      );
      await selectFile(tester, 'local', 'a.txt');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await selectFile(tester, 'local', 'upload.txt');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await selectFile(tester, 'remote', 'readme.txt');

      Color? backgroundOf(String path) {
        final row = find.byKey(ValueKey(path));
        final box = tester.widget<shadcn.OverflowDecoratedBox>(
          find
              .descendant(
                of: row,
                matching: find.byType(shadcn.OverflowDecoratedBox),
              )
              .first,
        );
        return (box.decoration as BoxDecoration).color;
      }

      final context = tester.element(fileIn('local', 'a.txt'));
      final background = AppTheme.fileSelectionBackground(context);
      final foreground = AppTheme.fileSelectionForeground(context);
      final colors = shadcn.Theme.of(context).colorScheme;
      expect(background, isNot(colors.background));
      expect(background, isNot(colors.accent));
      for (final (side, name, path) in [
        ('local', 'a.txt', '/local/a.txt'),
        ('local', 'upload.txt', '/local/upload.txt'),
        ('remote', 'readme.txt', '/home/test/readme.txt'),
      ]) {
        expect(backgroundOf('sftp-$side-row-$path'), background);
        expect(
          tester.widget<Text>(fileIn(side, name)).style?.color,
          foreground,
        );
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await selectFile(tester, 'local', 'a.txt');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(backgroundOf('sftp-local-row-/local/a.txt'), isNot(background));
      expect(backgroundOf('sftp-local-row-/local/upload.txt'), background);
      expect(backgroundOf('sftp-remote-row-/home/test/readme.txt'), background);
    });
  }

  testWidgets('Shift 可按首尾范围选择，反向选择仍按列表顺序批量下载', (tester) async {
    final engine = await pumpPanel(tester);
    engine.fs['/home/test']!.addAll([_file('a.txt', 1), _file('b.txt', 2)]);
    await tester.tap(findAppIconButton('刷新').last);
    await tester.pumpAndSettle();
    await selectFile(tester, 'remote', 'readme.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await selectFile(tester, 'remote', 'a.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(selectedPaths('remote'), hasLength(3));
    await tester.tap(findAppIconButton('下载所选文件'));
    await tester.pumpAndSettle();
    expect(engine.downloads, [
      ('/home/test/a.txt', '/local/a.txt'),
      ('/home/test/b.txt', '/local/b.txt'),
      ('/home/test/readme.txt', '/local/readme.txt'),
    ]);
  });

  testWidgets('Cmd/Ctrl 切换选择，Shift 扩展；全选和 Escape 清除仅作用于当前侧', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/a.txt', 10)
      ..putFile('/local/b.txt', 20)
      ..putFile('/local/c.txt', 30);
    await pumpPanel(tester, files: files);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await selectFile(tester, 'local', 'c.txt');
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(selectedPaths('local'), {'sftp-local-row-/local/c.txt'});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await selectFile(tester, 'local', 'b.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(selectedPaths('local'), {
      'sftp-local-row-/local/a.txt',
      'sftp-local-row-/local/b.txt',
    });
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), hasLength(5));
    expect(selectedPaths('remote'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), isEmpty);
  });

  testWidgets('多选文件拖到另一侧时传输整组选中项', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
    final engine = await pumpPanel(tester, files: files);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await selectFile(tester, 'local', 'upload.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await dragFile(
      tester,
      fileIn('local', 'a.txt'),
      tester.getCenter(pane('remote')),
    );
    expect(engine.uploads, [
      ('/local/a.txt', '/home/test/a.txt'),
      ('/local/upload.txt', '/home/test/upload.txt'),
    ]);
  });

  testWidgets('多选后文件菜单的上传命令传输全部所选文件', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
    final engine = await pumpPanel(tester, files: files);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await selectFile(tester, 'local', 'upload.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    final row = find.byKey(const ValueKey('sftp-local-row-/local/a.txt'));
    await tester.tap(row, buttons: kSecondaryMouseButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(engine.uploads, [
      ('/local/a.txt', '/home/test/a.txt'),
      ('/local/upload.txt', '/home/test/upload.txt'),
    ]);
  });

  testWidgets('键盘 Shift+End 选择范围，Home 返回首项', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/a.txt', 10)
      ..putFile('/local/b.txt', 10);
    await pumpPanel(tester, files: files);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), hasLength(3));
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), {'sftp-local-row-/local/downloads'});
  });

  testWidgets('批量下载取消目录授权时结束整个批次，不逐个重复请求授权', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    var selections = 0;
    final engine = await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections++;
        return null;
      },
    );
    engine.fs['/home/test']!.add(_file('a.txt', 10));
    await tester.tap(findAppIconButton('刷新').last);
    await tester.pumpAndSettle();
    await selectFile(tester, 'remote', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await selectFile(tester, 'remote', 'readme.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await dragFile(
      tester,
      fileIn('remote', 'a.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(selections, 1);
    expect(engine.downloads, isEmpty);
    expect(Get.find<TransferController>().tasks, isEmpty);
  });

  testWidgets('刷新保留有效多选，切换目录清空选择', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
    await pumpPanel(tester, files: files);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await selectFile(tester, 'local', 'upload.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    files.fs['/local']!.removeWhere((entry) => entry.name == 'a.txt');
    await tester.tap(findAppIconButton('刷新').first);
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), {'sftp-local-row-/local/upload.txt'});
    await openLocalDownloads(tester);
    expect(selectedPaths('local'), isEmpty);
    await tester.tap(pathSegment('local', '/local'));
    await tester.pumpAndSettle();
    expect(selectedPaths('local'), isEmpty);
  });

  testWidgets('批量传输跳过当前同名文件后继续下一项', (tester) async {
    final files = InMemoryLocalFileRepository()..putFile('/local/a.txt', 10);
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.add(_file('a.txt', 5));
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await selectFile(tester, 'local', 'upload.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(findAppIconButton('上传所选文件'));
    await tester.pumpAndSettle();
    expect(find.text('覆盖「a.txt」？'), findsOneWidget);
    expect(engine.uploads, isEmpty);
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(engine.uploads, [('/local/upload.txt', '/home/test/upload.txt')]);
  });

  for (final source in ['local', 'remote']) {
    for (final overwrite in [true, false]) {
      testWidgets('$source 批量${overwrite ? '覆盖' : '跳过'}后续冲突，新批次重新询问', (
        tester,
      ) async {
        final files = InMemoryLocalFileRepository()
          ..putFile('/local/a.txt', 10)
          ..putFile('/local/b.txt', 20);
        final engine = await pumpPanel(tester, files: files);
        engine.fs['/home/test']!.addAll([_file('a.txt', 1), _file('b.txt', 2)]);
        await tester.tap(findAppIconButton('刷新').last);
        await tester.pumpAndSettle();
        final names = [
          'a.txt',
          'b.txt',
          source == 'local' ? 'upload.txt' : 'readme.txt',
        ];
        await selectFile(tester, source, names.first);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        for (final name in names.skip(1)) {
          await selectFile(tester, source, name);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        final command = source == 'local' ? '上传所选文件' : '下载所选文件';
        await tester.tap(findAppIconButton(command));
        await tester.pumpAndSettle();
        expect(find.text('覆盖「a.txt」？'), findsOneWidget);
        await tester.tap(find.text('后续文件采用相同操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(overwrite ? '覆盖' : '跳过'));
        await tester.pumpAndSettle();
        expect(find.byType(AppDialog), findsNothing);
        final transfers = source == 'local' ? engine.uploads : engine.downloads;
        expect(transfers, hasLength(overwrite ? 3 : 1));
        if (!overwrite) {
          expect(transfers.single.$1, endsWith(names.last));
        }
        await tester.tap(findAppIconButton(command));
        await tester.pumpAndSettle();
        expect(find.text('覆盖「a.txt」？'), findsOneWidget);
        expect(
          tester.widget<shadcn.Checkbox>(find.byType(shadcn.Checkbox)).state,
          shadcn.CheckboxState.unchecked,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(transfers, hasLength(overwrite ? 3 : 1));
      });
    }
  }

  testWidgets('未勾选时逐项询问，取消会停止本批次的剩余文件', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/a.txt', 10)
      ..putFile('/local/b.txt', 20);
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.addAll([_file('a.txt', 1), _file('b.txt', 2)]);
    await selectFile(tester, 'local', 'a.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await selectFile(tester, 'local', 'b.txt');
    await selectFile(tester, 'local', 'upload.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(findAppIconButton('上传所选文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(find.text('覆盖「b.txt」？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(engine.uploads, isEmpty);
  });

  testWidgets('本地和远程文件按相同格式显示更新时间，未知时间显示横线', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..putFile('/local/a.txt', 10, modified: DateTime(2026, 10, 13, 7, 8, 9));
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/home/test']!.add(
      SftpDirEntry(
        name: 'dated.txt',
        isDir: false,
        size: 20,
        modified: DateTime(2026, 10, 12, 17, 18, 19),
      ),
    );
    await tester.tap(findAppIconButton('刷新').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: pane('local'), matching: find.text('更新时间')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pane('remote'), matching: find.text('更新时间')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pane('local'),
        matching: find.text('2026-10-13 07:08:09'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pane('remote'),
        matching: find.text('2026-10-12 17:18:19'),
      ),
      findsOneWidget,
    );
    final unknown = find.byKey(
      const ValueKey('sftp-remote-row-/home/test/readme.txt'),
    );
    expect(
      find.descendant(of: unknown, matching: find.text('—')),
      findsOneWidget,
    );
    expect(
      formatFileModified(DateTime(2026, 10, 13, 7, 8, 9).toUtc()),
      '2026-10-13 07:08:09',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有已完成任务时清理按钮仍有手形指针和悬停变色', (tester) async {
    final highlightStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy = highlightStrategy,
    );
    await pumpPanel(tester);
    final clear = findAppIconButton('清除已完成');
    final icon = find.descendant(
      of: clear,
      matching: find.byIcon(shadcn.LucideIcons.listX),
    );
    final idleColor = IconTheme.of(tester.element(icon)).color;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(clear));
    await tester.pumpAndSettle();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    expect(IconTheme.of(tester.element(icon)).color, isNot(idleColor));
    expect(find.byType(shadcn.Tooltip), findsNothing);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    final controller = Get.find<TransferController>();
    expect(controller.tasks, isEmpty);
    final running = TransferTask(
      id: 'running',
      sessionId: 's1',
      kind: TransferKind.upload,
      fileName: 'running.txt',
      remotePath: '/running.txt',
      localPath: '/local/running.txt',
    );
    controller.tasks.add(running);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(controller.tasks, [running]);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('传输进度区高度固定，可折叠展开且清理仅影响本标签', (tester) async {
    await pumpPanel(tester);
    final progress = find.byKey(const ValueKey('sftp-transfer-progress'));
    for (final label in ['展开传输进度', '清除已完成']) {
      final button = tester.widget<shadcn.IconButton>(
        find.descendant(
          of: findAppIconButton(label),
          matching: find.byType(shadcn.IconButton),
        ),
      );
      expect(button.variance, shadcn.ButtonVariance.text);
    }
    expect(tester.getSize(progress).height, 36);
    expect(find.byKey(const ValueKey('sftp-transfer-list')), findsNothing);
    final controller = Get.find<TransferController>();
    final foreign = TransferTask(
      id: 'other',
      sessionId: 's2',
      kind: TransferKind.upload,
      fileName: 'other.txt',
      remotePath: '/other.txt',
      localPath: '/local/other.txt',
    );
    foreign.status.value = TransferStatus.done;
    controller.tasks.add(foreign);
    for (var index = 0; index < 20; index++) {
      final task = TransferTask(
        id: 'test-$index',
        sessionId: 's1',
        kind: TransferKind.upload,
        fileName: 'test-$index.txt',
        remotePath: '/test-$index.txt',
        localPath: '/local/test-$index.txt',
      );
      task.status.value = TransferStatus.done;
      controller.tasks.add(task);
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(progress).height, 36);
    expect(find.text('传输进度 · 20 项 · 0 项进行中'), findsOneWidget);
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    expect(tester.getSize(progress).height, 144);
    await tester.tap(findAppIconButton('折叠传输进度'));
    await tester.pumpAndSettle();
    expect(tester.getSize(progress).height, 36);
    expect(find.byKey(const ValueKey('sftp-transfer-list')), findsNothing);
    await tester.tap(findAppIconButton('展开传输进度'));
    await tester.pumpAndSettle();
    expect(tester.getSize(progress).height, 144);
    final clear = findAppIconButton('清除已完成');
    expect(find.text('清除已完成'), findsNothing);
    expect(
      find.descendant(
        of: clear,
        matching: find.byIcon(shadcn.LucideIcons.listX),
      ),
      findsOneWidget,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(clear));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('清除已完成'), findsNothing);
    expect(find.byType(shadcn.Tooltip), findsNothing);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(controller.tasks, [foreign]);
    expect(tester.getSize(progress).height, 144);
    expect(find.text('暂无传输任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('传输记录从顶部排列，每条记录内文件名和进度条垂直居中对齐', (tester) async {
    await pumpPanel(tester);
    final controller = Get.find<TransferController>();
    for (var count = 1; count <= 2; count++) {
      final task = TransferTask(
        id: 'center-$count',
        sessionId: 's1',
        kind: TransferKind.upload,
        fileName: 'center-$count.txt',
        remotePath: '/center-$count.txt',
        localPath: '/local/center-$count.txt',
      );
      task.status.value = TransferStatus.done;
      controller.tasks.add(task);
      if (count == 1) await tester.tap(findAppIconButton('展开传输进度'));
      await tester.pumpAndSettle();
      final list = tester.getRect(
        find.byKey(const ValueKey('sftp-transfer-list')),
      );
      final first = tester.getRect(
        find.byKey(const ValueKey('sftp-transfer-row-center-1')),
      );
      final last = tester.getRect(
        find.byKey(ValueKey('sftp-transfer-row-center-$count')),
      );
      expect(first.top, closeTo(list.top, 0.5));
      expect(
        tester
            .getCenter(find.byKey(ValueKey('sftp-transfer-name-${task.id}')))
            .dy,
        closeTo(last.center.dy, 0.5),
      );
      expect(
        tester
            .getCenter(
              find.byKey(ValueKey('sftp-transfer-progress-${task.id}')),
            )
            .dy,
        closeTo(last.center.dy, 0.5),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地目录可进入与返回，不改变远程目录', (tester) async {
    await pumpPanel(tester);
    await tester.tap(fileIn('local', 'downloads'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(fileIn('local', 'downloads'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sftp-path-/local/downloads')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    await tester.tap(pathSegment('local', '/local'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
  });

  testWidgets('受限目录直接请求系统授权，不出现 Flutter 授权弹框', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final selections = <(String?, String?)>[];
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections.add((initialDirectory, confirmButtonText));
        files.deniedDirectories.remove(initialDirectory);
        return initialDirectory;
      },
    );
    await openLocalDownloads(tester);
    expect(find.byType(AppDialog), findsNothing);
    expect(selections, [('/local/downloads', '授权访问')]);
    expect(
      find.byKey(const ValueKey('sftp-path-/local/downloads')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    expect(localController(tester).permissionDeniedPath.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消系统授权后保留原目录，可通过授权按钮重试', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    var selections = 0;
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections++;
        return null;
      },
    );
    await openLocalDownloads(tester);
    expect(selections, 1);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(fileIn('local', 'upload.txt'), findsOneWidget);
    expect(find.text('需要授权才能访问此文件夹'), findsOneWidget);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '授权访问'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(selections, 2);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(fileIn('local', 'downloads'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择窗口返回后仍无权限时保留提示，不反复弹窗', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    var selections = 0;
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections++;
        return initialDirectory;
      },
    );
    await openLocalDownloads(tester);
    expect(selections, 1);
    expect(find.text('授权访问文件夹'), findsNothing);
    expect(find.text('需要授权才能访问此文件夹'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
  });

  testWidgets('普通目录读取失败不提示授权', (tester) async {
    final files = InMemoryLocalFileRepository()..fs.remove('/local/downloads');
    var selections = 0;
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections++;
        return initialDirectory;
      },
    );
    await openLocalDownloads(tester);
    expect(find.text('无法读取本地目录，请重试'), findsOneWidget);
    expect(find.text('授权访问文件夹'), findsNothing);
    expect(find.text('授权访问'), findsNothing);
    expect(selections, 0);
  });

  testWidgets('首次打开用户目录受限时自动请求系统授权并加载', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local');
    final selections = <String?>[];
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections.add(initialDirectory);
        files.deniedDirectories.remove(initialDirectory);
        return initialDirectory;
      },
    );
    expect(selections, ['/local']);
    expect(find.byType(AppDialog), findsNothing);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(fileIn('local', 'upload.txt'), findsOneWidget);
  });

  testWidgets('系统选择窗口出错时提示重试并保留原目录', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async =>
          throw PlatformException(code: 'picker_failed'),
    );
    await openLocalDownloads(tester);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(find.text('无法打开目录选择窗口，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('初始授权取消后展示用户目录路径，并保留重试入口', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local');
    var selections = 0;
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections++;
        return null;
      },
    );
    expect(selections, 1);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(find.widgetWithText(shadcn.OutlineButton, '授权访问'), findsOneWidget);
  });

  testWidgets('迟到的授权选择不能覆盖后续导航', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final selection = Completer<String?>();
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) =>
          selection.future,
    );
    await openLocalDownloads(tester);
    await localController(tester).navigate('/local');
    files.deniedDirectories.clear();
    selection.complete('/local/downloads');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(fileIn('local', 'upload.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭面板后忽略系统选择窗口的授权结果', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final selection = Completer<String?>();
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) =>
          selection.future,
    );
    await openLocalDownloads(tester);
    final local = localController(tester);
    await tester.pumpWidget(
      ShadcnTestApp(home: const shadcn.Scaffold(child: SizedBox.shrink())),
    );
    files.deniedDirectories.clear();
    selection.complete('/local/downloads');
    await tester.pumpAndSettle();
    expect(local.isClosed, isTrue);
    expect(local.cwd.value, '/local');
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话替换后忽略旧面板的授权选择', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final selection = Completer<String?>();
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) =>
          selection.future,
    );
    await openLocalDownloads(tester);
    final oldLocal = localController(tester);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: SftpPanel(
            localFiles: InMemoryLocalFileRepository(),
            session: Session(
              id: 's2',
              host: host,
              phase: SessionPhase.ready,
              engineSession: FakeSftpSession(),
            ),
          ),
        ),
      ),
    );
    files.deniedDirectories.clear();
    selection.complete('/local/downloads');
    await tester.pumpAndSettle();
    expect(oldLocal.isClosed, isTrue);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(fileIn('local', 'upload.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载到受限目录行时先授权，再使用原落点传输', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final engine = await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        files.deniedDirectories.remove(initialDirectory);
        return initialDirectory;
      },
    );
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(find.byType(AppDialog), findsNothing);
    expect(engine.downloads, [
      ('/home/test/readme.txt', '/local/downloads/readme.txt'),
    ]);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
  });

  testWidgets('取消下载目录授权不传输，重新拖拽可授权后下载', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    var selections = 0;
    final engine = await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        if (++selections == 1) return null;
        files.deniedDirectories.remove(initialDirectory);
        return initialDirectory;
      },
    );
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(engine.downloads, isEmpty);
    expect(Get.find<TransferController>().tasks, isEmpty);
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(engine.downloads, [
      ('/home/test/readme.txt', '/local/downloads/readme.txt'),
    ]);
  });

  testWidgets('授权时选了其他目录，不改变下载落点或开始传输', (tester) async {
    final files = InMemoryLocalFileRepository()
      ..deniedDirectories.add('/local/downloads');
    final engine = await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async =>
          '/local',
    );
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(engine.downloads, isEmpty);
    expect(Get.find<TransferController>().tasks, isEmpty);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(find.text('需要授权才能访问此文件夹'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('本地文件拖到远程空白处上传，完成后刷新远程列表', (tester) async {
    final engine = await pumpPanel(tester);
    await dragFile(
      tester,
      fileIn('local', 'upload.txt'),
      tester.getCenter(pane('remote')),
    );
    expect(engine.uploads, [('/local/upload.txt', '/home/test/upload.txt')]);
    expect(fileIn('remote', 'upload.txt'), findsOneWidget);
    expect(
      Get.find<TransferController>().tasks.single.status.value,
      TransferStatus.done,
    );
  });

  testWidgets('远程文件拖到本地空白处下载，完成后刷新本地列表', (tester) async {
    final engine = await pumpPanel(tester);
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(pane('local')),
    );
    expect(engine.downloads, [('/home/test/readme.txt', '/local/readme.txt')]);
    expect(fileIn('local', 'readme.txt'), findsOneWidget);
  });

  testWidgets('拖到另一侧的文件夹行，传入该文件夹且保留当前目录', (tester) async {
    final engine = await pumpPanel(tester);
    await dragFile(
      tester,
      fileIn('local', 'upload.txt'),
      tester.getCenter(fileIn('remote', 'logs')),
    );
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(fileIn('local', 'downloads')),
    );
    expect(engine.uploads, [
      ('/local/upload.txt', '/home/test/logs/upload.txt'),
    ]);
    expect(engine.downloads, [
      ('/home/test/readme.txt', '/local/downloads/readme.txt'),
    ]);
    expect(find.byKey(const ValueKey('sftp-path-/local')), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
  });

  testWidgets('同侧拖放不发起传输', (tester) async {
    final engine = await pumpPanel(tester);
    await dragFile(
      tester,
      fileIn('local', 'upload.txt'),
      tester.getCenter(pane('local')),
    );
    expect(engine.uploads, isEmpty);
    expect(Get.find<TransferController>().tasks, isEmpty);
  });

  testWidgets('同名文件先确认覆盖，取消不下载，确认后才开始', (tester) async {
    final engine = await pumpPanel(tester);
    engine.localFiles!.putFile('/local/readme.txt', 50);
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(pane('local')),
    );
    expect(find.text('覆盖「readme.txt」？'), findsOneWidget);
    expect(engine.downloads, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(Get.find<TransferController>().tasks, isEmpty);
    await dragFile(
      tester,
      fileIn('remote', 'readme.txt'),
      tester.getCenter(pane('local')),
    );
    await tester.tap(find.text('覆盖'));
    await tester.pumpAndSettle();
    expect(engine.downloads, [('/home/test/readme.txt', '/local/readme.txt')]);
  });

  testWidgets('初始定位家目录并列出内容（目录在前）', (tester) async {
    await pumpPanel(tester);

    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    expect(find.text('logs'), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
    expect(find.text('42 B'), findsOneWidget);
  });

  testWidgets('双击目录进入，点击 Breadcrumb 返回祖先目录', (tester) async {
    await pumpPanel(tester);

    await tester.tap(fileIn('remote', 'logs'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(fileIn('remote', 'logs'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('sftp-path-/home/test/logs')),
      findsOneWidget,
    );
    expect(find.text('app.log'), findsOneWidget);

    await tester.tap(pathSegment('remote', '/home/test'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
  });

  testWidgets('两侧 Breadcrumb 可跳过多层到根目录，互不影响', (tester) async {
    final files = InMemoryLocalFileRepository()..fs['/'] = [];
    final engine = await pumpPanel(tester, files: files);
    engine.fs['/'] = [];
    expect(find.byType(shadcn.Breadcrumb), findsNWidgets(2));
    expect(findAppIconButton('上级目录'), findsNothing);
    await openLocalDownloads(tester);
    await tester.tap(pathSegment('local', '/'));
    await tester.pumpAndSettle();
    expect(localController(tester).cwd.value, '/');
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    await tester.tap(pathSegment('remote', '/'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: pane('remote'),
        matching: find.byKey(const ValueKey('sftp-path-/')),
      ),
      findsOneWidget,
    );
    expect(localController(tester).cwd.value, '/');
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地 Breadcrumb 跳转受限祖先目录仍直接请求系统授权', (tester) async {
    final files = InMemoryLocalFileRepository()..deniedDirectories.add('/');
    final selections = <String?>[];
    await pumpPanel(
      tester,
      files: files,
      directoryPicker: ({initialDirectory, confirmButtonText}) async {
        selections.add(initialDirectory);
        expect(confirmButtonText, '授权访问');
        files.deniedDirectories.remove('/');
        files.fs['/'] = [];
        return '/';
      },
    );
    await tester.tap(pathSegment('local', '/'));
    await tester.pumpAndSettle();
    expect(selections, ['/']);
    expect(localController(tester).cwd.value, '/');
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('通过工具栏新建目录并出现在列表', (tester) async {
    final engine = await pumpPanel(tester);

    await tester.tap(findAppIconButton('新建目录'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<AppDialog>(find.byType(AppDialog));
    expect(dialog.maxWidth, AppTheme.folderDialogMaxWidth);
    final card = find.ancestor(
      of: find.widgetWithText(AppTextFormField, '名称'),
      matching: find.byType(shadcn.Card),
    );
    expect(tester.getSize(card).width, lessThanOrEqualTo(380));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('必填'), findsOneWidget);
    expect(engine.fs.containsKey('/home/test/deploy'), isFalse);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      'deploy',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(engine.fs.containsKey('/home/test/deploy'), isTrue);
    expect(find.text('deploy'), findsOneWidget);
  });

  testWidgets('删除文件需确认并刷新列表', (tester) async {
    final engine = await pumpPanel(tester);

    // 打开 readme.txt 行的菜单选删除。
    await tester.tap(
      fileIn('remote', 'readme.txt'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '删除'));
    await tester.pumpAndSettle();

    expect(engine.removed, ['/home/test/readme.txt']);
    expect(find.text('readme.txt'), findsNothing);
  });

  testWidgets('取消删除保留文件和当前目录', (tester) async {
    final engine = await pumpPanel(tester);
    await tester.tap(
      fileIn('remote', 'readme.txt'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(engine.removed, isEmpty);
    expect(find.text('readme.txt'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-path-/home/test')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板移除释放浏览控制器但保持 SSH 会话', (tester) async {
    final engine = await pumpPanel(tester);
    final panel = tester.state(find.byType(SftpPanel));
    final tag = 'sftp-s1-${identityHashCode(panel)}';
    final controller = Get.find<SftpController>(tag: tag);
    final localController = Get.find<LocalFileController>(tag: tag);
    await tester.pumpWidget(
      ShadcnTestApp(home: const shadcn.Scaffold(child: SizedBox.shrink())),
    );
    await tester.pumpAndSettle();
    expect(Get.isRegistered<SftpController>(tag: tag), isFalse);
    expect(controller.isClosed, isTrue);
    expect(localController.isClosed, isTrue);
    expect(engine.closes, 0);
  });

  testWidgets('会话替换重新绑定浏览状态，不沿用旧连接', (tester) async {
    final firstEngine = await pumpPanel(tester);
    final replacement = FakeSftpSession();
    replacement.fs['/home/test'] = [_file('replacement.txt', 10)];
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: SftpPanel(
            localFiles: InMemoryLocalFileRepository(),
            session: Session(
              id: 's2',
              host: host,
              phase: SessionPhase.ready,
              engineSession: replacement,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('replacement.txt'), findsOneWidget);
    expect(find.text('readme.txt'), findsNothing);
    expect(firstEngine.closes, 0);
    expect(tester.takeException(), isNull);
  });
}
