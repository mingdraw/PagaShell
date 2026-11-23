import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/infrastructure/ssh/server_profile_parser.dart';

void main() {
  for (final (id, name, manager, init) in [
    ('ubuntu', 'Ubuntu 24.04 LTS', 'apt-get', 'systemd'),
    ('rhel', 'Red Hat Enterprise Linux', 'dnf', 'systemd'),
    ('alpine', 'Alpine Linux', 'apk', 'openrc'),
  ]) {
    test(
      '$id profile distinguishes disk media, limits and installed services',
      () {
        final profile = parseServerProfile('''
system=Linux
PRETTY_NAME="$name"
ID=$id
kernel=6.8.0
architecture=x86_64
package=$manager
init=$init
privilege=sudo_noninteractive
cpu_cores=8
memory_bytes=17179869184
nofile_soft=1024
nofile_hard=65535
disk=nvme0n1|128000000000|0
disk=sda|1000000000000|1
sysctl.fs.nr_open=1048576
service=mysqld|8.0 test|active
''');
        expect(profile.distribution, name);
        expect(profile.distributionId, id);
        expect(profile.packageManagers, [manager]);
        expect(profile.initSystem, init);
        expect(profile.cpuCores, 8);
        expect(profile.memoryBytes, 17179869184);
        expect(profile.softOpenFiles, '1024');
        expect(profile.disks.map((disk) => disk.rotational), [false, true]);
        expect(profile.sysctl['fs.nr_open'], '1048576');
        expect(profile.services.single.status, 'active');
      },
    );
  }

  test('macOS profile handles swap and unavailable Linux-specific fields', () {
    final profile = parseServerProfile('''
system=Darwin
PRETTY_NAME=macOS
VERSION_ID=15.4
init=launchd
architecture=arm64
package=brew
swap_usage=total = 1024.00M  used = 32.00M  free = 992.00M  (encrypted)
''');
    expect(profile.system, 'Darwin');
    expect(profile.swapBytes, 1024 * 1024 * 1024);
    expect(profile.swapFreeBytes, 992 * 1024 * 1024);
    expect(profile.softOpenFiles, isNull);
    expect(profile.disks, isEmpty);
  });
}
