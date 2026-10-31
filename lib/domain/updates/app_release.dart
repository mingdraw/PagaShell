/// GitHub 稳定版标签；按数值比较，构建号不参与版本升级判断。
class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(this.major, this.minor, this.patch, {this.prerelease = false});

  factory ReleaseVersion.parse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('更新版本号无效');
    return ReleaseVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      prerelease: match[4] != null,
    );
  }

  final int major;
  final int minor;
  final int patch;
  final bool prerelease;

  @override
  int compareTo(ReleaseVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final comparison = pair.$1.compareTo(pair.$2);
      if (comparison != 0) return comparison;
    }
    return prerelease == other.prerelease ? 0 : (prerelease ? -1 : 1);
  }
}

enum UpdatePlatform { macos, windows, linux }

class InstalledApplication {
  const InstalledApplication({
    required this.version,
    required this.platform,
    required this.arch,
  });
  final String version;
  final UpdatePlatform platform;
  final String arch;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assetName,
    required this.downloadUrl,
    required this.size,
    required this.sha256,
    required this.platform,
    required this.arch,
  });

  factory AppRelease.fromGitHub(
    Map<String, dynamic> json,
    InstalledApplication app,
  ) {
    final tag = json['tag_name'];
    if (tag is! String ||
        !tag.startsWith('v') ||
        json['draft'] != false ||
        json['prerelease'] != false) {
      throw const FormatException('更新信息无效');
    }
    final version = ReleaseVersion.parse(tag);
    if (version.prerelease) throw const FormatException('更新信息无效');
    if (!['amd64', 'arm64'].contains(app.arch)) {
      throw const FormatException('当前处理器架构不支持自动更新');
    }
    final extension = switch (app.platform) {
      UpdatePlatform.macos => 'dmg',
      UpdatePlatform.windows => 'zip',
      UpdatePlatform.linux => 'tar.gz',
    };
    final name = 'pagashell_${tag}_${app.platform.name}_${app.arch}.$extension';
    final assets = json['assets'];
    if (assets is! List) throw const FormatException('更新安装包不可用');
    final matches = assets
        .whereType<Map<String, dynamic>>()
        .where((asset) => asset['name'] == name)
        .toList();
    if (matches.length != 1) throw const FormatException('更新安装包不可用');
    final asset = matches.single;
    final expected =
        'https://github.com/mingdraw/PagaShell/releases/download/$tag/$name';
    final digest = asset['digest'];
    final size = asset['size'];
    if (asset['browser_download_url'] != expected ||
        asset['state'] != 'uploaded' ||
        digest is! String ||
        !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        size > 2 * 1024 * 1024 * 1024) {
      throw const FormatException('更新安装包校验信息无效');
    }
    return AppRelease(
      version: tag.substring(1),
      tag: tag,
      notes: json['body'] is String
          ? (json['body'] as String).substring(
              0,
              (json['body'] as String).length.clamp(0, 16000),
            )
          : '',
      assetName: name,
      downloadUrl: Uri.parse(expected),
      size: size,
      sha256: digest.substring(7).toLowerCase(),
      platform: app.platform,
      arch: app.arch,
    );
  }

  final String version;
  final String tag;
  final String notes;
  final String assetName;
  final Uri downloadUrl;
  final int size;
  final String sha256;
  final UpdatePlatform platform;
  final String arch;
}
