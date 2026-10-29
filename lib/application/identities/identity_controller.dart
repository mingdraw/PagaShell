import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';

import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/repositories/identity_repository.dart';
import '../../domain/repositories/identity_tree_repository.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';

/// 凭证控制器：管理可复用的密码或私钥登录身份。
///
/// 密码、私钥及口令经 [SecretStore] 存取，实体上只保留引用；
/// 依赖通过构造函数显式注入（装配见 AppBinding）。
class IdentityController extends GetxController {
  IdentityController({
    required this._repository,
    required this._secretStore,
    this._privateKeyValidator,
    this._treeRepository,
  });

  final IdentityRepository _repository;
  final SecretStore _secretStore;
  final PrivateKeyValidator? _privateKeyValidator;
  final IdentityTreeRepository? _treeRepository;

  final RxList<Identity> identities = <Identity>[].obs;

  StreamSubscription<List<Identity>>? _subscription;

  @override
  void onInit() {
    super.onInit();
    _subscription = _repository.watchAll().listen(identities.assignAll);
  }

  @override
  void onClose() {
    _subscription?.cancel();
    super.onClose();
  }

  List<Identity> get sorted {
    final result = List<Identity>.of(identities);
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Identity? byId(String? id) {
    if (id == null) return null;
    for (final identity in identities) {
      if (identity.id == id) return identity;
    }
    return null;
  }

  bool isNameTaken(String name, {String? folderId, String? excludeId}) =>
      identities.any(
        (identity) =>
            identity.id != excludeId &&
            identity.folderId == folderId &&
            identity.name == name.trim(),
      );

  Future<Identity> _saveMetadata(Identity identity) async {
    final tree = _treeRepository;
    if (tree != null) return tree.saveIdentity(identity);
    await _repository.upsert(identity);
    return identity;
  }

  /// 新建密码凭证：密码入 SecretStore，元数据入仓库。返回创建的凭证。
  Future<Identity> saveWithPassword({
    required String name,
    required String username,
    required String password,
    String? folderId,
    ServiceType serviceType = ServiceType.ssh,
  }) async {
    return _save(
      name,
      username,
      AuthType.password,
      password,
      folderId,
      serviceType,
    );
  }

  /// 私钥与口令一起保存到系统钥匙串，普通存储仅保存引用。
  Future<Identity> saveWithPrivateKey({
    required String name,
    required String username,
    required String privateKey,
    String? passphrase,
    String? folderId,
  }) async {
    final secret = await _encodePrivateKey(privateKey, passphrase);
    return _save(
      name,
      username,
      AuthType.privateKey,
      secret,
      folderId,
      ServiceType.ssh,
    );
  }

  Future<String> _encodePrivateKey(
    String privateKey,
    String? passphrase,
  ) async {
    final validator = _privateKeyValidator;
    if (validator == null) throw const SshEngineException('未配置私钥校验器，无法保存');
    final key = privateKey.trim();
    if (key.isEmpty) throw const SshEngineException('请导入或粘贴私钥');
    final phrase = passphrase == null || passphrase.isEmpty ? null : passphrase;
    await validator.validatePrivateKey(key, passphrase: phrase);
    return jsonEncode({'version': 1, 'privateKey': key, 'passphrase': phrase});
  }

  Future<Identity> _save(
    String name,
    String username,
    AuthType type,
    String secret,
    String? folderId,
    ServiceType serviceType,
  ) async {
    final id = 'idn-${DateTime.now().microsecondsSinceEpoch}';
    final secretRef = 'sec-$id';
    await _secretStore.put(secretRef, secret);
    final identity = Identity(
      id: id,
      name: name.trim(),
      username: username,
      authType: type,
      secretRef: secretRef,
      folderId: folderId,
      serviceType: serviceType,
    );
    try {
      return await _saveMetadata(identity);
    } on Object {
      await _restoreSecret(secretRef, null);
      rethrow;
    }
  }

  Future<void> _restoreSecret(String ref, String? previous) async {
    try {
      if (previous == null) {
        await _secretStore.delete(ref);
      } else {
        await _secretStore.put(ref, previous);
      }
    } on Object {
      throw const SecretStoreException('凭证信息保存失败，系统钥匙串恢复失败，请解锁后重新保存凭证');
    }
  }

  /// 未提供新密文时保留原值；认证方式不可更换，需新建对应类型的凭证。
  Future<void> updateIdentity({
    required String id,
    required String name,
    required String username,
    String? password,
    AuthType? authType,
    String? privateKey,
    String? passphrase,
  }) async {
    final existing = byId(id);
    if (existing == null) return;
    final type = authType ?? existing.authType;
    if (type != existing.authType) {
      throw const SshEngineException('请新建对应认证方式的凭证');
    }
    String? secret;
    switch (type) {
      case AuthType.password:
        if (password != null && password.isNotEmpty) secret = password;
      case AuthType.privateKey:
        if (privateKey != null && privateKey.trim().isNotEmpty) {
          secret = await _encodePrivateKey(privateKey, passphrase);
        } else if (passphrase != null && passphrase.isNotEmpty) {
          throw const SshEngineException('更换私钥口令时请重新导入私钥');
        }
      default:
        throw const SshEngineException('暂不支持此认证方式');
    }
    var secretRef = existing.secretRef;
    String? previousSecret;
    if (secret != null) {
      final shared =
          secretRef != null &&
          (await _repository.getAll()).any(
            (i) => i.id != id && i.secretRef == secretRef,
          );
      if (shared) {
        secretRef = 'sec-$id-${DateTime.now().microsecondsSinceEpoch}';
      }
      secretRef ??= 'sec-$id';
      previousSecret = await _secretStore.read(secretRef);
      await _secretStore.put(secretRef, secret);
    }
    try {
      await _saveMetadata(
        existing.copyWith(
          name: name.trim(),
          username: username,
          secretRef: secretRef,
        ),
      );
    } on Object {
      if (secret != null) await _restoreSecret(secretRef!, previousSecret);
      rethrow;
    }
  }

  /// 解出凭证对应的密码；凭证无密文引用或密文缺失时返回 null。
  Future<String?> passwordOf(Identity identity) {
    final ref = identity.secretRef;
    if (ref == null || identity.authType != AuthType.password) {
      return Future.value();
    }
    return _secretStore.read(ref);
  }

  Future<SshCredentials?> credentialsOf(Identity identity) async {
    final ref = identity.secretRef;
    if (ref == null) return null;
    if (identity.authType != AuthType.password &&
        identity.authType != AuthType.privateKey) {
      throw const SshEngineException('暂不支持此认证方式');
    }
    final secret = await _secretStore.read(ref);
    if (secret == null) return null;
    if (identity.authType == AuthType.password) {
      return SshCredentials.password(secret, username: identity.username);
    }
    try {
      final Object? decoded = jsonDecode(secret);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException();
      }
      final Object? key = decoded['privateKey'];
      final Object? phrase = decoded['passphrase'];
      if (key is! String ||
          key.trim().isEmpty ||
          (phrase != null && phrase is! String)) {
        throw const FormatException();
      }
      return SshCredentials.privateKey(
        key,
        passphrase: phrase as String?,
        username: identity.username,
      );
    } on Object {
      throw const SecretStoreException('已保存的私钥凭证无法读取，请重新编辑并导入私钥');
    }
  }

  /// 仅删除未被服务或网关引用的凭证及其密文。
  Future<void> remove(String id) async {
    if (await _repository.isReferenced(id)) {
      throw StateError('凭证正在被网关或服务使用，请先修改对应的凭证配置');
    }
    final all = await _repository.getAll();
    final identity = all.firstWhereOrNull((identity) => identity.id == id);
    final ref = identity?.secretRef;
    final ownsSecret =
        ref != null && !all.any((i) => i.id != id && i.secretRef == ref);
    final secret = !ownsSecret ? null : await _secretStore.read(ref);
    if (ownsSecret) await _secretStore.delete(ref);
    try {
      // 仓库会复查引用；检查后被绑定或删除失败时，恢复原密文。
      await _repository.remove(id);
    } on Object {
      if (ownsSecret && secret != null) {
        try {
          await _secretStore.put(ref, secret);
        } on Object {
          throw const SecretStoreException('凭证删除失败，系统钥匙串恢复失败，请解锁后重新保存凭证');
        }
      }
      rethrow;
    }
  }
}
