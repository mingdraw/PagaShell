import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/network_ports_controller.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/network_ports_fixture.dart';
import '../support/process_fixture.dart';

class _Source implements NetworkPortsSource {
  final requests = <Completer<NetworkPortsSnapshot>>[];
  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() {
    final request = Completer<NetworkPortsSnapshot>();
    requests.add(request);
    return request.future;
  }
}

class _ActionSource implements NetworkPortsSource, ProcessManagerSource {
  NetworkPortsSnapshot ports = networkPortsFixture();
  ProcessSnapshot processes = processSnapshot(
    processes: [remoteProcess(pid: 42, name: '/usr/bin/Web API')],
  );
  final terminated = <RemoteProcess>[];
  int portReads = 0;
  int processReads = 0;
  Object? failure;
  final failures = <int, Object>{};
  Completer<void>? gate;
  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() async {
    portReads++;
    return ports;
  }

  @override
  Future<ProcessSnapshot> readProcesses() async {
    processReads++;
    return processes;
  }

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) async =>
      processDetails(process: process);
  @override
  Future<void> terminateProcess(RemoteProcess process) async {
    terminated.add(process);
    await gate?.future;
    if (failures[process.pid] case final error?) throw error;
    if (failure case final error?) throw error;
    ports = const NetworkPortsSnapshot(ports: []);
  }
}

void main() {
  testWidgets('结束前按需核对进程与端口，传递启动时间，禁止重复提交并刷新端口', (tester) async {
    final source = _ActionSource();
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    await tester.pump();
    expect(source.processReads, 0);
    final port = controller.ports.last;
    final target = await controller.prepareTermination(port);
    expect(target!.single, same(source.processes.processes.single));
    expect(source.processReads, 1);
    expect(source.terminated, isEmpty);
    source.gate = Completer<void>();
    final operation = controller.terminate(port, target);
    await tester.pump();
    expect(source.terminated.single.startedAt, target.single.startedAt);
    expect(await controller.terminate(port, target), false);
    expect(controller.terminating, contains(42));
    source.gate!.complete();
    expect(await operation, true);
    expect(controller.ports, isEmpty);
    expect(controller.notice.value, '已向全部关联进程发送结束请求');
    controller.onClose();
  });

  testWidgets('端口归属已变化、进程已退出或保护进程不能进入确认，错误不发送 TERM', (tester) async {
    final source = _ActionSource();
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    await tester.pump();
    final port = controller.ports.last;
    source.ports = const NetworkPortsSnapshot(ports: []);
    expect(await controller.prepareTermination(port), isNull);
    expect(controller.actionError.value, '端口对应的进程已变化，请刷新后重试');
    source.ports = networkPortsFixture();
    source.processes = processSnapshot(processes: []);
    expect(await controller.prepareTermination(port), isNull);
    expect(
      controller.canTerminateProcess(
        const NetworkPortProcess(pid: 1, name: 'init'),
      ),
      false,
    );
    expect(
      controller.canTerminateProcess(
        const NetworkPortProcess(pid: 42, name: ''),
      ),
      false,
    );
    expect(source.terminated, isEmpty);
    controller.onClose();
  });

  testWidgets('结束失败保留端口并展示固定原因，不自动重发结束请求', (tester) async {
    final source = _ActionSource()
      ..failure = const SshEngineException('无法结束进程，进程可能已退出或权限不足');
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    await tester.pump();
    final port = controller.ports.last;
    final processes = await controller.prepareTermination(port);
    expect(await controller.terminate(port, processes!), false);
    expect(controller.actionError.value, '未能结束端口关联的进程');
    expect(controller.actionFailures.single.message, '无法结束进程，进程可能已退出或权限不足');
    expect(controller.ports, hasLength(3));
    await tester.pump(const Duration(seconds: 10));
    expect(source.terminated, hasLength(1));
    controller.onClose();
  });
  testWidgets('批量合并同协议端口各卡片并去重，失败仍尝试后续进程且报告部分结果', (tester) async {
    final source = _ActionSource();
    ListeningNetworkPort port(
      int pid,
      bool ipv6, {
      NetworkPortProtocol protocol = NetworkPortProtocol.tcp,
    }) => ListeningNetworkPort(
      protocol: protocol,
      port: 8080,
      addresses: [
        NetworkPortAddress(address: ipv6 ? '::' : '0.0.0.0', ipv6: ipv6),
      ],
      processes: [NetworkPortProcess(pid: pid, name: 'api')],
    );
    final first = port(42, false);
    source.ports = NetworkPortsSnapshot(
      ports: [
        first,
        port(42, true),
        port(43, true),
        port(44, false, protocol: NetworkPortProtocol.udp),
      ],
    );
    source.processes = processSnapshot(
      processes: [
        remoteProcess(pid: 42, name: 'api'),
        remoteProcess(pid: 43, name: 'api'),
        remoteProcess(pid: 44, name: 'api'),
      ],
    );
    source.failures[42] = const SshEngineException('进程已变化，请刷新后重试');
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    await tester.pump();
    final targets = await controller.prepareTermination(first);
    expect(targets!.map((p) => p.pid), [42, 43]);
    expect(await controller.terminate(first, targets), false);
    expect(source.terminated.map((p) => p.pid), [42, 43]);
    expect(controller.actionError.value, '部分进程未能结束，请查看失败原因');
    expect(controller.actionFailures.single.pid, 42);
    expect(controller.notice.value, isNull);
    controller.onClose();
  });

  testWidgets('确认后新增进程使目标集合变化时不结束任何进程，未知或保护进程不被静默跳过', (tester) async {
    final source = _ActionSource();
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    await tester.pump();
    final first = controller.ports.last;
    final targets = await controller.prepareTermination(first);
    source.ports = NetworkPortsSnapshot(
      ports: [
        ListeningNetworkPort(
          protocol: first.protocol,
          port: first.port,
          addresses: first.addresses,
          processes: [
            ...first.processes,
            const NetworkPortProcess(pid: 43, name: 'other'),
          ],
        ),
      ],
    );
    expect(await controller.terminate(first, targets!), false);
    expect(source.terminated, isEmpty);
    await controller.refreshPorts();
    source.ports = NetworkPortsSnapshot(
      ports: [
        ListeningNetworkPort(
          protocol: first.protocol,
          port: first.port,
          addresses: first.addresses,
          processes: [
            ...first.processes,
            const NetworkPortProcess(pid: 1, name: 'init'),
          ],
        ),
      ],
    );
    await controller.refreshPorts();
    expect(controller.canTerminatePort(controller.ports.single), false);
    expect(
      await controller.prepareTermination(controller.ports.single),
      isNull,
    );
    expect(source.terminated, isEmpty);
    controller.onClose();
  });
  testWidgets('端口/进程名检索与协议过滤在本地完成，隐藏暂停且保留筛选，迟到快照不替换当前数据', (tester) async {
    final source = _Source();
    final controller = NetworkPortsController(source: source);
    controller.setEnabled(true);
    source.requests.single.complete(networkPortsFixture());
    await tester.pump();
    controller.query.value = 'WEB';
    expect(controller.visiblePorts.single.port, 8080);
    controller.query.value = '22';
    expect(controller.visiblePorts.single.port, 22);
    controller.query.value = '';
    controller.filter.value = NetworkPortsFilter.udp;
    expect(controller.visiblePorts.single.port, 53);
    expect(source.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 3));
    expect(source.requests, hasLength(2));
    controller.setEnabled(false);
    source.requests.last.complete(const NetworkPortsSnapshot(ports: []));
    await tester.pump(const Duration(seconds: 30));
    expect(controller.ports, hasLength(3));
    expect(source.requests, hasLength(2));
    controller.setEnabled(true);
    source.requests.last.complete(networkPortsFixture(limited: true));
    await tester.pump();
    expect(controller.limited.value, isTrue);
    expect(controller.filter.value, NetworkPortsFilter.udp);
    expect(controller.visiblePorts.single.port, 53);
    controller.onClose();
    await tester.pump(const Duration(seconds: 30));
    expect(source.requests, hasLength(3));
  });

  testWidgets('错误保留上次数据，超时释放加载状态，手动刷新可恢复且忽略迟到结果', (tester) async {
    final source = _Source();
    final controller = NetworkPortsController(
      source: source,
      timeout: const Duration(seconds: 1),
    );
    controller.setEnabled(true);
    source.requests.single.complete(networkPortsFixture());
    await tester.pump();
    final failed = controller.refreshPorts();
    source.requests.last.completeError(const SshEngineException('没有权限读取网络端口'));
    await failed;
    expect(controller.error.value, '没有权限读取网络端口');
    expect(controller.ports, hasLength(3));
    final pending = controller.refreshPorts();
    expect(source.requests, hasLength(3));
    await tester.pump(const Duration(seconds: 1));
    await pending;
    expect(controller.loading.value, isFalse);
    expect(controller.error.value, '网络端口查询超时，请重试');
    final recovery = controller.refreshPorts();
    source.requests.last.complete(networkPortsFixture());
    await recovery;
    expect(controller.error.value, isNull);
    source.requests[2].complete(const NetworkPortsSnapshot(ports: []));
    await tester.pump();
    expect(controller.ports, hasLength(3));
    controller.onClose();
  });
}
