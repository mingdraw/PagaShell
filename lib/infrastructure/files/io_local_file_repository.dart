import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:win32/win32.dart' as win32;

import '../../domain/entities/local_file_entry.dart';
import '../../domain/entities/small_text_file.dart';
import '../../domain/repositories/local_file_repository.dart';

class IoLocalFileRepository
    implements LocalFileRepository, LocalFileMover, SmallTextFileAccess {
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
        name.contains('\x00') ||
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
      isSymbolicLink:
          FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link,
    );
  }

  @override
  Future<List<LocalFileEntry>> listDirectory(String path) =>
      Isolate.run(() => _listDirectory(path));

  static List<LocalFileEntry> _listDirectory(String path) {
    final entries = <LocalFileEntry>[];
    try {
      for (final entity in Directory(path).listSync(followLinks: false)) {
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
            isSymbolicLink: entity is Link,
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

  static bool _hasWindowsHiddenAttribute(String path) {
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
  Future<void> createDirectory(
    String path, {
    bool rejectExisting = false,
  }) async {
    if (rejectExisting &&
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const LocalFileTargetExists();
    }
    try {
      await Directory(path).create();
    } on FileSystemException catch (e) {
      if (rejectExisting && e is PathExistsException) {
        throw const LocalFileTargetExists();
      }
      if (Platform.isMacOS &&
          (e.osError?.errorCode == 1 || e.osError?.errorCode == 13)) {
        throw LocalDirectoryAccessDenied(path);
      }
      rethrow;
    }
  }

  @override
  Future<void> rename(
    String path,
    String newName, {
    required bool isDir,
  }) async => moveTo(path, pathOf(parentOf(path), newName), isDir: isDir);

  @override
  Future<void> moveTo(String path, String target, {required bool isDir}) async {
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

  Future<FileStat> _textStat(String path) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const SmallTextFileException('只可编辑普通文件');
    }
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) {
      throw const SmallTextFileException('只可编辑普通文件');
    }
    if (stat.size > smallTextFileByteLimit) {
      throw const SmallTextFileException('文本文件不能超过 2 MiB');
    }
    return stat;
  }

  @override
  Future<SmallTextFile> readSmallText(String path) async {
    final before = await _textStat(path);
    final file = await File(path).open();
    try {
      final bytes = await file.read(smallTextFileByteLimit + 1);
      if (bytes.length > smallTextFileByteLimit) {
        throw const SmallTextFileException('文本文件不能超过 2 MiB');
      }
      final after = await _textStat(path);
      if (after.size != bytes.length || after.modified != before.modified) {
        throw const SmallTextFileException('文件已被修改，请重新打开');
      }
      final hasBom =
          bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      final text = '${hasBom ? '\uFEFF' : ''}${utf8.decode(bytes)}';
      validateSmallText(text);
      return SmallTextFile(text, after.modified);
    } on FormatException {
      throw const SmallTextFileException('仅支持 UTF-8 文本文件');
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> saveSmallText(
    String path,
    SmallTextFile original,
    String text,
  ) async {
    validateSmallText(text);
    final current = await readSmallText(path);
    if (current.modified != original.modified ||
        current.text != original.text) {
      throw const SmallTextFileException('文件已被修改，请重新打开');
    }
    await File(path).writeAsBytes(utf8.encode(text), flush: true);
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
