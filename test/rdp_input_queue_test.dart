import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/presentation/rdp/rdp_input_queue.dart';

void main() {
  test('慢输入下合并旧鼠标移动，保持按键和按钮边沿的顺序', () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final errors = <Object>[];
    final queue = RdpInputQueue(onError: errors.add);
    queue.add(() async {
      sent.add('in-flight');
      await gate.future;
    });
    for (var i = 0; i < 1000; i++) {
      queue.add(() async => sent.add('move-$i'), movement: true);
    }
    queue.add(() async => sent.add('key-down'));
    queue.add(() async => sent.add('key-up'));
    queue.add(() async => sent.add('button-down'));
    for (var i = 0; i < 1000; i++) {
      queue.add(() async => sent.add('drag-$i'), movement: true);
    }
    queue.add(() async => sent.add('button-up'));
    expect(sent, ['in-flight']);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(sent, [
      'in-flight',
      'move-999',
      'key-down',
      'key-up',
      'button-down',
      'drag-999',
      'button-up',
    ]);
    expect(errors, isEmpty);
  });

  test('输入失败只报告一次，停止后续提交', () async {
    final gate = Completer<void>();
    final errors = <Object>[];
    final sent = <String>[];
    final queue = RdpInputQueue(onError: errors.add);
    queue.add(() async {
      await gate.future;
      throw StateError('closed');
    });
    queue.add(() async => sent.add('queued'));
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    queue.add(() async => sent.add('late'));
    expect(errors, hasLength(1));
    expect(sent, isEmpty);
  });
}
