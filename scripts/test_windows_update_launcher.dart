import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pagashell/infrastructure/updates/windows_update_launcher.dart';

String get _powershell =>
    '${Platform.environment['SystemRoot']}'
    r'\System32\WindowsPowerShell\v1.0\powershell.exe';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stdout.writeln('SKIP: Windows native updater launch tests.');
    return;
  }
  if (arguments.isNotEmpty && arguments.first == '--parent') {
    final fixture = _Fixture(Directory(arguments[1]));
    await fixture.writeConfig(parentPid: pid);
    await fixture.start();
    await fixture.file('commit').writeAsString('');
    return;
  }
  await _run('cancel before commit preserves the installation', (
    fixture,
  ) async {
    await fixture.start();
    await fixture.file('cancel').writeAsString('');
    _check(await fixture.version() == 'old', 'Cancellation changed the app.');
  });
  await _run('cancel revokes commit before the app exits', (fixture) async {
    await fixture.start();
    await fixture.file('commit').writeAsString('');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _check(await fixture.version() == 'old', 'Updated while app was running.');
    await fixture.file('cancel').writeAsString('');
  });
  await _run('startup errors are logged and installation is retained', (
    fixture,
  ) async {
    await fixture.script.writeAsString(
      'param([string]\$Mode, [string]\$ConfigPath)\n'
      "throw 'fixture startup failure'\n",
    );
    try {
      await fixture.start(readyTimeout: const Duration(seconds: 4));
      throw StateError('A failed watcher was accepted.');
    } on FormatException catch (error) {
      _check(error.message == '无法启动更新安装程序，请重试', '$error');
    }
    _check(fixture.file('cancel').existsSync(), 'Missing cancellation.');
    final error = await fixture.file('watcher.stderr.log').readAsString();
    _check(error.contains('fixture startup failure'), 'Lost startup error.');
    _check(
      await fixture.version() == 'old',
      'Startup failure changed the app.',
    );
  });
  await _run('watcher survives app exit, installs and restarts', (
    fixture,
  ) async {
    const program =
        'using System; using System.IO; public class Fixture { '
        'public static void Main() { File.WriteAllText(Path.Combine('
        'AppDomain.CurrentDomain.BaseDirectory, "launched"), "ok"); }}';
    final executable = File('${fixture.source.path}\\pagashell.exe');
    final compilation = await Process.run(_powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "\$ErrorActionPreference = 'Stop'; Add-Type -TypeDefinition '$program' "
          '-OutputAssembly ${_quote(executable.path)} '
          '-OutputType WindowsApplication',
    ]);
    _check(compilation.exitCode == 0, '${compilation.stderr}');
    final parent = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      '--parent',
      fixture.root.path,
    ]);
    final output = Future.wait([
      parent.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      parent.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
    ]);
    await parent.stdin.close();
    try {
      final code = await parent.exitCode.timeout(const Duration(seconds: 25));
      _check(code == 0, (await output).join('\n'));
      await fixture.waitFor(fixture.file('complete'));
      await fixture.waitFor(File('${fixture.target.path}\\launched'));
      _check(await fixture.version() == 'new', 'Update was not installed.');
      _check(
        await File('${fixture.target.path}.pagashell-backup\\version')
                .readAsString() ==
            'old',
        'Missing original installation backup.',
      );
    } finally {
      parent.kill();
    }
  });
}

Future<void> _run(String name, Future<void> Function(_Fixture) test) async {
  final root = await Directory.systemTemp.createTemp("pagashell update ' 测试 ");
  final fixture = _Fixture(root);
  try {
    await fixture.setUp();
    await test(fixture);
    stdout.writeln('PASS: $name');
  } catch (error) {
    stderr.writeln('FAIL: $name\n$error\n${await fixture.logs()}');
    rethrow;
  } finally {
    await fixture.dispose();
  }
}

class _Fixture {
  _Fixture(this.root);

  final Directory root;
  Directory get work => Directory('${root.path}\\work');
  Directory get source => Directory('${work.path}\\stage\\bundle');
  Directory get target => Directory('${root.path}\\installed app');
  File get script => file('install_windows.ps1');
  File get config => file('install.json');
  File file(String name) => File('${work.path}\\$name');

  Future<void> setUp() async {
    await source.create(recursive: true);
    await target.create();
    await File('${target.path}\\version').writeAsString('old');
    await File('${source.path}\\version').writeAsString('new');
    await File('assets/updater/install_windows.ps1').copy(script.path);
    await file('fixture.zip').writeAsString('fixture archive');
    await writeConfig(parentPid: pid);
  }

  Future<void> writeConfig({required int parentPid}) => config.writeAsString(
    jsonEncode({
      'source': source.path,
      'target': target.path,
      'work': work.path,
      'parentPid': parentPid,
      'requiresAdmin': false,
      'archive': file('fixture.zip').path,
      'stage': '${work.path}\\stage',
      'prefix': 'bundle',
    }),
  );

  Future<void> start({Duration readyTimeout = const Duration(seconds: 20)}) =>
      startWindowsUpdateHelper(
        powershell: _powershell,
        script: script,
        config: config,
        work: work,
        readyTimeout: readyTimeout,
      );

  Future<String> version() => File('${target.path}\\version').readAsString();

  Future<void> waitFor(File result) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!result.existsSync()) {
      if (file('error').existsSync() || DateTime.now().isAfter(deadline)) {
        throw StateError('Missing ${result.path}\n${await logs()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<String> logs() async => [
    for (final name in [
      'launcher.log',
      'watcher.stdout.log',
      'watcher.stderr.log',
      'helper.log',
      'error',
    ])
      if (file(name).existsSync()) '$name: ${await file(name).readAsString()}',
  ].join('\n');

  Future<void> dispose() async {
    await file('cancel').writeAsString('');
    if (file('watcher.pid').existsSync()) {
      final watcher = int.parse(
        (await file('watcher.pid').readAsString()).trim(),
      );
      // Keep the cancellation marker until the watcher has closed its log
      // handles. A partial recursive delete can otherwise remove it too soon.
      final result = await Process.run(_powershell, [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$watcher = Get-Process -Id $watcher -ErrorAction SilentlyContinue; '
            'if (\$null -ne \$watcher -and -not \$watcher.WaitForExit(10000)) '
            "{ throw 'Watcher did not exit after cancellation' }; exit 0",
      ]);
      _check(result.exitCode == 0, '${result.stderr}');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

String _quote(String value) => "'${value.replaceAll("'", "''")}'";

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
