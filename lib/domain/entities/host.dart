import 'forward_port.dart';
import 'proxy_config.dart';

enum GatewayType {
  ssh,
  page;

  String get label => this == page ? 'Page' : 'SSH';
}

enum ServiceType {
  ssh,
  rdp,
  vnc;

  String get label => name.toUpperCase();
  int get defaultPort => switch (this) {
    ssh => 22,
    rdp => 3389,
    vnc => 5900,
  };
}

/// 一台可连接的远程主机。
///
/// Domain 层实体：纯 Dart、不可变。凭据（密码/私钥）不在此实体上，
/// 通过 [identityId] 引用 Identity，密文本体存放于 SecretStore。
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.hostname,
    this.port = 22,
    this.username = 'root',
    this.note = '',
    this.tags = const [],
    this.folderId,
    this.identityId,
    this.colorValue,
    this.sortOrder = 0,
    this.gatewayId,
    this.gatewayType = GatewayType.ssh,
    this.serviceType = ServiceType.ssh,
    this.rdpDomain = '',
    this.pageClientId = '',
    this.pageServerFingerprint = '',
    this.forwardPorts = const [],
    this.proxyConfig = const ProxyConfig(),
  });

  final String id;
  final String name;
  final String hostname;
  final int port;
  final String username;
  final String note;
  final List<String> tags;

  /// 所属文件夹 id；null 表示根级（未分组）。
  final String? folderId;
  final String? identityId;

  /// 跳板网关的 ID；null 表示直接连接。
  final String? gatewayId;

  /// 网关传输类型；服务协议独立维护。
  final GatewayType gatewayType;
  final ServiceType serviceType;
  bool get isRdp => serviceType == ServiceType.rdp;
  bool get isVnc => serviceType == ServiceType.vnc;
  bool get isDesktop => serviceType != ServiceType.ssh;
  final String rdpDomain;
  final String pageClientId;
  final String pageServerFingerprint;

  /// 随网关保存的端口映射；打开页签不会自动启动。
  final List<ForwardPort> forwardPorts;
  final ProxyConfig proxyConfig;

  /// 侧边栏色标（ARGB），null 表示未设置。
  final int? colorValue;

  final int sortOrder;

  /// 形如 `user@host:port` 的展示地址。
  String get address => isVnc
      ? '$hostname:$port'
      : port == 22
      ? '$username@$hostname'
      : '$username@$hostname:$port';

  /// 用于搜索匹配的归一化文本。
  String get searchText =>
      '$name $hostname $username ${tags.join(' ')}'.toLowerCase();

  static const _unset = Object();

  Host copyWith({
    String? name,
    String? hostname,
    int? port,
    String? username,
    String? note,
    List<String>? tags,
    Object? folderId = _unset,
    Object? identityId = _unset,
    Object? gatewayId = _unset,
    GatewayType? gatewayType,
    ServiceType? serviceType,
    String? rdpDomain,
    String? pageClientId,
    String? pageServerFingerprint,
    int? colorValue,
    int? sortOrder,
    List<ForwardPort>? forwardPorts,
    ProxyConfig? proxyConfig,
  }) {
    return Host(
      id: id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      note: note ?? this.note,
      tags: tags ?? this.tags,
      folderId: identical(folderId, _unset)
          ? this.folderId
          : folderId as String?,
      identityId: identical(identityId, _unset)
          ? this.identityId
          : identityId as String?,
      gatewayId: identical(gatewayId, _unset)
          ? this.gatewayId
          : gatewayId as String?,
      gatewayType: gatewayType ?? this.gatewayType,
      serviceType: serviceType ?? this.serviceType,
      rdpDomain: rdpDomain ?? this.rdpDomain,
      pageClientId: pageClientId ?? this.pageClientId,
      pageServerFingerprint:
          pageServerFingerprint ?? this.pageServerFingerprint,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
      forwardPorts: forwardPorts ?? this.forwardPorts,
      proxyConfig: proxyConfig ?? this.proxyConfig,
    );
  }

  @override
  bool operator ==(Object other) => other is Host && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Host($id, $name, $address)';
}
