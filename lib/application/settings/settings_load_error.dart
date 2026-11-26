/// 脱敏后的本地设置读取失败摘要，仅包含错误分类与错误码，不含凭据、配置内容或文件路径。
class SettingsLoadError {
  const SettingsLoadError(this.key, [this.params = const {}]);

  final String key;
  final Map<String, String> params;

  static SettingsLoadError from(Object error) {
    if (error is FormatException) {
      return const SettingsLoadError('本地配置格式无效');
    }
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('failed to load dynamic library') ||
        lower.contains('sqlite3.dll') ||
        lower.contains('libsqlite3')) {
      return const SettingsLoadError('本地 SQLite 运行库不可用');
    }
    if (lower.contains('database is locked') ||
        lower.contains('database table is locked') ||
        lower.contains('sqliteexception(5)') ||
        lower.contains('sqliteexception(6)')) {
      return const SettingsLoadError('本地数据库正被占用');
    }
    if (lower.contains('readonly') ||
        lower.contains('read-only') ||
        lower.contains('sqliteexception(8)')) {
      return const SettingsLoadError('本地数据库无写入权限');
    }
    if (lower.contains('unable to open database') ||
        lower.contains('cantopen') ||
        lower.contains('sqliteexception(14)')) {
      return const SettingsLoadError('无法打开本地数据库文件');
    }
    if (lower.contains('malformed') ||
        lower.contains('not a database') ||
        lower.contains('sqliteexception(11)') ||
        lower.contains('sqliteexception(26)')) {
      return const SettingsLoadError('本地数据库文件已损坏');
    }
    final sqliteCode = RegExp(r'SqliteException\((\d+)\)').firstMatch(raw);
    if (sqliteCode != null) {
      return SettingsLoadError('本地数据库错误（SQLite @code）', {
        'code': sqliteCode.group(1)!,
      });
    }
    return SettingsLoadError('内部错误（@type）', {
      'type': error.runtimeType.toString(),
    });
  }
}
