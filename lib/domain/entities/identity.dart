import 'host.dart';

/// 认证方式。
enum AuthType { password, privateKey, keyboardInteractive, agent }

/// 登录身份：用户名 + 认证方式的可复用组合。
///
/// 密码 / 私钥 / 私钥口令不在实体上，存放于系统钥匙串，
/// 此处仅保留引用键 [secretRef]。
class Identity {
  const Identity({
    required this.id,
    required this.name,
    required this.username,
    required this.authType,
    this.secretRef,
    this.folderId,
    this.sortOrder = 0,
    this.serviceType = ServiceType.ssh,
  });

  final String id;
  final String name;
  final String username;
  final AuthType authType;
  final String? secretRef;
  final String? folderId;
  final int sortOrder;
  final ServiceType serviceType;

  bool supports(ServiceType type) =>
      serviceType == type &&
      (authType == AuthType.password ||
          (type == ServiceType.ssh && authType == AuthType.privateKey));

  Identity copyWith({
    String? name,
    String? username,
    Object? secretRef = _unset,
    Object? folderId = _unset,
    int? sortOrder,
    ServiceType? serviceType,
  }) => Identity(
    id: id,
    name: name ?? this.name,
    username: username ?? this.username,
    authType: authType,
    secretRef: identical(secretRef, _unset)
        ? this.secretRef
        : secretRef as String?,
    folderId: identical(folderId, _unset) ? this.folderId : folderId as String?,
    sortOrder: sortOrder ?? this.sortOrder,
    serviceType: serviceType ?? this.serviceType,
  );

  static const _unset = Object();

  @override
  bool operator ==(Object other) => other is Identity && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
