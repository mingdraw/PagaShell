/// 通过网关将目标 TCP 地址和端口映射到本地监听端口。
class ForwardPort {
  const ForwardPort({
    required this.localPort,
    this.bindHost = loopbackBindHost,
    this.targetHost = '127.0.0.1',
    required this.targetPort,
    this.enabled = true,
    this.note = '',
  });

  static const loopbackBindHost = '127.0.0.1';
  static const anyBindHost = '0.0.0.0';
  static const allowedBindHosts = [loopbackBindHost, anyBindHost];

  final int localPort;
  final String bindHost;
  final String targetHost;
  final int targetPort;
  final bool enabled;
  final String note;

  bool get isWildcardBind => bindHost == anyBindHost;

  ForwardPort copyWith({
    int? localPort,
    String? bindHost,
    String? targetHost,
    int? targetPort,
    bool? enabled,
    String? note,
  }) => ForwardPort(
    localPort: localPort ?? this.localPort,
    bindHost: bindHost ?? this.bindHost,
    targetHost: targetHost ?? this.targetHost,
    targetPort: targetPort ?? this.targetPort,
    enabled: enabled ?? this.enabled,
    note: note ?? this.note,
  );

  Map<String, Object> toJson() => {
    'localPort': localPort,
    if (bindHost != loopbackBindHost) 'bindHost': bindHost,
    'targetHost': targetHost,
    'targetPort': targetPort,
    if (!enabled) 'enabled': enabled,
    if (note.isNotEmpty) 'note': note,
  };

  factory ForwardPort.fromJson(Map<String, dynamic> json) {
    final rawBindHost = (json['bindHost'] as String?)?.trim();
    final bindHost = rawBindHost == null || rawBindHost.isEmpty
        ? loopbackBindHost
        : rawBindHost;
    final rawNote = json['note'];
    return ForwardPort(
      localPort: json['localPort'] as int,
      bindHost: bindHost,
      targetHost: json['targetHost'] as String? ?? '127.0.0.1',
      targetPort: json['targetPort'] as int,
      enabled: json['enabled'] as bool? ?? true,
      note: rawNote is String ? rawNote.trim() : '',
    );
  }

  static void validateAll(List<ForwardPort> ports, {bool allowEmpty = true}) {
    if (!allowEmpty) {
      if (ports.isEmpty) {
        throw StateError('请添加至少一组端口映射');
      }
      if (ports.every((port) => !port.enabled)) {
        throw StateError('请至少启用一组端口映射');
      }
    }
    final localPorts = <int>{};
    for (final port in ports) {
      if (port.bindHost != loopbackBindHost && port.bindHost != anyBindHost) {
        throw StateError('请填写有效的本地监听地址');
      }
      if (port.targetHost.trim().isEmpty ||
          RegExp(r'\s|[/\\]').hasMatch(port.targetHost)) {
        throw StateError('请填写有效的目标地址');
      }
      if (port.localPort < 1 ||
          port.localPort > 65535 ||
          port.targetPort < 1 ||
          port.targetPort > 65535) {
        throw StateError('请填写有效的端口（1-65535）');
      }
      if (port.note.length > 200 ||
          port.note.contains('\n') ||
          port.note.contains('\r')) {
        throw StateError('备注长度不能超过 200 个字符');
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
      other.bindHost == bindHost &&
      other.targetHost == targetHost &&
      other.targetPort == targetPort &&
      other.enabled == enabled &&
      other.note == note;

  @override
  int get hashCode =>
      Object.hash(localPort, bindHost, targetHost, targetPort, enabled, note);
}
