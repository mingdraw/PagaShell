import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Start the watcher with its own standard handles so Windows PowerShell can
/// initialize and keep running after the application's Dart isolate exits.
Future<void> startWindowsUpdateHelper({
  required String powershell,
  required File script,
  required File config,
  required Directory work,
  Duration readyTimeout = const Duration(seconds: 20),
}) async {
  final launcherLog = File.fromUri(work.uri.resolve('launcher.log'));
  final stdoutLog = File.fromUri(work.uri.resolve('watcher.stdout.log'));
  final stderrLog = File.fromUri(work.uri.resolve('watcher.stderr.log'));
  final watcherPid = File.fromUri(work.uri.resolve('watcher.pid'));
  final ready = File.fromUri(work.uri.resolve('ready'));
  final cancel = File.fromUri(work.uri.resolve('cancel'));
  final watchCommand =
      '& ${_quote(script.path)} -Mode Watch -ConfigPath ${_quote(config.path)}';
  final bootstrap =
      '''
\$ErrorActionPreference = 'Stop'
\$child = Start-Process -FilePath ${_quote(powershell)} -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-EncodedCommand', '${_encodeCommand(watchCommand)}'
) -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput ${_quote(stdoutLog.path)} `
  -RedirectStandardError ${_quote(stderrLog.path)}
\$child.Id | Set-Content -LiteralPath ${_quote(watcherPid.path)} -Encoding ASCII
''';
  Process? process;
  final output = StringBuffer();
  final subscriptions = <StreamSubscription<String>>[];
  try {
    // Dart's DETACHED_PROCESS mode prevents Windows PowerShell from reaching
    // the script on Windows. The short bootstrap uses normal handles, and
    // Start-Process gives the independent watcher file handles for its output.
    process = await Process.start(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      _encodeCommand(bootstrap),
    ], workingDirectory: work.path);
    for (final stream in [process.stdout, process.stderr]) {
      subscriptions.add(
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(
              output.write,
              onError: (Object error) => output.writeln(error),
            ),
      );
    }
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(readyTimeout);
    // Descendants may inherit a duplicate of the bootstrap's pipe handles.
    // Its exit code is sufficient: waiting for pipe EOF waits for the watcher
    // itself, which is waiting for this application's commit and exit.
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    subscriptions.clear();
    await launcherLog.writeAsString(
      'Bootstrap exit code: $exitCode\n$output',
      flush: true,
    );
    if (exitCode != 0) {
      throw const FormatException('无法启动更新安装程序，请重试');
    }
    final deadline = DateTime.now().add(readyTimeout);
    while (!ready.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw const FormatException('无法启动更新安装程序，请重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } on Object catch (error) {
    process?.kill();
    await cancel.writeAsString('', flush: true);
    await launcherLog.writeAsString(
      '\n$error\n',
      mode: FileMode.append,
      flush: true,
    );
    if (error is FormatException) rethrow;
    throw const FormatException('无法启动更新安装程序，请重试');
  } finally {
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}

String _quote(String value) => "'${value.replaceAll("'", "''")}'";

String _encodeCommand(String command) {
  final bytes = ByteData(command.length * 2);
  for (var index = 0; index < command.length; index++) {
    bytes.setUint16(index * 2, command.codeUnitAt(index), Endian.little);
  }
  return base64Encode(bytes.buffer.asUint8List());
}
