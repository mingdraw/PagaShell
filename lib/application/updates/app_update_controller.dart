import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:get/get.dart';

import '../../domain/updates/app_release.dart';
import '../../domain/updates/update_installer.dart';
import '../settings/settings_controller.dart';

enum UpdatePhase {
  idle,
  checking,
  downloading,
  verifying,
  preparing,
  installing,
}

class AppUpdateController extends GetxController {
  AppUpdateController({
    required this._connect,
    required this._createDownloadConnect,
    required this._settings,
    required this._installer,
  });

  final GetConnect _connect;
  final GetConnect Function() _createDownloadConnect;
  final SettingsController _settings;
  final UpdateInstaller _installer;
  final phase = UpdatePhase.idle.obs;
  final currentVersion = ''.obs;
  final available = Rxn<AppRelease>();
  final message = ''.obs;
  final progress = 0.0.obs;
  InstalledApplication? _installed;
  GetConnect? _activeDownload;
  Future<AppRelease?>? _checking;
  Future<void>? _installing;
  bool _startupChecked = false;
  bool _cancelled = false;
  bool _committed = false;
  bool _promptOpen = false;
  String? _offeredVersion;
  PendingUpdate? _pending;
  late final Future<void> ready = _loadInstalled();

  /// ShellPage supplies the existing save/close/proxy-restore/native-exit path.
  Future<bool> Function(Future<void> Function() commit)? exitForUpdate;

  bool get busy => phase.value != UpdatePhase.idle;
  bool get canCancel =>
      phase.value == UpdatePhase.downloading ||
      phase.value == UpdatePhase.verifying;

  @override
  void onInit() {
    super.onInit();
    unawaited(ready);
  }

  Future<void> _loadInstalled() async {
    try {
      _installed = await _installer.installedApplication();
      if (!isClosed) currentVersion.value = _installed!.version;
    } on Object {
      if (!isClosed) message.value = '无法读取当前版本，请重试';
    }
  }

  Future<AppRelease?> checkOnStartup() async {
    if (_startupChecked) return null;
    _startupChecked = true;
    await _settings.ready;
    if (isClosed || !_settings.automaticUpdates.value) return null;
    final release = await check();
    return !isClosed && _settings.automaticUpdates.value ? release : null;
  }

  bool beginPrompt(AppRelease release, {required bool automatic}) {
    if (_promptOpen || (automatic && _offeredVersion == release.tag)) {
      return false;
    }
    _promptOpen = true;
    _offeredVersion = release.tag;
    return true;
  }

  void endPrompt() => _promptOpen = false;

  Future<AppRelease?> check() {
    if (_installing != null) return Future.value(null);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<AppRelease?> _check() async {
    phase.value = UpdatePhase.checking;
    message.value = '';
    available.value = null;
    try {
      await ready;
      if (_installed == null) await _loadInstalled();
      if (_installed == null) throw const FormatException('无法读取当前版本，请重试');
      final response = await _connect.get<Map<String, dynamic>>(
        'https://api.github.com/repos/mingdraw/PagaShell/releases/latest',
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'PagaShell/${_installed!.version}',
          'X-GitHub-Api-Version': '2026-03-10',
        },
      );
      if (isClosed) return null;
      if (!response.isOk ||
          response.statusCode != 200 ||
          response.body == null) {
        throw const FormatException('检查更新失败，请检查网络后重试');
      }
      final release = AppRelease.fromGitHub(response.body!, _installed!);
      if (ReleaseVersion.parse(release.version)
              .compareTo(ReleaseVersion.parse(_installed!.version)) <=
          0) {
        message.value = '当前已是最新版本';
        return null;
      }
      available.value = release;
      return release;
    } on FormatException catch (error) {
      if (!isClosed) message.value = error.message;
    } on Object {
      if (!isClosed) message.value = '检查更新失败，请检查网络后重试';
    } finally {
      if (!isClosed) phase.value = UpdatePhase.idle;
    }
    return null;
  }

  Future<void> install(AppRelease release) =>
      _installing ??= _install(release).whenComplete(() => _installing = null);

  Future<void> _install(AppRelease release) async {
    if (busy || exitForUpdate == null) return;
    _cancelled = false;
    _committed = false;
    message.value = '';
    progress.value = 0;
    phase.value = UpdatePhase.downloading;
    String? archive;
    try {
      archive = await _installer.downloadPath(release);
      _throwIfCancelled();
      await _download(release, File(archive));
      _throwIfCancelled();
      phase.value = UpdatePhase.verifying;
      final digest = await crypto.sha256.bind(File(archive).openRead()).first;
      _throwIfCancelled();
      if (digest.toString() != release.sha256) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      phase.value = UpdatePhase.preparing;
      _pending = await _installer.prepare(release, archive);
      _throwIfCancelled();
      phase.value = UpdatePhase.installing;
      final allowed = await exitForUpdate!(() async {
        await _pending!.commit();
        _committed = true;
      });
      if (!allowed) {
        _committed = false;
        message.value = '更新已取消';
      }
    } on FormatException catch (error) {
      _committed = false;
      if (!isClosed) message.value = _cancelled ? '更新已取消' : error.message;
    } on Object {
      _committed = false;
      if (!isClosed) message.value = _cancelled ? '更新已取消' : '下载或安装更新失败，请重试';
    } finally {
      if (!_committed) {
        // A failed native close must revoke the handoff before any later exit.
        try {
          await _pending?.cancel();
        } on Object {
          /* Best-effort cleanup. */
        }
        if (archive != null) {
          try {
            await _installer.discard(archive);
          } on Object {
            /* Best-effort cleanup. */
          }
        }
      }
      _pending = null;
      if (!isClosed) phase.value = UpdatePhase.idle;
    }
  }

  Future<void> _download(AppRelease release, File file) async {
    final client = _createDownloadConnect();
    _activeDownload = client;
    try {
      // The interceptor returns before GetX's default UTF-8 body decoder.
      // Keep the original stream, rather than buffering a desktop package in RAM.
      final response = await client.httpClient.get<void>(
        release.downloadUrl.toString(),
        headers: {
          'Accept': 'application/octet-stream',
          'User-Agent': 'PagaShell/${currentVersion.value}',
        },
        responseInterceptor: (request, type, raw) async {
          if (raw.redirects.any(
            (redirect) =>
                redirect.location.hasScheme &&
                redirect.location.scheme != 'https',
          )) {
            await raw.listen((_) {}).cancel();
            throw const FormatException('更新下载地址无效');
          }
          final headers = <String, String>{};
          raw.headers.forEach((key, values) => headers[key] = values.join(','));
          return Response<void>(
            request: request,
            statusCode: raw.statusCode,
            headers: headers,
            bodyBytes: raw,
          );
        },
      );
      _throwIfCancelled();
      if (!response.isOk ||
          response.statusCode != 200 ||
          response.bodyBytes == null) {
        throw const FormatException('下载更新失败，请检查网络后重试');
      }
      final length = int.tryParse(response.headers?['content-length'] ?? '');
      if (length != null && length != release.size) {
        throw const FormatException('安装包大小不匹配，请重新下载');
      }
      final output = await file.open(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.bodyBytes!.timeout(
          const Duration(seconds: 45),
        )) {
          _throwIfCancelled();
          received += chunk.length;
          if (received > release.size) {
            throw const FormatException('安装包大小不匹配，请重新下载');
          }
          await output.writeFrom(chunk);
          if (!isClosed) progress.value = received / release.size;
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (received != release.size) {
        throw const FormatException('安装包下载不完整，请重新下载');
      }
    } finally {
      client.dispose();
      _activeDownload = null;
    }
  }

  void _throwIfCancelled() {
    if (_cancelled || isClosed) throw const FormatException('更新已取消');
  }

  Future<void> cancelDownload() async {
    if (!canCancel) return;
    _cancelled = true;
    _activeDownload?.dispose();
    await _installing;
  }

  @override
  void onClose() {
    _cancelled = true;
    _activeDownload?.dispose();
    if (!_committed) unawaited(_pending?.cancel().catchError((Object _) {}));
    super.onClose();
  }
}
