/// 将服务本机的目标端口映射到本地监听端口。
class ForwardPort {
  const ForwardPort({required this.localPort, required this.targetPort});

  final int localPort;
  final int targetPort;

  Map<String, Object> toJson() => {
    'localPort': localPort,
    'targetPort': targetPort,
  };

  factory ForwardPort.fromJson(Map<String, dynamic> json) => ForwardPort(
    localPort: json['localPort'] as int,
    targetPort: json['targetPort'] as int,
  );

  static void validateAll(List<ForwardPort> ports, {bool allowEmpty = true}) {
    if (!allowEmpty && ports.isEmpty) {
      throw StateError('请添加至少一组端口映射');
    }
    final localPorts = <int>{};
    for (final port in ports) {
      if (port.localPort < 1 ||
          port.localPort > 65535 ||
          port.targetPort < 1 ||
          port.targetPort > 65535) {
        throw StateError('请填写有效的端口（1-65535）');
      }
      if (!localPorts.add(port.localPort)) {
        throw StateError('本地端口不能重复');
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ForwardPort &&
      other.localPort == localPort &&
      other.targetPort == targetPort;

  @override
  int get hashCode => Object.hash(localPort, targetPort);
}
