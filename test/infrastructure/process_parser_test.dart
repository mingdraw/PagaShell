import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/process_parser.dart';

import '../support/process_fixture.dart';

String _table(
  String rows, {
  String time = '1000.25',
  String memory = '1073741824',
}) =>
    '''
login banner
PAGA_PROCESSES_V1
TIME $time
MEMORY $memory
PROCESSES
$rows
PAGA_PROCESSES_END
''';

String _details({String path = '/usr/bin/worker'}) =>
    'PAGA_PROCESS_DETAILS_V1\n'
    '42 12 rocky 125.5 9.8 102400 2097152 S+ -5 1-02:03:04 3:02.57 '
    'Fri Nov 6 14:20:00 2026 worker\n'
    'PAGA_PROCESS_PATH\x00$path\x00\nPAGA_PROCESS_DETAILS_END\n';

void main() {
  test('单进程详情解析资源、父进程、状态和路径，路径不混入列表', () {
    for (final path in [
      '/usr/bin/worker (deleted)',
      '/Applications/My App.app/Contents/MacOS/My\nApp\tFile',
    ]) {
      final details = parseProcessDetails(
        _details(path: path),
        remoteProcess(),
      );
      expect(details.process.pid, 42);
      expect(details.process.name, 'worker');
      expect(details.process.cpuPercent, 125.5);
      expect(details.process.cpuSeconds, closeTo(182.57, .001));
      expect(details.process.memoryBytes, 104857600);
      expect(details.parentPid, 12);
      expect(details.state, 'S+');
      expect(details.nice, -5);
      expect(details.elapsed, '1-02:03:04');
      expect(details.memoryPercent, 9.8);
      expect(details.virtualMemoryBytes, 2147483648);
      expect(
        details.executablePath,
        path.replaceAll('\n', '�').replaceAll('\t', '�'),
      );
    }
  });

  test('单进程路径不可读仍展示详情，拒绝截断、非法数据及PID复用', () {
    for (final path in ['', 'worker']) {
      expect(
        parseProcessDetails(
          _details(path: path),
          remoteProcess(),
        ).executablePath,
        isNull,
      );
    }
    for (final output in [
      '',
      _details().replaceAll('PAGA_PROCESS_DETAILS_END', ''),
      _details().replaceAll(
        '\x00\nPAGA_PROCESS_DETAILS_END',
        '\nPAGA_PROCESS_DETAILS_END',
      ),
      _details().replaceAll('125.5', 'NaN'),
      _details(path: '/usr/bin/worker\x00junk'),
    ]) {
      expect(
        () => parseProcessDetails(output, remoteProcess()),
        throwsA(isA<SshEngineException>()),
      );
    }
    for (final expected in [
      remoteProcess(pid: 81),
      remoteProcess(startedAt: 'Fri Nov 6 14:21:00 2026'),
    ]) {
      expect(
        () => parseProcessDetails(_details(), expected),
        throwsA(
          isA<SshEngineException>().having(
            (e) => e.message,
            'message',
            '进程已变化，请刷新后重试',
          ),
        ),
      );
    }
  });

  test('解析 Linux 的天数 CPU 时间、RSS 字节及带空格的名称', () {
    final snapshot = parseProcesses(
      _table('''
   42 rocky 125.5 102400 2-01:02:03 Fri Nov  6 14:20:00 2026 /usr/bin/CPU Worker
   81 root 0.0 0 00:00:00 Fri Nov  6 14:21:00 2026 [kernel]
'''),
    );
    expect(snapshot.sampledAtSeconds, 1000.25);
    expect(snapshot.memoryTotal, 1073741824);
    final first = snapshot.processes.first;
    expect(first.pid, 42);
    expect(first.name, '/usr/bin/CPU Worker');
    expect(first.user, 'rocky');
    expect(first.startedAt, 'Fri Nov 6 14:20:00 2026');
    expect(first.memoryBytes, 104857600);
    expect(first.cpuSeconds, 176523);
    expect(first.cpuPercent, 125.5);
  });

  test('解析 macOS 的小数 CPU 时间、长进程路径和百分比', () {
    final snapshot = parseProcesses(
      _table('''
42 user 12.3 2048 3:02.57 Fri Nov  6 14:20:00 2026 /Applications/My App.app/Contents/MacOS/My App
81 user 0.0 1024 10:01:02.10 Fri Nov  6 14:21:00 2026 launchd
'''),
    );
    expect(snapshot.processes.first.cpuSeconds, closeTo(182.57, .001));
    expect(snapshot.processes.last.cpuSeconds, closeTo(36062.1, .001));
    expect(snapshot.processes.first.name, endsWith('/My App'));
  });

  test('不完整的行和重复 PID 不阻断有效数据，拒绝截断和错误协议', () {
    const row = '42 rocky 1.0 1024 0:01.00 Fri Nov 6 14:20:00 2026 worker';
    expect(
      parseProcesses(_table('broken\n$row\n$row')).processes,
      hasLength(1),
    );
    expect(parseProcesses(_table('')).processes, isEmpty);
    for (final output in [
      '',
      _table(row).replaceAll('PAGA_PROCESSES_END', ''),
      _table('broken'),
      _table(row, time: 'NaN'),
      _table(row, memory: '0'),
    ]) {
      expect(() => parseProcesses(output), throwsA(isA<SshEngineException>()));
    }
    expect(
      () => parseProcesses(
        'PAGA_PROCESSES_V1\nUNSUPPORTED\nPAGA_PROCESSES_END\n',
      ),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          '进程管理仅支持 Linux 和 macOS',
        ),
      ),
    );
  });

  test('CPU 用相邻样本增量，多核可超过 100%，PID 复用及计数重置重新取基线', () {
    final first = processSnapshot(
      processes: [remoteProcess(seconds: 10, cpu: 1)],
    );
    final next = processSnapshot(
      time: 1003,
      processes: [remoteProcess(seconds: 16, cpu: 2)],
    );
    final usage = ProcessUsage.fromSamples(next, first).single;
    expect(usage.cpuPercent, 200);
    expect(usage.memoryPercent, closeTo(9.765625, .001));
    expect(ProcessUsage.fromSamples(next, null).single.cpuPercent, 2);
    final reused = processSnapshot(
      time: 1006,
      processes: [
        remoteProcess(
          seconds: 20,
          cpu: 3,
          startedAt: 'Fri Nov 6 14:22:00 2026',
        ),
      ],
    );
    expect(ProcessUsage.fromSamples(reused, next).single.cpuPercent, 3);
    expect(ProcessUsage.fromSamples(first, next).single.cpuPercent, 1);
  });
}
