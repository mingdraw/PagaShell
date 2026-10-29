import '../entities/identity.dart';

/// 凭证（登录身份）存储的抽象接口。
///
/// 只存元数据（名称/用户名/认证方式/密文引用），密文本体走 SecretStore。
abstract interface class IdentityRepository {
  /// 监听全量凭证列表（含首帧当前值）。
  Stream<List<Identity>> watchAll();

  Future<List<Identity>> getAll();

  Future<void> upsert(Identity identity);

  /// 是否仍有服务或网关使用该凭证。
  Future<bool> isReferenced(String id);

  /// 有服务或网关引用时抛出 [StateError]，保留凭证。
  Future<void> remove(String id);
}
