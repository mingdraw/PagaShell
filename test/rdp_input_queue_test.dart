import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_input_queue.dart';

void main() {
  test('慢输入下合并旧鼠标移动，保持按键和按钮边沿的顺序', () async {
    final gate = Completer<void>();
    final sent = <Object>[];
    final errors = <Object>[];
    final queue = RdpInputQueue(
      onError: errors.add,
      sendBatch: (events) async => sent.add([
        for (final event in events)
          switch (event) {
            RdpKeyInput() => (event.scanCode, event.down),
            RdpPointerInput() => (event.x, event.flags),
          },
      ]),
    );
    queue.add(() async {
      sent.add('in-flight');
      await gate.future;
    });
    for (var i = 0; i < 1000; i++) {
      queue.addEvent(RdpPointerInput(i, 0, 0x0800));
    }
    queue.addEvent(const RdpKeyInput(0x1d, down: true));
    queue.add(() async => sent.add('clipboard barrier'));
    queue.addEvent(const RdpKeyInput(0x2f, down: true));
    queue.addEvent(const RdpKeyInput(0x2f, down: false));
    queue.addEvent(const RdpKeyInput(0x1d, down: false));
    queue.addEvent(const RdpPointerInput(0, 0, 0x9000));
    for (var i = 0; i < 1000; i++) {
      queue.addEvent(RdpPointerInput(i, 0, 0x0800));
    }
    queue.addEvent(const RdpPointerInput(0, 0, 0x1000));
    expect(sent, ['in-flight']);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(sent, [
      'in-flight',
      [(999, 0x0800), (0x1d, true)],
      'clipboard barrier',
      [
        (0x2f, true),
        (0x2f, false),
        (0x1d, false),
        (0, 0x9000),
        (999, 0x0800),
        (0, 0x1000),
      ],
    ]);
    expect(errors, isEmpty);
  });

  test('输入分批有上限，保留同一事件循环内的每个按键', () async {
    final batches = <List<int>>[];
    final queue = RdpInputQueue(
      onError: (error) => fail(error.toString()),
      sendBatch: (events) async => batches.add(
        events.cast<RdpKeyInput>().map((e) => e.scanCode).toList(),
      ),
    );
    for (var i = 0; i < 75; i++) {
      queue.addEvent(RdpKeyInput(i, down: i.isEven));
    }
    await Future<void>.delayed(Duration.zero);
    expect(batches.map((events) => events.length), [32, 32, 11]);
    expect(batches.expand((events) => events), List.generate(75, (i) => i));
  });

  test('输入失败只报告一次，停止后续提交', () async {
    final gate = Completer<void>();
    final errors = <Object>[];
    final sent = <String>[];
    final queue = RdpInputQueue(
      onError: errors.add,
      sendBatch: (_) async => sent.add('batch'),
    );
    queue.add(() async {
      await gate.future;
      throw StateError('closed');
    });
    queue.addEvent(const RdpKeyInput(0x1d, down: true));
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    queue.add(() async => sent.add('late'));
    expect(errors, hasLength(1));
    expect(sent, isEmpty);
  });
}
