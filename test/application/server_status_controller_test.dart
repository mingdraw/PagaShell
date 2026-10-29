import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/server_status_controller.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/server_status_fixture.dart';

class _Source implements ServerStatusSource {
  final List<Completer<ServerStatusSample>> requests = [];

  @override
  Future<ServerStatusSample> readServerStatus() {
    final request = Completer<ServerStatusSample>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  testWidgets('定时采样不重叠，收起暂停，重新展开忽略旧请求并重新建立基线', (tester) async {
    final source = _Source();
    final controller = ServerStatusController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    expect(source.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 10));
    await controller.refreshStatus();
    expect(source.requests, hasLength(1));
    source.requests[0].complete(statusSample());
    await tester.pump();
    expect(controller.status.value!.cpuFraction, isNull);
    await tester.pump(const Duration(seconds: 3));
    expect(source.requests, hasLength(2));
    controller.setEnabled(false);
    controller.setEnabled(true);
    expect(source.requests, hasLength(2));
    source.requests[1].complete(
      statusSample(uptime: 1003, cpu: 1300, idle: 900),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(source.requests, hasLength(3));
    expect(controller.status.value!.sample.uptimeSeconds, 1000);
    source.requests[2].complete(
      statusSample(uptime: 1006, cpu: 1600, idle: 1000),
    );
    await tester.pump();
    expect(controller.status.value!.cpuFraction, isNull);
    controller.setEnabled(false);
    await tester.pump(const Duration(seconds: 30));
    expect(source.requests, hasLength(3));
  });

  testWidgets('失败保留上次数据并可恢复，关闭后忽略迟到结果', (tester) async {
    final source = _Source();
    final controller = ServerStatusController(source: source);
    controller.setEnabled(true);
    source.requests[0].complete(statusSample());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    source.requests[1].completeError(const SshEngineException('服务状态采集超时'));
    await tester.pump();
    expect(controller.error.value, '服务状态采集超时');
    expect(controller.status.value!.sample.uptimeSeconds, 1000);
    await tester.pump(const Duration(seconds: 3));
    source.requests[2].complete(statusSample(uptime: 1006));
    await tester.pump();
    expect(controller.error.value, isNull);
    expect(controller.status.value!.cpuFraction, isNull);
    await tester.pump(const Duration(seconds: 3));
    controller.onClose();
    source.requests[3].complete(statusSample(uptime: 1009));
    await tester.pump(const Duration(seconds: 30));
    expect(controller.status.value!.sample.uptimeSeconds, 1006);
    expect(source.requests, hasLength(4));
  });
}
