import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/updates/app_release.dart';

import '../support/update_fixtures.dart';

void main() {
  test('版本按数值比较，忽略构建号，正式版高于同号预览版', () {
    expect(
      ReleaseVersion.parse('0.10.0').compareTo(ReleaseVersion.parse('v0.9.9')),
      greaterThan(0),
    );
    expect(
      ReleaseVersion.parse('0.2.1+4')
          .compareTo(ReleaseVersion.parse('0.2.1+99')),
      0,
    );
    expect(
      ReleaseVersion.parse('v0.2.1')
          .compareTo(ReleaseVersion.parse('0.2.1-rc.1')),
      greaterThan(0),
    );
    for (final invalid in ['latest', 'v1.2', '01.2.3', '1.2.3/../../file']) {
      expect(() => ReleaseVersion.parse(invalid), throwsFormatException);
    }
  });

  for (final platform in UpdatePlatform.values) {
    for (final arch in ['amd64', 'arm64']) {
      test('精确选择 ${platform.name} $arch 完整安装包', () {
        final release = AppRelease.fromGitHub(
          releaseJson(),
          InstalledApplication(
            version: '0.2.1',
            platform: platform,
            arch: arch,
          ),
        );
        expect(release.assetName, assetName('0.3.0', platform, arch));
        expect(release.version, '0.3.0');
        expect(release.sha256, hasLength(64));
      });
    }
  }

  test('拒绝预发布、草稿、缺包、重复包和错误的校验信息', () {
    const installed = InstalledApplication(
      version: '0.2.1',
      platform: UpdatePlatform.macos,
      arch: 'amd64',
    );
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (json) => json['draft'] = true,
      (json) => json['prerelease'] = true,
      (json) => json['tag_name'] = 'v0.3.0-rc.1',
      (json) => json['assets'] = <dynamic>[],
      (json) => (json['assets'] as List).add((json['assets'] as List).first),
      (json) => ((json['assets'] as List).first as Map).remove('digest'),
      (json) => ((json['assets'] as List).first as Map)['size'] = 0,
      (json) => ((json['assets'] as List).first as Map)['state'] = 'new',
      (json) =>
          ((json['assets'] as List).first as Map)['browser_download_url'] =
              'https://example.test/update.dmg',
    ]) {
      final json = releaseJson();
      mutation(json);
      expect(
        () => AppRelease.fromGitHub(json, installed),
        throwsFormatException,
      );
    }
  });
}
