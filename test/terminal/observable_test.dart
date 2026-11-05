import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/src/base/observable.dart';

class _Observable with Observable {}

void main() {
  test('通知期间监听器可移除自己，其他监听器继续收到通知', () {
    final observable = _Observable();
    final calls = <String>[];
    void selfRemoving() {
      calls.add('self');
      observable.removeListener(selfRemoving);
    }

    observable.addListener(selfRemoving);
    observable.addListener(() => calls.add('other'));
    observable.notifyListeners();
    observable.notifyListeners();
    expect(calls, ['self', 'other', 'other']);
  });

  test('被移除的监听器当轮不再调用，新监听器从下一轮开始', () {
    final observable = _Observable();
    final calls = <String>[];
    void removed() => calls.add('removed');
    void added() => calls.add('added');
    observable.addListener(() {
      calls.add('first');
      observable.removeListener(removed);
      observable.addListener(added);
    });
    observable.addListener(removed);

    observable.notifyListeners();
    expect(calls, ['first']);
    observable.notifyListeners();
    expect(calls, ['first', 'first', 'added']);
  });

  test('通知过程中释放所有监听器会停止当轮后续回调', () {
    final observable = _Observable();
    final calls = <String>[];
    observable.addListener(() {
      calls.add('dispose');
      observable.listeners.clear();
    });
    observable.addListener(() => calls.add('after disposal'));
    observable.notifyListeners();
    expect(calls, ['dispose']);
  });
}
