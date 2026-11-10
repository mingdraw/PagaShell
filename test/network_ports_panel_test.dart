import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/ssh/network_ports.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/terminal/network_ports_panel.dart';

import 'support/network_ports_fixture.dart';
import 'support/process_fixture.dart';
import 'support/shadcn_test_app.dart';

class _Source implements NetworkPortsSource, ProcessManagerSource {
  NetworkPortsSnapshot ports = networkPortsFixture();
  ProcessSnapshot processes = processSnapshot(
    processes: [
      remoteProcess(pid: 7, name: '/usr/sbin/sshd'),
      remoteProcess(pid: 80, name: 'dns server'),
      remoteProcess(pid: 42, name: '/usr/bin/Web API'),
      remoteProcess(pid: 43, name: '/usr/bin/Other API'),
    ],
  );
  final terminated = <RemoteProcess>[];
  int processReads = 0;
  Object? failure;
  final failures = <int, Object>{};
  Completer<void>? gate;

  @override
  Future<NetworkPortsSnapshot> readNetworkPorts() async => ports;
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
    ports = NetworkPortsSnapshot(
      ports: [
        for (final port in ports.ports)
          if (port.processes.any((p) => p.pid != process.pid))
            ListeningNetworkPort(
              protocol: port.protocol,
              port: port.port,
              addresses: port.addresses,
              processes: port.processes
                  .where((p) => p.pid != process.pid)
                  .toList(),
            ),
      ],
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Source source, {
  Locale locale = const Locale('zh', 'CN'),
}) async {
  await tester.pumpWidget(
    ShadcnTestApp(
      locale: locale,
      home: Center(
        child: SizedBox(
          width: 260,
          height: 550,
          child: NetworkPortsPanel(source: source, active: true),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _stop(ListeningNetworkPort port) =>
    find.byKey(ValueKey('network-port-stop-${port.identity}'));
Finder get _confirm => find.byKey(const ValueKey('process-confirm-terminate'));
TextEditingController _input(WidgetTester tester) => tester
    .widget<AppTextFormField>(
      find.byKey(const ValueKey('process-terminate-name')),
    )
    .controller;

void main() {
  tearDown(Get.reset);

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('端口停止需输入完全一致进程名，取消不结束，成功传递身份并刷新 $locale', (tester) async {
      final source = _Source();
      final port = source.ports.ports.last;
      await _mount(tester, source, locale: locale);
      expect(source.processReads, 0);
      await tester.tap(_stop(port));
      await tester.pumpAndSettle();
      expect(find.text('高危操作：结束进程'.tr), findsOneWidget);
      expect(source.processReads, 1);
      expect(source.terminated, isEmpty);
      await tester.tap(find.text('取消'.tr));
      await tester.pumpAndSettle();
      expect(source.terminated, isEmpty);
      await tester.tap(_stop(port));
      await tester.pumpAndSettle();
      await tester.tap(_confirm);
      expect(source.terminated, isEmpty);
      _input(tester).text = 'web api';
      await tester.pump();
      await tester.tap(_confirm);
      expect(source.terminated, isEmpty);
      _input(tester).text = 'Web API';
      await tester.pump();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(source.terminated.single.pid, 42);
      expect(
        source.terminated.single.startedAt,
        source.processes.processes[2].startedAt,
      );
      expect(find.text('已向全部关联进程发送结束请求'.tr), findsOneWidget);
      expect(find.text('8080'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('共享端口直接确认全部进程，输入各名称后全部尝试，部分失败列出 PID 原因', (tester) async {
    final source = _Source()..gate = Completer<void>();
    source.failures[42] = const SshEngineException('无法结束进程，进程可能已退出或权限不足');
    final port = ListeningNetworkPort(
      protocol: NetworkPortProtocol.tcp,
      port: 8080,
      addresses: const [NetworkPortAddress(address: '127.0.0.1', ipv6: false)],
      processes: const [
        NetworkPortProcess(pid: 42, name: 'Web API'),
        NetworkPortProcess(pid: 43, name: 'Other API'),
      ],
    );
    source.ports = NetworkPortsSnapshot(ports: [port]);
    await _mount(tester, source);
    await tester.tap(_stop(port));
    await tester.pumpAndSettle();
    expect(find.text('高危操作：结束全部进程'), findsOneWidget);
    expect(find.text('Web API · PID 42'), findsOneWidget);
    expect(find.text('Other API · PID 43'), findsOneWidget);
    final confirmAll = find.byKey(
      const ValueKey('network-port-confirm-terminate-all'),
    );
    final first = tester
        .widget<AppTextFormField>(
          find.byKey(const ValueKey('network-port-terminate-name-42')),
        )
        .controller;
    final second = tester
        .widget<AppTextFormField>(
          find.byKey(const ValueKey('network-port-terminate-name-43')),
        )
        .controller;
    first.text = 'Web API';
    await tester.pump();
    await tester.tap(confirmAll);
    expect(source.terminated, isEmpty);
    second.text = 'Other API';
    await tester.pump();
    await tester.tap(confirmAll);
    await tester.pumpAndSettle();
    expect(source.terminated.single.pid, 42);
    expect(source.terminated, hasLength(1));
    expect(tester.widget<AppIconButton>(_stop(port)).onPressed, isNull);
    source.gate!.complete();
    await tester.pumpAndSettle();
    expect(source.terminated.map((p) => p.pid), [42, 43]);
    expect(find.textContaining('PID 42 · 无法结束进程'), findsOneWidget);
    expect(find.text('8080'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(source.terminated, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('同名多 PID 和独立卡片共用一个确认名称，取消不执行，确认全部结束 $locale', (tester) async {
      final source = _Source();
      source.processes = processSnapshot(
        processes: [
          remoteProcess(pid: 42, name: '/usr/bin/api'),
          remoteProcess(pid: 43, name: '/usr/bin/api'),
        ],
      );
      ListeningNetworkPort port(int pid, bool ipv6) => ListeningNetworkPort(
        protocol: NetworkPortProtocol.tcp,
        port: 8080,
        addresses: [
          NetworkPortAddress(address: ipv6 ? '::' : '0.0.0.0', ipv6: ipv6),
        ],
        processes: [NetworkPortProcess(pid: pid, name: 'api')],
      );
      final first = port(42, false);
      source.ports = NetworkPortsSnapshot(ports: [first, port(43, true)]);
      await _mount(tester, source, locale: locale);
      await tester.tap(_stop(first));
      await tester.pumpAndSettle();
      expect(find.text('api · PID 42, 43'), findsOneWidget);
      expect(find.byType(AppTextFormField), findsNWidgets(2));
      await tester.tap(find.text('取消'.tr));
      await tester.pumpAndSettle();
      expect(source.terminated, isEmpty);
      await tester.tap(_stop(first));
      await tester.pumpAndSettle();
      tester
              .widget<AppTextFormField>(
                find.byKey(const ValueKey('network-port-terminate-name-42')),
              )
              .controller
              .text =
          'api';
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('network-port-confirm-terminate-all')),
      );
      await tester.pumpAndSettle();
      expect(source.terminated.map((p) => p.pid), [42, 43]);
      expect(find.text('暂无监听端口'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('无法识别进程或受保护 PID 的端口禁用停止，归属已变化不弹确认', (tester) async {
    final source = _Source();
    final unknown = ListeningNetworkPort(
      protocol: NetworkPortProtocol.udp,
      port: 53,
      addresses: const [NetworkPortAddress(address: '0.0.0.0', ipv6: false)],
      processes: const [],
    );
    final init = ListeningNetworkPort(
      protocol: NetworkPortProtocol.tcp,
      port: 80,
      addresses: unknown.addresses,
      processes: const [NetworkPortProcess(pid: 1, name: 'init')],
    );
    final target = source.ports.ports.last;
    source.ports = NetworkPortsSnapshot(ports: [unknown, init, target]);
    await _mount(tester, source);
    for (final port in [unknown, init]) {
      expect(tester.widget<AppIconButton>(_stop(port)).onPressed, isNull);
    }
    source.ports = const NetworkPortsSnapshot(ports: []);
    await tester.tap(_stop(target));
    await tester.pumpAndSettle();
    expect(find.text('端口对应的进程已变化，请刷新后重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('network-port-terminate-confirmation')),
      findsNothing,
    );
    expect(source.terminated, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('批量失败较多时结果可滚动且不挤出端口列表', (tester) async {
    final source = _Source();
    final ids = List.generate(20, (i) => i + 100);
    final port = ListeningNetworkPort(
      protocol: NetworkPortProtocol.tcp,
      port: 8080,
      addresses: const [NetworkPortAddress(address: '0.0.0.0', ipv6: false)],
      processes: [
        for (final pid in ids) NetworkPortProcess(pid: pid, name: 'worker'),
      ],
    );
    source.ports = NetworkPortsSnapshot(ports: [port]);
    source.processes = processSnapshot(
      processes: [
        for (final pid in ids) remoteProcess(pid: pid, name: 'worker'),
      ],
    );
    for (final pid in ids) {
      source.failures[pid] = const SshEngineException('无法结束进程，进程可能已退出或权限不足');
    }
    await _mount(tester, source);
    await tester.tap(_stop(port));
    await tester.pumpAndSettle();
    tester
            .widget<AppTextFormField>(
              find.byKey(const ValueKey('network-port-terminate-name-100')),
            )
            .controller
            .text =
        'worker';
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('network-port-confirm-terminate-all')),
    );
    await tester.pumpAndSettle();
    expect(source.terminated, hasLength(20));
    expect(find.byKey(const ValueKey('network-ports-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
