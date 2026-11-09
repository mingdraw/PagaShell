import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/process_manager_controller.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/process_fixture.dart';

class _Source implements ProcessManagerSource {
  final reads = <Completer<ProcessSnapshot>>[];
  final terminations = <RemoteProcess>[];
  Completer<void>? termination;
  Object? terminationFailure;
  final detailsRead = <RemoteProcess>[];
  Completer<ProcessDetails>? detailRequest;

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) async {
    detailsRead.add(process);
    if (detailRequest case final request?) return request.future;
    return processDetails(process: process);
  }

  @override
  Future<ProcessSnapshot> readProcesses() {
    final request = Completer<ProcessSnapshot>();
    reads.add(request);
    return request.future;
  }

  @override
  Future<void> terminateProcess(RemoteProcess process) async {
    terminations.add(process);
    if (terminationFailure case final failure?) throw failure;
    await termination?.future;
  }
}

void main() {
  testWidgets('详情按需读取，隐藏后忽略迟到响应，关闭后不能再查询', (tester) async {
    final source = _Source();
    final controller = ProcessManagerController(source: source);
    controller.setEnabled(true);
    source.reads.single.complete(processSnapshot());
    await tester.pump();
    expect(source.detailsRead, isEmpty);
    final process = controller.processes.first.process;
    expect((await controller.readDetails(process)).process, same(process));
    expect(source.detailsRead, [process]);
    source.detailRequest = Completer<ProcessDetails>();
    final pending = controller.readDetails(process);
    final rejected = expectLater(pending, throwsA(isA<SshEngineException>()));
    controller.setEnabled(false);
    source.detailRequest!.complete(processDetails(process: process));
    await rejected;
    expect(controller.processes, hasLength(3));
    controller.onClose();
    await expectLater(
      controller.readDetails(process),
      throwsA(isA<SshEngineException>()),
    );
    expect(source.detailsRead, hasLength(2));
  });

  testWidgets('默认内存降序，可切换 CPU，名称、PID、用户本地筛选', (tester) async {
    final source = _Source();
    final controller = ProcessManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    source.reads.single.complete(processSnapshot());
    await tester.pump();
    expect(controller.sort.value, ProcessSort.memory);
    expect(controller.visibleProcesses.map((p) => p.process.pid), [81, 42, 1]);
    controller.sort.value = ProcessSort.cpu;
    expect(controller.visibleProcesses.map((p) => p.process.pid), [42, 81, 1]);
    for (final term in ['MEMORY', '81', 'rocky']) {
      controller.query.value = term;
      expect(controller.visibleProcesses, isNotEmpty);
    }
    controller.query.value = 'root';
    expect(controller.visibleProcesses.single.process.pid, 1);
    controller.query.value = 'missing';
    expect(controller.visibleProcesses, isEmpty);
    expect(source.reads, hasLength(1));
    controller.setEnabled(false);
  });

  testWidgets('不并发采样，隐藏暂停，重新展开忽略迟到采样，关闭停止刷新', (tester) async {
    final source = _Source();
    final controller = ProcessManagerController(source: source);
    controller.setEnabled(true);
    await tester.pump(const Duration(seconds: 10));
    expect(source.reads, hasLength(1));
    controller.setEnabled(false);
    controller.setEnabled(true);
    source.reads.first.complete(processSnapshot());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(source.reads, hasLength(2));
    expect(controller.processes, isEmpty);
    source.reads.last.complete(processSnapshot(time: 1003));
    await tester.pump();
    expect(controller.processes.first.cpuPercent, 150);
    controller.setEnabled(false);
    await tester.pump(const Duration(seconds: 12));
    expect(source.reads, hasLength(2));
    controller.setEnabled(true);
    controller.onClose();
    source.reads.last.complete(processSnapshot(time: 1006));
    await tester.pump(const Duration(seconds: 12));
    expect(source.reads, hasLength(3));
    expect(controller.updatedAt.value, isNotNull);
  });

  testWidgets('结束操作不重复、不结束 PID 1，失败保留列表且不重试信号', (tester) async {
    final source = _Source();
    final controller = ProcessManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    source.reads.first.complete(processSnapshot());
    await tester.pump();
    source.termination = Completer<void>();
    final process = controller.processes.first.process;
    final pending = controller.terminate(process);
    expect(await controller.terminate(process), false);
    expect(await controller.terminate(remoteProcess(pid: 1)), false);
    expect(source.terminations, [process]);
    expect(controller.terminating, contains(process.identity));
    source.termination!.completeError(
      const SshEngineException('无法结束进程，进程可能已退出或权限不足'),
    );
    expect(await pending, false);
    expect(controller.processes, hasLength(3));
    expect(controller.actionError.value, contains('权限不足'));
    expect(controller.terminating, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    source.reads.last.completeError(const SshEngineException('进程操作超时'));
    await tester.pump();
    expect(controller.processes, hasLength(3));
    expect(source.terminations, hasLength(1));
    controller.setEnabled(false);
  });

  testWidgets('成功发送 TERM 后刷新，关闭的面板不能再发结束请求', (tester) async {
    final source = _Source();
    final controller = ProcessManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    source.reads.first.complete(processSnapshot());
    await tester.pump();
    final process = controller.processes.first.process;
    final pending = controller.terminate(process);
    await tester.pump();
    expect(source.reads, hasLength(2));
    source.reads.last.complete(processSnapshot(time: 1003, processes: []));
    await tester.pump();
    expect(await pending, true);
    expect(controller.notice.value, '已发送结束请求');
    expect(controller.processes, isEmpty);
    controller.setEnabled(false);
    expect(await controller.terminate(process), false);
    expect(source.terminations, hasLength(1));
  });
}
