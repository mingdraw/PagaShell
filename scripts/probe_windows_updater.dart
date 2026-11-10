import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows is required for the updater launch probe.');
    return;
  }
  final powershell =
      '${Platform.environment['SystemRoot']}'
      r'\System32\WindowsPowerShell\v1.0\powershell.exe';
  for (final mode in const [
    ProcessStartMode.normal,
    ProcessStartMode.detached,
    ProcessStartMode.detachedWithStdio,
  ]) {
    for (final hidden in [true, false]) {
      final root = await Directory.systemTemp.createTemp(
        "pagashell launch ' 测试 ",
      );
      final script = await File('assets/updater/install_windows.ps1')
          .copy('${root.path}\\install_windows.ps1');
      final config = File('${root.path}\\install.json');
      await config.writeAsString(
        jsonEncode({
          'source': '${root.path}\\stage\\bundle',
          'target': '${root.path}\\installed app',
          'work': root.path,
          'parentPid': pid,
          'requiresAdmin': false,
          'archive': '${root.path}\\fixture.zip',
          'stage': '${root.path}\\stage',
          'prefix': 'bundle',
        }),
      );
      final output = <String>[];
      Process? child;
      final timer = Stopwatch()..start();
      try {
        child = await Process.start(
          powershell,
          [
            '-NoProfile',
            '-NonInteractive',
            if (hidden) ...['-WindowStyle', 'Hidden'],
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            script.path,
            '-Mode',
            'Watch',
            '-ConfigPath',
            config.path,
          ],
          workingDirectory: root.path,
          mode: mode,
        );
        if (mode != ProcessStartMode.detached) {
          for (final stream in [child.stdout, child.stderr]) {
            stream
                .transform(const Utf8Decoder(allowMalformed: true))
                .listen(
                  output.add,
                  onError: (Object error) => output.add('$error'),
                );
          }
        }
        final ready = File('${root.path}\\ready');
        while (!ready.existsSync() && timer.elapsed.inSeconds < 8) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        stdout.writeln(
          jsonEncode({
            'mode': '$mode',
            'hidden': hidden,
            'ready': ready.existsSync(),
            'elapsedMs': timer.elapsedMilliseconds,
            'output': output.join(),
            'helperLog': File('${root.path}\\helper.log').existsSync()
                ? await File('${root.path}\\helper.log').readAsString()
                : null,
          }),
        );
      } finally {
        await File('${root.path}\\cancel').writeAsString('');
        if (child != null) {
          if (mode != ProcessStartMode.detached) await child.stdin.close();
          if (mode == ProcessStartMode.normal) {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            child.kill();
          }
        }
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // The runner's temporary directory cleanup can remove held files.
        }
      }
    }
  }
}
