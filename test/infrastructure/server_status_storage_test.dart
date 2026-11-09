import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/infrastructure/ssh/server_status_parser.dart';

import '../support/server_status_fixture.dart';

String _section(String output, String name, String data) => output.replaceFirst(
  RegExp('PAGASHELL_STATUS_$name\\n[\\s\\S]*?(?=PAGASHELL_STATUS_)'),
  'PAGASHELL_STATUS_$name\n$data\n',
);

void main() {
  test('Linux 重复挂载只计一次，缺失拓扑的分区保持独立', () {
    final sample = parseServerStatus(
      _section(linuxStatusOutput, 'FILESYSTEMS', '''
/dev/sda1 1000 500 450 53% /
/dev/sda1 1000 500 450 53% /var/lib/container
/dev/sda2 2000 500 1500 25% /home
/dev/sdb1 3000 1000 2000 33% /data
'''),
    );
    // sda2 没有拓扑时不能猜父盘，补上拓扑的用例见下方。
    expect(sample.storage.first.id, 'sda');
    expect(sample.storage.first.total, 1000 * 1024);
    expect(sample.storage.first.filesystems, hasLength(2));
    expect(sample.storage.last.id, 'sdb');
  });

  test('Linux 无 lsblk 时仍利用设备别名合并 mapper 与 dm 挂载', () {
    final output = _section(
      _section(
        linuxStatusOutput,
        'LINUX_STORAGE',
        'PAGASHELL_STATUS_LINUX_DEVICE_ALIASES\n/dev/mapper/vg-root\t/dev/dm-0',
      ),
      'FILESYSTEMS',
      '''
/dev/mapper/vg-root 1000 500 400 56% /
/dev/dm-0 1000 500 400 56% /bind
''',
    );
    final sample = parseServerStatus(output);
    expect(sample.storage, hasLength(1));
    expect(sample.storage.single.id, 'dm-0');
    expect(sample.storage.single.total, 1000 * 1024);
    expect(sample.storage.single.filesystems, hasLength(2));
  });

  test('Linux 通过 mapper 别名追踪多级设备，将同盘各分区汇总', () {
    final topology = {
      'blockdevices': [
        {
          'name': '/dev/sda',
          'kname': '/dev/sda',
          'type': 'disk',
          'children': [
            {
              'name': '/dev/sda1',
              'kname': '/dev/sda1',
              'type': 'part',
              'uuid': 'boot',
            },
            {
              'name': '/dev/sda2',
              'kname': '/dev/sda2',
              'type': 'part',
              'children': [
                {
                  'name': '/dev/mapper/vg-root',
                  'kname': '/dev/dm-0',
                  'type': 'lvm',
                  'uuid': 'root',
                },
              ],
            },
          ],
        },
        {
          'name': '/dev/sdb',
          'kname': '/dev/sdb',
          'type': 'disk',
          'size': 8192000,
        },
      ],
    };
    final sample = parseServerStatus(
      _section(
        _section(linuxStatusOutput, 'LINUX_STORAGE', jsonEncode(topology)),
        'FILESYSTEMS',
        '''
/dev/sda1 1000 200 800 20% /boot
/dev/mapper/vg-root 3000 1000 2000 33% /
/dev/dm-0 3000 1000 2000 33% /var/lib/bind
''',
      ),
    );
    final disk = sample.storage.first;
    expect(disk.id, 'sda');
    expect(disk.total, 4000 * 1024);
    expect(disk.used, 1200 * 1024);
    expect(disk.filesystems, hasLength(3));
    final unmounted = sample.storage.last;
    expect(unmounted.id, 'sdb');
    expect(unmounted.total, 8192000);
    expect(unmounted.fraction, isNull);
  });

  test('跨盘共享 UUID 组成一个存储组，不能在两块物理盘重复计数', () {
    final sample = parseServerStatus(
      _section(
        _section(
          linuxStatusOutput,
          'LINUX_STORAGE',
          jsonEncode({
            'blockdevices': [
              for (final name in ['sda', 'sdb'])
                {
                  'name': name,
                  'kname': name,
                  'type': 'disk',
                  'children': [
                    {
                      'name': '${name}1',
                      'kname': '${name}1',
                      'type': 'part',
                      'uuid': 'shared-pool',
                    },
                  ],
                },
            ],
          }),
        ),
        'FILESYSTEMS',
        '''
/dev/sda1 4000 1000 3000 25% /
/dev/sdb1 4000 1000 3000 25% /data
''',
      ),
    );
    expect(sample.storage, hasLength(1));
    expect(sample.storage.single.devices, ['sda', 'sdb']);
    expect(sample.storage.single.total, 4000 * 1024);
    expect(sample.storage.single.fraction, .25);
  });

  test('可选拓扑与 Swap 缺失不会丢失 CPU 和内存采样', () {
    final sample = parseServerStatus(
      _section(linuxStatusOutput, 'LINUX_STORAGE', 'not json')
          .replaceFirst('SwapTotal: 524288 kB\nSwapFree: 393216 kB\n', '')
          .replaceFirst('x86_64\n', '')
          .replaceFirst('0.50 0.75 1.25 1/100 1000\n', ''),
    );
    expect(sample.memoryTotal, greaterThan(0));
    expect(sample.cpuTotal, 1000);
    expect(sample.architecture, isNull);
    expect(sample.loadAverage, isEmpty);
    expect(sample.swapFraction, isNull);
    expect(sample.storage.first.id, 'sda1');
    expect(sample.storage.first.total, sample.filesystems.first.total);
  });

  test('Swap 未启用与字段缺失分别为零和未知，支持 macOS G 单位', () {
    final linux = parseServerStatus(
      linuxStatusOutput
          .replaceFirst('SwapTotal: 524288', 'SwapTotal: 0')
          .replaceFirst('SwapFree: 393216', 'SwapFree: 0'),
    );
    expect(linux.swapTotal, 0);
    expect(linux.swapFraction, 0);
    final mac = parseServerStatus(
      _section(
        macStatusOutput,
        'MAC_SWAP',
        'total = 2.00G used = 0.50G free = 1.50G (encrypted)',
      ),
    );
    expect(mac.swapTotal, 2 * 1024 * 1024 * 1024);
    expect(mac.swapFraction, .25);
    expect(
      parseServerStatus(_section(macStatusOutput, 'MAC_SWAP', '')).swapFraction,
      isNull,
    );
  });

  test('macOS 排除磁盘镜像，共享容器容量不随挂载数量翻倍', () {
    final sample = parseServerStatus(
      _section(macStatusOutput, 'FILESYSTEMS', '''
/dev/disk3s1s1 1048576 65536 524288 12% /
/dev/disk3s2 1048576 400000 524288 43% /System/Volumes/Data
/dev/disk3s6 1048576 4 524288 1% /System/Volumes/VM
/dev/disk9s1 1048576 999999 1 100% /Volumes/Installer
'''),
    );
    expect(sample.storage.first.name, 'Macintosh HD');
    expect(sample.storage.first.total, 1073741824);
    expect(sample.storage.first.fraction, .5);
    expect(sample.storage.first.filesystems, hasLength(2));
    expect(sample.filesystems.map((fs) => fs.mount), [
      '/',
      '/System/Volumes/Data',
    ]);
  });

  test('macOS diskutil 不可用时保留容量并按系统 APFS 设备去重', () {
    var output = _section(macStatusOutput, 'MAC_STORAGE', '');
    output = _section(output, 'MAC_APFS', '');
    output = _section(output, 'FILESYSTEMS', '''
/dev/disk3s1s1 1000 20 400 5% /
/dev/disk3s2 1000 500 400 56% /System/Volumes/Data
''');
    final sample = parseServerStatus(output);
    expect(sample.storage, hasLength(1));
    expect(sample.storage.single.total, 1000 * 1024);
    expect(sample.storage.single.used, 600 * 1024);
    expect(sample.storage.single.filesystems, hasLength(2));
  });
}
