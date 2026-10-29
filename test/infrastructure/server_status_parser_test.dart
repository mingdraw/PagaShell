import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/server_status_parser.dart';

import '../support/server_status_fixture.dart';

void main() {
  test('macOS 使用第二次 CPU 采样，解析页内存、网卡和物理磁盘', () {
    final sample = parseServerStatus(macStatusOutput);
    final status = ServerStatus.fromSamples(sample, null);
    expect(sample.system, 'macOS');
    expect(sample.systemLabel, 'macOS 15.0.1');
    expect(status.cpuFraction, closeTo(.3, .0001));
    expect(sample.cpuCores.keys, [0, 1]);
    expect(sample.cpuCores[0]!.total, 1000);
    expect(status.cpuCores.values, everyElement(isNull));
    expect(sample.memoryFraction, .75);
    expect(sample.network.keys, ['en0', 'utun0']);
    expect(sample.network['en0']!.read, 4096);
    expect(sample.network['utun0']!.write, 512);
    expect(sample.disks.keys, ['disk0', 'disk4']);
    expect(sample.disks['disk0']!.read, 8192);
    expect(sample.disks['disk4']!.write, 512);
    expect(sample.filesystems.single.mount, '/');
    expect(sample.filesystems.single.name, 'Macintosh HD');
  });

  test('macOS 保留含空格及中文的磁盘名，名称缺失不影响容量解析', () {
    final renamed = parseServerStatus(
      macStatusOutput.replaceFirst('Macintosh HD', '开发磁盘 SSD'),
    );
    expect(renamed.filesystems.single.name, '开发磁盘 SSD');
    final unnamed = parseServerStatus(
      macStatusOutput.replaceFirst('Macintosh HD\n', ''),
    );
    expect(unnamed.filesystems.single.name, isNull);
    expect(unnamed.filesystems.single.fraction, .5);
  });

  test('macOS 只显示系统磁盘，按共享剩余空间计算占用而非仅系统卷用量', () {
    final sample = parseServerStatus(
      macStatusOutput.replaceFirst(
        '/dev/disk3s1s1 1048576 524288 524288 50% /',
        '/dev/disk3s6 1048576 4 262144 1% /System/Volumes/VM\n'
            '/dev/disk3s1s1 1048576 65536 262144 20% /\n'
            '/dev/disk3s2 1048576 458752 262144 64% /System/Volumes/Data\n'
            '/dev/disk4s1 2097152 1048576 1048576 50% /Volumes/External',
      ),
    );
    final disk = sample.filesystems.single;
    expect(disk.mount, '/');
    expect(disk.total, 1048576 * 1024);
    expect(disk.used, 786432 * 1024);
    expect(disk.available, 262144 * 1024);
    expect(disk.fraction, .75);
  });

  test('macOS 系统磁盘数据缺失时不拿辅助卷代替', () {
    final sample = parseServerStatus(
      macStatusOutput.replaceFirst(
        '/dev/disk3s1s1 1048576 524288 524288 50% /',
        '/dev/disk3s6 1048576 4 262144 1% /System/Volumes/VM',
      ),
    );
    expect(sample.filesystems, isEmpty);
  });

  const liveSample = String.fromEnvironment('PAGASHELL_STATUS_SAMPLE');
  const previousLiveSample = String.fromEnvironment(
    'PAGASHELL_STATUS_PREVIOUS_SAMPLE',
  );
  test('真实 macOS 脚本样本可解析全部指标', () {
    final sample = parseServerStatus(File(liveSample).readAsStringSync());
    expect(sample.system, 'macOS');
    expect(sample.measuredCpuFraction, inInclusiveRange(0, 1));
    expect(sample.memoryTotal, greaterThan(0));
    expect(sample.network, isNotEmpty);
    expect(sample.disks, isNotEmpty);
    expect(sample.filesystems.single.mount, '/');
    expect(sample.cpuCores, isNotEmpty);
    if (previousLiveSample.isNotEmpty) {
      final previous = parseServerStatus(
        File(previousLiveSample).readAsStringSync(),
      );
      final cores = ServerStatus.fromSamples(sample, previous).cpuCores;
      expect(cores.values.whereType<double>(), isNotEmpty);
      expect(
        cores.values.whereType<double>(),
        everyElement(inInclusiveRange(0, 1)),
      );
    }
  }, skip: liveSample.isEmpty);
  test('Linux 采样解析内存、挂载点、网卡和整盘扇区，CPU 不重复计算 guest', () {
    final sample = parseServerStatus(linuxStatusOutput);
    expect(sample.systemLabel, 'Ubuntu 24.04');
    expect(sample.uptimeSeconds, 1000.5);
    expect(sample.cpuTotal, 1000);
    expect(sample.cpuIdle, 810);
    expect(sample.cpuCores.keys, [0, 1]);
    expect(sample.cpuCores[0]!.total, 500);
    expect(sample.cpuCores[0]!.idle, 405);
    expect(sample.memoryTotal, 1024 * 1024 * 1024);
    expect(sample.memoryFraction, .75);
    expect(sample.network.keys, ['eth0']);
    expect(sample.network['eth0']!.read, 4096);
    expect(sample.network['eth0']!.write, 2048);
    expect(sample.disks['nvme0n1']!.read, 51200);
    expect(sample.disks['nvme0n1']!.write, 102400);
    expect(sample.filesystems.last.mount, '/data with spaces');
    expect(sample.filesystems.first.fraction, closeTo(1 / 1.9, .0001));
  });

  test('系统版本缺失时保留系统名，并兼容发行版引号与转义', () {
    expect(
      parseServerStatus(
        linuxStatusOutput.replaceFirst(
          'NAME="Ubuntu"\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n',
          '',
        ),
      ).systemLabel,
      'Linux',
    );
    expect(
      parseServerStatus(macStatusOutput.replaceFirst('15.0.1\n', ''))
          .systemLabel,
      'macOS',
    );
    expect(
      parseServerStatus(
        linuxStatusOutput.replaceFirst(
          'NAME="Ubuntu"',
          "NAME='Debian GNU/Linux'",
        ),
      ).systemLabel,
      'Debian GNU/Linux 24.04',
    );
    expect(
      parseServerStatus(
        linuxStatusOutput.replaceFirst(
          'NAME="Ubuntu"\nVERSION_ID="24.04"\n',
          '',
        ),
      ).systemLabel,
      'Ubuntu 24.04 LTS',
    );
    expect(
      parseServerStatus(
        linuxStatusOutput.replaceFirst(
          'NAME="Ubuntu"',
          r'NAME="Test \"Linux\""',
        ),
      ).systemLabel,
      'Test "Linux" 24.04',
    );
  });

  test('macOS 核心使用相邻计数计算占用，保持 top 汇总占用独立', () {
    final first = parseServerStatus(macStatusOutput);
    final next = parseServerStatus(
      macStatusOutput
          .replaceFirst('cpu0 1000 800', 'cpu0 1100 820')
          .replaceFirst('cpu1 1200 900', 'cpu1 1300 970')
          .replaceFirst('\n1000\n', '\n1003\n'),
    );
    final status = ServerStatus.fromSamples(next, first);
    expect(status.cpuCores[0], .8);
    expect(status.cpuCores[1], .3);
    expect(status.cpuFraction, closeTo(.3, .0001));
  });

  test('缺失或异常核心数据不影响汇总和其它指标', () {
    final legacy = parseServerStatus(
      linuxStatusOutput.replaceAll(RegExp(r'cpu\d+ [^\n]*\n'), ''),
    );
    expect(legacy.cpuCores, isEmpty);
    expect(legacy.cpuTotal, 1000);
    final linux = parseServerStatus(
      linuxStatusOutput.replaceFirst(
        'PAGASHELL_STATUS_MEMORY',
        'cpu2 1 2\ncpu3 1 2 x 4\ncpu4 -1 2 3 4\nPAGASHELL_STATUS_MEMORY',
      ),
    );
    expect(linux.cpuCores.keys, [0, 1]);
    final mac = parseServerStatus(
      macStatusOutput.replaceFirst(
        'cpu0 1000 800\ncpu1 1200 900',
        'cpu0 invalid 800\ncpu1 100 200\ncpu2 -1 0',
      ),
    );
    expect(mac.cpuCores, isEmpty);
    expect(mac.measuredCpuFraction, closeTo(.3, .0001));
    expect(mac.memoryFraction, .75);
    expect(
      parseServerStatus(
        macStatusOutput.replaceFirst(
          'PAGASHELL_STATUS_MAC_CPU_CORES\ncpu0 1000 800\ncpu1 1200 900\n',
          '',
        ),
      ).cpuCores,
      isEmpty,
    );
  });

  test('核心按编号匹配和排序，新增核心先建立基线，移除核心不保留', () {
    final first = statusSample(
      cpuCores: {
        0: const CpuCounters(1000, 800),
        1: const CpuCounters(2000, 1500),
        2: const CpuCounters(1000, 800),
      },
    );
    expect(
      ServerStatus.fromSamples(first, null).cpuCores.values,
      everyElement(isNull),
    );
    final next = ServerStatus.fromSamples(
      statusSample(
        uptime: 1003,
        cpuCores: {
          1: const CpuCounters(2200, 1550),
          0: const CpuCounters(1100, 820),
          4: const CpuCounters(200, 100),
        },
      ),
      first,
    );
    expect(next.cpuCores.keys, [0, 1, 4]);
    expect(next.cpuCores[0], .8);
    expect(next.cpuCores[1], .75);
    expect(next.cpuCores[4], isNull);
  });

  test('核心计数重置、零增量和异常 idle 不产生错误占比', () {
    final first = statusSample(
      cpuCores: {
        for (var id = 0; id < 6; id++) id: const CpuCounters(1000, 800),
      },
    );
    final counters = {
      0: const CpuCounters(1000, 800),
      1: const CpuCounters(10, 8),
      2: const CpuCounters(1100, 700),
      3: const CpuCounters(1100, 950),
      4: const CpuCounters(1100, 800),
      5: const CpuCounters(1100, 900),
    };
    final next = ServerStatus.fromSamples(
      statusSample(uptime: 1003, cpuCores: counters),
      first,
    );
    expect(next.cpuCores.values.take(4), everyElement(isNull));
    expect(next.cpuCores[4], 1);
    expect(next.cpuCores[5], 0);
    for (final uptime in [10.0, 1000.0]) {
      expect(
        ServerStatus.fromSamples(
          statusSample(uptime: uptime, cpuCores: counters),
          first,
        ).cpuCores.values,
        everyElement(isNull),
      );
    }
  });

  test('旧内核缺少 MemAvailable 时扣除可回收缓存，不把全部缓存当成已用', () {
    final sample = parseServerStatus(
      linuxStatusOutput.replaceFirst('MemAvailable: 262144 kB\n', ''),
    );
    expect(sample.memoryAvailable, (102400 + 1024 + 4096) * 1024);
  });

  test('不支持的系统及截断输出显示采集错误', () {
    expect(
      () => parseServerStatus('PAGASHELL_STATUS_OS\nFreeBSD\n'),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          '服务状态仅支持 Linux 和 macOS',
        ),
      ),
    );
    expect(
      () => parseServerStatus(
        linuxStatusOutput.replaceFirst('PAGASHELL_STATUS_END', ''),
      ),
      throwsA(isA<SshEngineException>()),
    );
  });

  test('CPU、网络和磁盘速率按远端采样间隔计算，首次采样为空', () {
    final first = statusSample();
    final initial = ServerStatus.fromSamples(first, null);
    expect(initial.cpuFraction, isNull);
    expect(initial.network['eth0']!.readPerSecond, isNull);
    final next = ServerStatus.fromSamples(
      statusSample(
        uptime: 1004,
        cpu: 1400,
        idle: 1000,
        read: 8192,
        write: 6144,
      ),
      first,
    );
    expect(next.cpuFraction, .5);
    expect(next.network['eth0']!.readPerSecond, 1024);
    expect(next.network['eth0']!.writePerSecond, 1024);
    expect(next.disks['nvme0n1']!.readPerSecond, 2048);
  });

  test('服务器重启、设备计数回退或新设备不产生负速率', () {
    final before = statusSample();
    final reboot = ServerStatus.fromSamples(
      statusSample(uptime: 10, cpu: 100, idle: 80, read: 0, write: 0),
      before,
    );
    expect(reboot.cpuFraction, isNull);
    expect(reboot.disks['nvme0n1']!.readPerSecond, isNull);
    final reset = ServerStatus.fromSamples(
      statusSample(uptime: 1003, read: 1, write: 1),
      before,
    );
    expect(reset.network['eth0']!.writePerSecond, isNull);
  });
}
