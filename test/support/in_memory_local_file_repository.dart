import 'package:pagashell/domain/entities/local_file_entry.dart';
import 'package:pagashell/domain/repositories/local_file_repository.dart';

class InMemoryLocalFileRepository implements LocalFileRepository {
  final deniedDirectories = <String>{};

  final Map<String, List<LocalFileEntry>> fs = {
    '/local': [
      const LocalFileEntry(
        path: '/local/downloads',
        name: 'downloads',
        isDir: true,
        size: 0,
      ),
      const LocalFileEntry(
        path: '/local/upload.txt',
        name: 'upload.txt',
        isDir: false,
        size: 100,
      ),
    ],
    '/local/downloads': [],
  };

  @override
  String get homeDirectory => '/local';

  @override
  String parentOf(String path) {
    final cut = path.lastIndexOf('/');
    return cut <= 0 ? '/' : path.substring(0, cut);
  }

  @override
  String pathOf(String directory, String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw ArgumentError.value(name, 'name');
    }
    return directory == '/' ? '/$name' : '$directory/$name';
  }

  @override
  Future<LocalFileEntry> entryAt(String path) async {
    for (final entries in fs.values) {
      for (final entry in entries) {
        if (entry.path == path) return entry;
      }
    }
    throw StateError('Missing local file');
  }

  @override
  Future<List<LocalFileEntry>> listDirectory(String path) async {
    if (deniedDirectories.contains(path)) {
      throw LocalDirectoryAccessDenied(path);
    }
    return List.of(fs[path] ?? (throw StateError('Missing local directory')));
  }

  @override
  Future<void> rename(
    String path,
    String newName, {
    required bool isDir,
  }) async {
    final parent = fs[parentOf(path)]!;
    final target = pathOf(parentOf(path), newName);
    if (target == path) return;
    if (parent.any((entry) => entry.path == target)) {
      throw const LocalFileTargetExists();
    }
    final index = parent.indexWhere((entry) => entry.path == path);
    parent[index] = _withPath(parent[index], target);
    for (final directory in fs.keys.toList()) {
      if (directory == path || directory.startsWith('$path/')) {
        final entries = fs.remove(directory)!;
        fs['$target${directory.substring(path.length)}'] = [
          for (final entry in entries)
            _withPath(entry, '$target${entry.path.substring(path.length)}'),
        ];
      }
    }
  }

  LocalFileEntry _withPath(LocalFileEntry entry, String path) => LocalFileEntry(
    path: path,
    name: path.substring(path.lastIndexOf('/') + 1),
    isDir: entry.isDir,
    size: entry.size,
    modified: entry.modified,
    isHidden: entry.isHidden,
  );

  @override
  Future<void> remove(String path, {required bool isDir}) async {
    fs[parentOf(path)]!.removeWhere((entry) => entry.path == path);
    fs.removeWhere(
      (directory, _) => directory == path || directory.startsWith('$path/'),
    );
  }

  void putFile(String path, int size, {DateTime? modified}) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final entries = fs[parentOf(path)]!;
    entries.removeWhere((entry) => entry.name == name);
    entries.add(
      LocalFileEntry(
        path: path,
        name: name,
        isDir: false,
        size: size,
        modified: modified,
      ),
    );
  }
}
