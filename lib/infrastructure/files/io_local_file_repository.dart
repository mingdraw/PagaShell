import 'dart:io';

import 'package:win32/win32.dart' as win32;

import '../../domain/entities/local_file_entry.dart';
import '../../domain/repositories/local_file_repository.dart';

class IoLocalFileRepository implements LocalFileRepository {
  const IoLocalFileRepository({this.userHomeDirectory});

  final String? userHomeDirectory;

  @override
  String get homeDirectory =>
      userHomeDirectory ??
      resolveHomeDirectory(Platform.environment, windows: Platform.isWindows) ??
      Directory.current.path;

  static String? resolveHomeDirectory(
    Map<String, String> environment, {
    required bool windows,
  }) {
    final home = environment[windows ? 'USERPROFILE' : 'HOME'];
    if (home != null && home.isNotEmpty) {
      return home;
    }
    if (windows) {
      final drive = environment['HOMEDRIVE'];
      final path = environment['HOMEPATH'];
      if (drive != null && path != null && path.isNotEmpty) {
        return '$drive$path';
      }
    }
    return null;
  }

  @override
  String parentOf(String path) => Directory(path).parent.path;

  @override
  String pathOf(String directory, String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        (Platform.isWindows && name.contains('\\'))) {
      throw ArgumentError.value(name, 'name');
    }
    return Directory(directory).uri
        .resolveUri(Uri(pathSegments: [name]))
        .toFilePath();
  }

  @override
  Future<LocalFileEntry> entryAt(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file &&
        stat.type != FileSystemEntityType.directory) {
      throw FileSystemException('Unsupported or inaccessible file', path);
    }
    final name = File(path).uri.pathSegments
        .lastWhere((part) => part.isNotEmpty);
    return LocalFileEntry(
      path: path,
      name: name,
      isDir: stat.type == FileSystemEntityType.directory,
      size: stat.size,
      modified: stat.modified,
    );
  }

  @override
  Future<List<LocalFileEntry>> listDirectory(String path) async {
    final entries = <LocalFileEntry>[];
    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        final stat = entity.statSync();
        if (stat.type != FileSystemEntityType.directory &&
            stat.type != FileSystemEntityType.file) {
          continue;
        }
        final name = entity.uri.pathSegments.lastWhere(
          (part) => part.isNotEmpty,
        );
        entries.add(
          LocalFileEntry(
            path: entity.path,
            name: name,
            isDir: stat.type == FileSystemEntityType.directory,
            size: stat.size,
            modified: stat.modified,
            isHidden:
                name.startsWith('.') || _hasWindowsHiddenAttribute(entity.path),
          ),
        );
      }
    } on FileSystemException catch (e) {
      // EPERM / EACCES：沙盒或文件系统拒绝访问，其他读取错误照常上抛。
      if (Platform.isMacOS &&
          (e.osError?.errorCode == 1 || e.osError?.errorCode == 13)) {
        throw LocalDirectoryAccessDenied(path);
      }
      rethrow;
    }
    return entries;
  }

  bool _hasWindowsHiddenAttribute(String path) {
    if (!Platform.isWindows) return false;
    final nativePath = path.toPcwstr();
    try {
      final attributes = win32.GetFileAttributes(nativePath).value;
      return attributes != 0xFFFFFFFF &&
          attributes & win32.FILE_ATTRIBUTE_HIDDEN != 0;
    } finally {
      win32.free(nativePath);
    }
  }

  @override
  Future<void> rename(
    String path,
    String newName, {
    required bool isDir,
  }) async {
    final target = pathOf(parentOf(path), newName);
    if (target == path) return;
    if (FileSystemEntity.typeSync(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const LocalFileTargetExists();
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      await Link(path).rename(target);
    } else if (isDir) {
      await Directory(path).rename(target);
    } else {
      await File(path).rename(target);
    }
  }

  @override
  Future<void> remove(String path, {required bool isDir}) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (isDir) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  }
}
