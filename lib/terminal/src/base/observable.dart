mixin Observable {
  final listeners = <void Function()>{};

  void addListener(void Function() listener) {
    listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (final listener in List.of(listeners)) {
      // 移除立即生效；通知期间新加入的监听器从下一轮开始调用。
      if (listeners.contains(listener)) listener();
    }
  }
}
