import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/updates/app_release.dart';
import 'package:pagashell/domain/updates/update_installer.dart';

Map<String, dynamic> releaseJson({String version = '0.3.0'}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'body': '修复终端问题',
  'assets': [
    for (final platform in UpdatePlatform.values)
      for (final arch in ['amd64', 'arm64'])
        {
          'name': assetName(version, platform, arch),
          'state': 'uploaded',
          'size': 4,
          'digest': 'sha256:${sha256.convert([1, 2, 3, 4])}',
          'browser_download_url':
              'https://github.com/mingdraw/PagaShell/releases/download/v$version/${assetName(version, platform, arch)}',
        },
  ],
};

String assetName(String version, UpdatePlatform platform, String arch) {
  final extension = switch (platform) {
    UpdatePlatform.macos => 'dmg',
    UpdatePlatform.windows => 'zip',
    UpdatePlatform.linux => 'tar.gz',
  };
  return 'pagashell_v${version}_${platform.name}_$arch.$extension';
}

AppRelease downloadRelease(
  Uri url, {
  List<int> bytes = const [1, 2, 3, 4],
  String? digest,
  int? size,
}) => AppRelease(
  version: '0.3.0',
  tag: 'v0.3.0',
  notes: '修复终端问题',
  assetName: 'fixture.tar.gz',
  downloadUrl: url,
  size: size ?? bytes.length,
  sha256: digest ?? sha256.convert(bytes).toString(),
  platform: UpdatePlatform.linux,
  arch: 'amd64',
);

class UpdateConnect extends GetConnect {
  UpdateConnect({this.handler});
  final FutureOr<Response<Map<String, dynamic>>> Function()? handler;
  int calls = 0;
  @override
  Future<Response<T>> get<T>(
    String url, {
    Map<String, String>? headers,
    String? contentType,
    Map<String, dynamic>? query,
    Decoder<T>? decoder,
  }) async {
    calls++;
    final response =
        await (handler?.call() ??
            Response(statusCode: 200, body: releaseJson()));
    return Response<T>(
      statusCode: response.statusCode,
      body: response.body as T?,
    );
  }
}

class TestUpdateInstaller implements UpdateInstaller {
  final pending = TestPendingUpdate();
  final events = <String>[];
  final directories = <Directory>[];
  List<int>? preparedBytes;
  bool cleanupFails = false;
  @override
  Future<InstalledApplication> installedApplication() async =>
      const InstalledApplication(
        version: '0.2.1',
        platform: UpdatePlatform.linux,
        arch: 'amd64',
      );
  @override
  Future<String> downloadPath(AppRelease release) async {
    final work = await Directory.systemTemp.createTemp(
      'pagashell-updater-test-',
    );
    directories.add(work);
    return '${work.path}/${release.assetName}';
  }

  @override
  Future<PendingUpdate> prepare(AppRelease release, String archivePath) async {
    events.add('prepare');
    preparedBytes = await File(archivePath).readAsBytes();
    return pending;
  }

  @override
  Future<void> discard(String archivePath) async {
    events.add('discard');
    if (cleanupFails) throw const FileSystemException('fixture cleanup');
    await Directory(File(archivePath).parent.path).delete(recursive: true);
  }

  Future<void> cleanup() async {
    for (final directory in directories) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  }
}

class TestPendingUpdate implements PendingUpdate {
  int commits = 0;
  int cancels = 0;
  @override
  Future<void> commit() async => commits++;
  @override
  Future<void> cancel() async => cancels++;
}
