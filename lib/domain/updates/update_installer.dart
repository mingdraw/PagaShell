import 'app_release.dart';

abstract interface class UpdateInstaller {
  Future<InstalledApplication> installedApplication();
  Future<String> downloadPath(AppRelease release);
  Future<PendingUpdate> prepare(AppRelease release, String archivePath);
  Future<void> discard(String archivePath);
}

/// Helper 已就绪但尚未获得替换许可；正常退出获准后才 commit。
abstract interface class PendingUpdate {
  Future<void> commit();
  Future<void> cancel();
}
