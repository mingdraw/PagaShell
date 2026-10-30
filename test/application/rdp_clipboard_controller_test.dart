import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/rdp/rdp_clipboard_controller.dart';
import 'package:pagashell/domain/rdp/rdp_clipboard.dart';

import '../support/fake_rdp_clipboard.dart';

void main() {
  late FakeClipboardSession session;
  late FakeLocalClipboard local;
  late RdpClipboardController controller;
  late List<String> errors;
  void initialize() {
    session = FakeClipboardSession();
    local = FakeLocalClipboard();
    errors = [];
    controller = RdpClipboardController(
      session: session,
      local: local,
      onError: errors.add,
    );
  }

  tearDown(() async {
    controller.dispose();
    await session.close();
  });

  testWidgets('活动会话同步初始和后续文字/多文件，未变化时不重复发布', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    expect(session.clipboardChanges.single.text, 'initial');
    await tester.pump(const Duration(seconds: 1));
    expect(session.clipboardChanges, hasLength(1));
    local.copy(const ClipboardContent(text: '中文😀\n第二行'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(session.clipboardChanges.last.text, '中文😀\n第二行');
    local.copy(const ClipboardContent(files: ['/tmp/中文.txt', '/tmp/folder']));
    await tester.pump(const Duration(milliseconds: 500));
    expect(session.clipboardChanges.last.files, ['/tmp/中文.txt', '/tmp/folder']);
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('远端文字和文件写回系统剪贴板且不回传，重复原生通知不回环', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: '来自 Windows 😀'),
      ),
    );
    await tester.pump();
    expect(local.current.content.text, '来自 Windows 😀');
    await tester.pump(const Duration(milliseconds: 500));
    expect(session.clipboardChanges, hasLength(1));
    local.copy(local.current.content);
    await tester.pump(const Duration(milliseconds: 500));
    expect(session.clipboardChanges, hasLength(1));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.files,
        content: ClipboardContent(
          files: ['/tmp/cache/文档.txt', '/tmp/cache/文件夹'],
        ),
      ),
    );
    await tester.pump();
    expect(local.current.content.files, [
      '/tmp/cache/文档.txt',
      '/tmp/cache/文件夹',
    ]);
    await tester.pump(const Duration(seconds: 1));
    expect(session.clipboardChanges, hasLength(1));
    expect(local.writes, hasLength(2));
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('后台页签停止读写，恢复时只发布当前本机内容', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    controller.setActive(false);
    await tester.pump();
    final reads = local.reads;
    local.copy(const ClipboardContent(text: 'new local'));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'inactive remote'),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(local.reads, reads);
    expect(local.writes, isEmpty);
    controller.setActive(true);
    await tester.pump();
    expect(session.clipboardChanges.last.text, 'new local');
    expect(session.clipboardActive, [true, false, true]);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('下载期间新的本机复制优先，旧文件结果不会覆盖本机', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.receiving,
        transferred: 10,
        total: 20,
      ),
    );
    expect(controller.progress.value!.total, 20);
    local.copy(const ClipboardContent(text: 'new local'));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.files,
        content: ClipboardContent(files: ['/tmp/old']),
      ),
    );
    await tester.pump();
    expect(local.writes, isEmpty);
    expect(local.current.content.text, 'new local');
    expect(session.clipboardChanges.last.text, 'new local');
    controller.dispose();
    await tester.pump();
  });
  testWidgets('写入前系统再次变化时原生版本检查避免覆盖', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    local.beforeWrite = () =>
        local.copy(const ClipboardContent(text: 'raced local'));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'old remote'),
      ),
    );
    await tester.pump();
    expect(local.writes, isEmpty);
    expect(local.current.content.text, 'raced local');
    expect(session.clipboardChanges.last.text, 'raced local');
    controller.dispose();
    await tester.pump();
  });
  testWidgets('同步失败不关闭桌面，重新复制相同文字可重试', (tester) async {
    initialize();
    session.onClipboardUpdate = (_) => Future<void>.error(StateError('test'));
    controller.setActive(true);
    await tester.pump();
    expect(errors, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    expect(errors, hasLength(1));
    expect(await controller.syncBeforePaste(), isFalse);
    session.onClipboardUpdate = null;
    local.copy(local.current.content);
    await tester.pump(const Duration(milliseconds: 500));
    expect(session.clipboardChanges, hasLength(3));
    expect(await controller.syncBeforePaste(), isTrue);
    expect(session.closes, 0);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('关闭阻止未完成激活重新启用或写入', (tester) async {
    initialize();
    final enabled = Completer<void>();
    session.onClipboardActive = (active) =>
        active ? enabled.future : Future<void>.value();
    controller.setActive(true);
    await tester.pump();
    controller.dispose();
    enabled.complete();
    await tester.pump();
    expect(session.clipboardActive, [true, false]);
    expect(session.clipboardChanges, isEmpty);
    expect(local.reads, 0);
  });
  testWidgets('发布失败后再次粘贴会重试原剪贴板，无需重新复制', (tester) async {
    initialize();
    session.onClipboardUpdate = (_) => Future<void>.error(StateError('test'));
    controller.setActive(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(session.clipboardChanges, hasLength(1));
    session.onClipboardUpdate = null;
    expect(await controller.syncBeforePaste(), isTrue);
    expect(session.clipboardChanges, hasLength(2));
    expect(session.closes, 0);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('激活期间的远端复制等待初始同步完成且不回环', (tester) async {
    initialize();
    final enabled = Completer<void>();
    session.onClipboardActive = (_) => enabled.future;
    controller.setActive(true);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'activation remote'),
      ),
    );
    expect(local.writes, isEmpty);
    enabled.complete();
    await tester.pump();
    expect(local.current.content.text, 'activation remote');
    expect(session.clipboardChanges.map((c) => c.text), ['initial']);
    await tester.pump(const Duration(seconds: 1));
    expect(session.clipboardChanges, hasLength(1));
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('粘贴等待旧轮询后再次读取并发布最新复制', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    final read = Completer<ClipboardSnapshot>();
    final old = local.current;
    local.onRead = () => read.future;
    await tester.pump(const Duration(milliseconds: 500));
    local.copy(const ClipboardContent(text: 'copied just before paste'));
    final paste = controller.syncBeforePaste();
    local.onRead = null;
    read.complete(old);
    await tester.pump();
    await paste;
    expect(session.clipboardChanges.last.text, 'copied just before paste');
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('取消文件传输清空进度并保持会话', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    session.clipboardOutput.add(
      const RdpClipboardEvent(kind: RdpClipboardEventKind.receiving, total: 50),
    );
    await controller.cancelTransfer();
    expect(controller.progress.value, isNull);
    expect(session.cancelledTransfers, 1);
    expect(session.closes, 0);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('切到本机应用不发布新的本机复制，也不被旧远端结果覆盖', (tester) async {
    initialize();
    controller.setActive(true);
    await tester.pump();
    controller.setForeground(false);
    final reads = local.reads;
    local.copy(const ClipboardContent(text: 'new local in another app'));
    await tester.pump(const Duration(seconds: 2));
    expect(local.reads, reads);
    expect(session.clipboardChanges, hasLength(1));
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'late remote'),
      ),
    );
    await tester.pump();
    expect(local.current.content.text, 'new local in another app');
    expect(local.writes, isEmpty);
    expect(session.clipboardChanges, hasLength(1));
    controller.setForeground(true);
    await tester.pump();
    expect(session.clipboardChanges.last.text, 'new local in another app');
    expect(session.clipboardActive, [true]);
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
  testWidgets('窗口尚未激活时可接收远端复制，恢复后不回传远端内容', (tester) async {
    initialize();
    controller.setForeground(false);
    controller.setActive(true);
    await tester.pump();
    expect(session.clipboardChanges, isEmpty);
    session.clipboardOutput.add(
      const RdpClipboardEvent(
        kind: RdpClipboardEventKind.text,
        content: ClipboardContent(text: 'copied before window activation'),
      ),
    );
    await tester.pump();
    expect(local.current.content.text, 'copied before window activation');
    controller.setForeground(true);
    await tester.pump();
    expect(session.clipboardChanges, isEmpty);
    expect(errors, isEmpty);
    controller.dispose();
    await tester.pump();
  });
}
