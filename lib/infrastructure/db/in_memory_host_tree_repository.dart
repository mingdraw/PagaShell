import 'stored_host_tree_repository.dart';

/// 内存替身串行处理写入，避免并发新增取到相同的末尾位置。
class InMemoryHostTreeRepository extends StoredHostTreeRepository {
  InMemoryHostTreeRepository({required super.folders, required super.hosts});

  Future<void>? _pending;

  @override
  Future<T> transaction<T>(Future<T> Function() action) {
    final result = _pending?.then((_) => action()) ?? Future<T>.sync(action);
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
