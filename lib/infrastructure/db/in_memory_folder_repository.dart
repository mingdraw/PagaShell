import 'dart:async';

import '../../domain/entities/folder.dart';
import '../../domain/repositories/folder_repository.dart';

/// 内存版文件夹存储：用于测试与 drift 落地前的替身。
class InMemoryFolderRepository implements FolderRepository {
  final Map<String, Folder> _folders = {};
  final StreamController<List<Folder>> _changes =
      StreamController<List<Folder>>.broadcast();

  List<Folder> get _snapshot => List.unmodifiable(_folders.values);

  @override
  Stream<List<Folder>> watchAll() async* {
    yield _snapshot;
    yield* _changes.stream;
  }

  @override
  Future<List<Folder>> getAll() async => _snapshot;

  @override
  Future<void> upsert(Folder folder) async {
    _folders[folder.id] = folder;
    _changes.add(_snapshot);
  }

  @override
  Future<void> remove(String id) async {
    _folders.remove(id);
    _changes.add(_snapshot);
  }

  void dispose() {
    _changes.close();
  }
}
