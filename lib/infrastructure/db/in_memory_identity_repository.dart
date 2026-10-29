import 'dart:async';

import '../../domain/entities/identity.dart';
import '../../domain/repositories/host_repository.dart';
import '../../domain/repositories/identity_repository.dart';

/// 内存版凭证存储：M2 引入 drift(SQLite) 前的临时实现。
class InMemoryIdentityRepository implements IdentityRepository {
  InMemoryIdentityRepository({this._services, this._gateways});

  final HostRepository? _services;
  final HostRepository? _gateways;
  final Map<String, Identity> _identities = {};
  final StreamController<List<Identity>> _changes =
      StreamController<List<Identity>>.broadcast();

  List<Identity> get _snapshot => List.unmodifiable(_identities.values);

  @override
  Stream<List<Identity>> watchAll() async* {
    yield _snapshot;
    yield* _changes.stream;
  }

  @override
  Future<List<Identity>> getAll() async => _snapshot;

  @override
  Future<void> upsert(Identity identity) async {
    _identities[identity.id] = identity;
    _changes.add(_snapshot);
  }

  @override
  Future<bool> isReferenced(String id) async {
    for (final repository in [_services, _gateways]) {
      if (repository != null &&
          (await repository.getAll()).any((host) => host.identityId == id)) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> remove(String id) async {
    if (await isReferenced(id)) {
      throw StateError('凭证正在被网关或服务使用，请先修改对应的凭证配置');
    }
    _identities.remove(id);
    _changes.add(_snapshot);
  }

  void dispose() {
    _changes.close();
  }
}
