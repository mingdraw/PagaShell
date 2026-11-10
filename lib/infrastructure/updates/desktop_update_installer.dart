import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

import '../../domain/updates/app_release.dart';
import '../../domain/updates/update_installer.dart';
import 'windows_update_launcher.dart';

class DesktopUpdateInstaller implements UpdateInstaller {
  final _owned = <String>{};
  final _helpers = <String>{};

  @override
  Future<InstalledApplication> installedApplication() async {
    final info = await PackageInfo.fromPlatform();
    final platform = Platform.isMacOS
        ? UpdatePlatform.macos
        : Platform.isWindows
        ? UpdatePlatform.windows
        : UpdatePlatform.linux;
    final abi = Abi.current();
    final arch = switch (abi) {
      Abi.macosArm64 || Abi.windowsArm64 || Abi.linuxArm64 => 'arm64',
      Abi.macosX64 || Abi.windowsX64 || Abi.linuxX64 => 'amd64',
      _ => throw const FormatException('当前处理器架构不支持自动更新'),
    };
    return InstalledApplication(
      version: info.version,
      platform: platform,
      arch: arch,
    );
  }

  Future<Directory> _installedBundle() async {
    if (!kReleaseMode) throw const FormatException('开发版本不支持自动安装，请使用发布版');
    final executable = await File(Platform.resolvedExecutable)
        .resolveSymbolicLinks();
    final root = Platform.isMacOS
        ? path.normalize(path.join(path.dirname(executable), '..', '..'))
        : path.dirname(executable);
    final platform = Platform.isMacOS
        ? UpdatePlatform.macos
        : Platform.isWindows
        ? UpdatePlatform.windows
        : UpdatePlatform.linux;
    await _validateLayout(Directory(root), platform);
    return Directory(root);
  }

  @override
  Future<String> downloadPath(AppRelease release) async {
    await _installedBundle();
    final work = await Directory.systemTemp.createTemp('pagashell-update-');
    _owned.add(work.path);
    if (!Platform.isWindows) await _run('/bin/chmod', ['700', work.path]);
    return path.join(work.path, release.assetName);
  }

  Future<void> _validateLayout(Directory root, UpdatePlatform platform) async {
    final relativeExecutable = platform == UpdatePlatform.macos
        ? 'Contents/MacOS/pagashell'
        : platform == UpdatePlatform.windows
        ? 'pagashell.exe'
        : 'pagashell';
    if (!File(path.join(root.path, relativeExecutable)).existsSync()) {
      throw const FormatException('应用安装目录无效，请重新安装后重试');
    }
    if (platform == UpdatePlatform.macos) {
      if (!root.path.endsWith('.app')) {
        throw const FormatException('应用安装目录无效，请重新安装后重试');
      }
      final identifier = await _run('/usr/libexec/PlistBuddy', [
        '-c',
        'Print :CFBundleIdentifier',
        path.join(root.path, 'Contents/Info.plist'),
      ]);
      if ((identifier.stdout as String).trim() !=
          'io.github.zhongxuming.pagashell') {
        throw const FormatException('更新安装包无效');
      }
    } else if (!Directory(path.join(root.path, 'data', 'flutter_assets'))
            .existsSync() ||
        !File(
          path.join(
            root.path,
            platform == UpdatePlatform.windows
                ? 'flutter_windows.dll'
                : 'lib/libflutter_linux_gtk.so',
          ),
        ).existsSync()) {
      throw const FormatException('应用安装目录无效，请重新安装后重试');
    }
  }

  @override
  Future<PendingUpdate> prepare(AppRelease release, String archivePath) async {
    final work = Directory(path.dirname(archivePath));
    if (!_owned.contains(work.path)) throw const FormatException('更新安装包无效');
    final target = await _installedBundle();
    final stage = Directory(path.join(work.path, 'stage'));
    await stage.create();
    final prefix =
        'pagashell_${release.tag}_${release.platform.name}_${release.arch}';
    final source = Directory(
      path.join(
        stage.path,
        release.platform == UpdatePlatform.macos ? 'PagaShell.app' : prefix,
      ),
    );
    final scriptName = release.platform == UpdatePlatform.windows
        ? 'install_windows.ps1'
        : 'install_posix.sh';
    final script = File(path.join(work.path, scriptName));
    await script.writeAsString(
      await rootBundle.loadString('assets/updater/$scriptName'),
      flush: true,
    );
    var requiresAdmin = false;
    final backup = Directory('${target.path}.pagashell-backup');
    // A writable parent can still contain a root-owned app or older backup.
    // Removing either bundle requires access inside that directory as well.
    for (final directory in [
      target.parent,
      target,
      if (backup.existsSync() && File('${backup.path}.marker').existsSync())
        backup,
    ]) {
      final probe = File(
        path.join(
          directory.path,
          '.pagashell-write-$pid-${path.basename(work.path)}',
        ),
      );
      try {
        await probe.writeAsString('', flush: true);
        await probe.delete();
      } on FileSystemException {
        requiresAdmin = true;
        break;
      }
    }
    if (requiresAdmin &&
        release.platform == UpdatePlatform.macos &&
        target.path.startsWith('/Volumes/')) {
      throw const FormatException('请先将应用移到可写目录后再更新');
    }
    if (requiresAdmin && release.platform == UpdatePlatform.linux) {
      final result = await Process.run('which', ['pkexec']);
      if (result.exitCode != 0) {
        throw const FormatException('安装目录需要管理员权限，但系统未提供授权工具');
      }
    }
    final config = File(path.join(work.path, 'install.json'));
    await config.writeAsString(
      jsonEncode({
        'source': source.path,
        'target': target.path,
        'work': work.path,
        'parentPid': pid,
        'requiresAdmin': requiresAdmin,
        'archive': archivePath,
        'stage': stage.path,
        'prefix': prefix,
      }),
      flush: true,
    );
    if (release.platform == UpdatePlatform.windows) {
      await _run(_powershell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Mode',
        'Extract',
        '-ConfigPath',
        config.path,
      ]);
    } else if (release.platform == UpdatePlatform.linux) {
      final listing = await _run('tar', ['-tzf', archivePath]);
      final entries = const LineSplitter().convert(listing.stdout as String);
      if (entries.isEmpty ||
          entries.any(
            (entry) =>
                !(entry == prefix ||
                    entry == '$prefix/' ||
                    entry.startsWith('$prefix/')) ||
                entry.split('/').contains('..') ||
                entry.startsWith('/'),
          )) {
        throw const FormatException('更新安装包无效');
      }
      await _run('tar', ['-xzf', archivePath, '-C', stage.path]);
    } else {
      final mount = Directory(path.join(work.path, 'mounted'));
      await mount.create();
      var attached = false;
      try {
        await _run('/usr/bin/hdiutil', [
          'attach',
          '-readonly',
          '-nobrowse',
          '-quiet',
          '-mountpoint',
          mount.path,
          archivePath,
        ]);
        attached = true;
        await _run('/usr/bin/ditto', [
          path.join(mount.path, 'PagaShell.app'),
          source.path,
        ]);
      } finally {
        if (attached) {
          await _run('/usr/bin/hdiutil', ['detach', '-quiet', mount.path]);
        }
      }
    }
    await _validateLayout(source, release.platform);
    // No link in the replacement bundle may resolve outside its staging root.
    final canonical = await source.resolveSymbolicLinks();
    await for (final entry in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) {
        final resolved = await entry.resolveSymbolicLinks();
        if (!path.isWithin(canonical, resolved)) {
          throw const FormatException('更新安装包无效');
        }
      }
    }
    final executable = File(
      path.join(
        source.path,
        release.platform == UpdatePlatform.macos
            ? 'Contents/MacOS/pagashell'
            : release.platform == UpdatePlatform.windows
            ? 'pagashell.exe'
            : 'pagashell',
      ),
    );
    await _verifyBinary(executable, release);
    if (release.platform == UpdatePlatform.macos) {
      await _run('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        source.path,
      ]);
      final version = await _run('/usr/libexec/PlistBuddy', [
        '-c',
        'Print :CFBundleShortVersionString',
        path.join(source.path, 'Contents/Info.plist'),
      ]);
      if ((version.stdout as String).trim() != release.version) {
        throw const FormatException('更新版本号无效');
      }
    }
    _helpers.add(work.path);
    if (release.platform == UpdatePlatform.windows) {
      await startWindowsUpdateHelper(
        powershell: _powershell,
        script: script,
        config: config,
        work: work,
      );
    } else {
      await Process.start(
        '/bin/sh',
        [
          script.path,
          'watch',
          release.platform.name,
          source.path,
          target.path,
          work.path,
          '$pid',
          '$requiresAdmin',
        ],
        workingDirectory: work.path,
        mode: ProcessStartMode.detached,
      );
    }
    final handoff = _FilePendingUpdate(work);
    final timeout = DateTime.now().add(const Duration(seconds: 20));
    while (!File(path.join(work.path, 'ready')).existsSync()) {
      if (DateTime.now().isAfter(timeout)) {
        await handoff.cancel();
        throw const FormatException('无法启动更新安装程序，请重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return handoff;
  }

  Future<void> _verifyBinary(File executable, AppRelease release) async {
    if (release.platform == UpdatePlatform.macos) {
      await _run('/usr/bin/lipo', [
        executable.path,
        '-verify_arch',
        release.arch == 'amd64' ? 'x86_64' : 'arm64',
      ]);
      return;
    }
    final binary = await executable.open();
    try {
      final header = await binary.read(64);
      if (header.length != 64) throw const FormatException('更新安装包无效');
      final bytes = ByteData.sublistView(header);
      if (release.platform == UpdatePlatform.linux) {
        final machine = release.arch == 'amd64' ? 62 : 183;
        if (header[0] != 0x7f ||
            header[1] != 69 ||
            header[2] != 76 ||
            header[3] != 70 ||
            header[4] != 2 ||
            bytes.getUint16(18, Endian.little) != machine) {
          throw const FormatException('更新安装包无效');
        }
        if (executable.statSync().mode & 0x49 == 0) {
          throw const FormatException('更新安装包无效');
        }
      } else {
        if (header[0] != 77 || header[1] != 90) {
          throw const FormatException('更新安装包无效');
        }
        await binary.setPosition(bytes.getUint32(60, Endian.little));
        final pe = await binary.read(6);
        if (pe.length != 6 ||
            pe[0] != 80 ||
            pe[1] != 69 ||
            pe[2] != 0 ||
            pe[3] != 0 ||
            ByteData.sublistView(pe).getUint16(4, Endian.little) !=
                (release.arch == 'amd64' ? 0x8664 : 0xaa64)) {
          throw const FormatException('更新安装包无效');
        }
      }
    } finally {
      await binary.close();
    }
  }

  @override
  Future<void> discard(String archivePath) async {
    final work = path.dirname(archivePath);
    if (!_owned.remove(work)) return;
    if (_helpers.contains(work)) {
      // Keep cancellation/control files until the detached watcher sees them.
      for (final entry in [
        File(archivePath),
        Directory(path.join(work, 'stage')),
      ]) {
        if (entry.existsSync()) await entry.delete(recursive: true);
      }
    } else if (Directory(work).existsSync()) {
      await Directory(work).delete(recursive: true);
    }
  }

  String get _powershell => path.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );

  Future<ProcessResult> _run(String command, List<String> arguments) async {
    final process = await Process.start(command, arguments);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      process.kill();
      throw const FormatException('准备更新超时，请重试');
    }
    final result = ProcessResult(
      process.pid,
      exitCode,
      await stdout,
      await stderr,
    );
    if (exitCode != 0) throw const FormatException('无法准备更新安装包，请重试');
    return result;
  }
}

class _FilePendingUpdate implements PendingUpdate {
  _FilePendingUpdate(this.work);
  final Directory work;
  @override
  Future<void> commit() =>
      File(path.join(work.path, 'commit')).writeAsString('', flush: true);
  @override
  Future<void> cancel() =>
      File(path.join(work.path, 'cancel')).writeAsString('', flush: true);
}
