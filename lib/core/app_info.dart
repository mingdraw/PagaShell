/// 应用元信息。
///
/// 版本号与 pubspec.yaml 保持一致；后续可切换为 package_info_plus 运行时读取。
abstract final class AppInfo {
  static const String name = 'PagaShell';
  static const String version = '0.1.0-dev';
  static const String versionLabel = 'v$version';
  static const String repository = 'https://github.com/zhongxuming/PagaShell';
}
