import 'stored_identity_tree_repository.dart';

class InMemoryIdentityTreeRepository extends StoredIdentityTreeRepository {
  InMemoryIdentityTreeRepository({
    required super.folders,
    required super.identities,
  });
  Future<void>? _pending;
  @override
  Future<T> transaction<T>(Future<T> Function() action) {
    final result = _pending?.then((_) => action()) ?? Future<T>.sync(action);
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
