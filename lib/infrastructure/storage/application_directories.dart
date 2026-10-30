import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Continue using existing sandbox data after the GitHub macOS build becomes
/// unsandboxed for Authorization Services. Never copy an open SQLite database.
abstract final class ApplicationDirectories {
  static const _bundle = 'io.github.zhongxuming.pagashell';

  static Future<Directory> database() async {
    final current = await getApplicationDocumentsDirectory();
    if (!Platform.isMacOS) return current;
    final home = await _home();
    final legacy = Directory(
      path.join(home, 'Library', 'Containers', _bundle, 'Data', 'Documents'),
    );
    return preferExisting(legacy, current, 'pagashell.sqlite');
  }

  static Future<Directory> vault() async {
    final current = await getApplicationSupportDirectory();
    if (!Platform.isMacOS) return current;
    final home = await _home();
    final legacy = Directory(
      path.join(
        home,
        'Library',
        'Containers',
        _bundle,
        'Data',
        'Library',
        'Application Support',
        _bundle,
      ),
    );
    return preferExisting(legacy, current, 'credentials.vault');
  }

  static Future<String> _home() async {
    final home = await const MethodChannel('pagashell/files')
        .invokeMethod<String>('getUserHomeDirectory');
    if (home == null || !path.isAbsolute(home)) {
      throw const FileSystemException('User home directory unavailable');
    }
    return home;
  }

  static Future<Directory> preferExisting(
    Directory legacy,
    Directory current,
    String filename,
  ) async =>
      File(path.join(legacy.path, filename)).existsSync() ? legacy : current;
}
