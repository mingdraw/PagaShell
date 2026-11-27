import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/system_proxy.dart';
import 'system_proxy_backend.dart';

typedef ProxyCommand = Future<ProcessResult> Function(String, List<String>);
typedef ProxyExecutable = Future<String?> Function(String);

/// Current desktop session only. Never edits shell profiles or global /etc files.
class LinuxSystemProxy implements SystemProxyBackend {
  LinuxSystemProxy({
    ProxyCommand? run,
    ProxyExecutable? executable,
    Map<String, String>? environment,
  }) : _run = run ?? _runCommand,
       _environment = environment ?? Platform.environment,
       _executable = executable ?? _findExecutable;

  final ProxyCommand _run;
  final ProxyExecutable _executable;
  final Map<String, String> _environment;
  _LinuxProxyChange? _change;
  String? _owner;

  static Future<ProcessResult> _runCommand(
    String file,
    List<String> args,
  ) async {
    final process = await Process.start(file, args, runInShell: false);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr.drain<void>();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        return -1;
      },
    );
    final text = await output;
    await errors;
    return ProcessResult(process.pid, code, text, '');
  }

  static Future<String?> _findExecutable(String name) async {
    for (final directory in (Platform.environment['PATH'] ?? '').split(':')) {
      if (directory.isEmpty) continue;
      final file = path.join(directory, name);
      if (File(file).existsSync()) return file;
    }
    return null;
  }

  Future<String> _command(String file, List<String> args) async {
    final result = await _run(file, args);
    if (result.exitCode != 0) {
      throw const SystemProxyException('自动设置系统代理失败，请检查系统设置或取消自动设置');
    }
    return (result.stdout as String).replaceFirst(RegExp(r'\r?\n$'), '');
  }

  void _checkEnvironmentAndDesktop() {
    if (_change != null) {
      throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
    }
    const variables = [
      'http_proxy',
      'https_proxy',
      'all_proxy',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
    ];
    if (variables.any((key) => (_environment[key] ?? '').trim().isNotEmpty)) {
      throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
    }
    final desktop = _desktop();
    if (desktop.isNotEmpty &&
        ![
          'kde',
          'plasma',
          'gnome',
          'unity',
          'budgie',
          'pantheon',
        ].any(desktop.contains)) {
      throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
    }
  }

  String _desktop() =>
      (_environment['XDG_CURRENT_DESKTOP'] ??
              _environment['DESKTOP_SESSION'] ??
              '')
          .toLowerCase();

  @override
  Future<UpstreamProxyConfig?> inspectUpstream(ProxyConfig config) async {
    _checkEnvironmentAndDesktop();
    final desktop = _desktop();
    final change = desktop.contains('kde') || desktop.contains('plasma')
        ? await _kde(config)
        : await _gnome(config, checkWritable: false);
    return change.inspect();
  }

  @override
  Future<UpstreamProxyConfig?> enable(String owner, ProxyConfig config) async {
    _checkEnvironmentAndDesktop();
    final desktop = _desktop();
    final change = desktop.contains('kde') || desktop.contains('plasma')
        ? await _kde(config)
        : await _gnome(config, checkWritable: true);
    _change = change;
    _owner = owner;
    return change.enable();
  }

  @override
  Future<void> restore(String owner) async {
    if (_owner != owner || _change == null) return;
    await _change!.restore();
    _change = null;
    _owner = null;
  }

  static String _unquoteGSettings(String? raw) {
    if (raw == null) return '';
    final trimmed = raw.trim();
    if (trimmed.length >= 2 &&
        ((trimmed.startsWith("'") && trimmed.endsWith("'")) ||
            (trimmed.startsWith('"') && trimmed.endsWith('"')))) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return trimmed;
  }

  static List<String> _parseGSettingsList(String? raw) {
    if (raw == null) return const [];
    var text = raw.trim();
    if (text.startsWith('@as ')) text = text.substring(4).trim();
    if (!text.startsWith('[') || !text.endsWith(']')) return const [];
    final inner = text.substring(1, text.length - 1).trim();
    if (inner.isEmpty) return const [];
    final items = <String>[];
    for (final part in inner.split(',')) {
      final unquoted = _unquoteGSettings(part);
      if (unquoted.isNotEmpty) items.add(unquoted);
    }
    return List.unmodifiable(items);
  }

  static bool _isLoopbackHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host == 'localhost' || host.endsWith('.localhost') || host == '::1') {
      return true;
    }
    final ip = InternetAddress.tryParse(host);
    return ip != null && ip.isLoopback;
  }

  static bool _conflictsWithLocalPorts(
    UpstreamProxyConfig upstream,
    ProxyConfig config,
  ) {
    final localPorts = <int>{
      if (config.httpEnabled) config.httpPort,
      if (config.httpsEnabled) config.httpsPort,
      if (config.socks5Enabled) config.socks5Port,
    };
    bool hits(UpstreamProxyEndpoint? ep) =>
        ep != null && _isLoopbackHost(ep.host) && localPorts.contains(ep.port);
    return hits(upstream.http) || hits(upstream.https) || hits(upstream.socks5);
  }

  static UpstreamProxyEndpoint? _parseKdeProxyUrl(
    String? raw, {
    required UpstreamProxyProtocol defaultProtocol,
  }) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    if (text.contains('@')) {
      throw const SystemProxyException('当前系统代理启用了认证或反向排除规则，暂不支持串联，请取消串联或手动配置');
    }
    final normalized = text.contains('://') ? text : 'http://$text';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty || uri.port < 1 || uri.port > 65535) {
      throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const SystemProxyException('当前系统代理启用了认证或反向排除规则，暂不支持串联，请取消串联或手动配置');
    }
    final protocol = switch (uri.scheme.toLowerCase()) {
      'http' || 'https' => UpstreamProxyProtocol.http,
      'socks' || 'socks5' || 'socks5h' => UpstreamProxyProtocol.socks5,
      '' => defaultProtocol,
      _ => throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置'),
    };
    return UpstreamProxyEndpoint(
      protocol: protocol,
      host: uri.host,
      port: uri.port,
    );
  }

  Future<_LinuxProxyChange> _gnome(
    ProxyConfig config, {
    required bool checkWritable,
  }) async {
    final tool = await _executable('gsettings');
    if (tool == null) throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
    final schemas = (await _command(tool, [
      'list-schemas',
    ])).split('\n').toSet();
    const base = 'org.gnome.system.proxy';
    if (!schemas.contains(base)) {
      throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
    }
    final desired = <String, String?>{
      '$base|autoconfig-url': "''",
      '$base|ignore-hosts': '[]',
      '$base|use-same-proxy': 'false',
      '$base.http|use-authentication': 'false',
      for (final protocol in ['http', 'https', 'ftp', 'socks']) ...{
        '$base.$protocol|host': switch (protocol) {
          'http' when config.httpEnabled => "'127.0.0.1'",
          'https' when config.httpsEnabled => "'127.0.0.1'",
          'socks' when config.socks5Enabled => "'127.0.0.1'",
          _ => "''",
        },
        '$base.$protocol|port':
            '${switch (protocol) {
              'http' when config.httpEnabled => config.httpPort,
              'https' when config.httpsEnabled => config.httpsPort,
              'socks' when config.socks5Enabled => config.socks5Port,
              _ => 0,
            }}',
      },
      '$base|mode': "'manual'",
    };
    Future<String?> read(String key) async {
      final value = await _command(tool, ['get', ...key.split('|')]);
      return value == '@as []' ? '[]' : value;
    }

    if (checkWritable) {
      for (final key in desired.keys) {
        if (await _command(tool, ['writable', ...key.split('|')]) != 'true') {
          throw const SystemProxyException('没有修改系统代理的权限，请授权后重试');
        }
      }
    }
    return _LinuxProxyChange(
      desired: desired,
      modeKey: '$base|mode',
      coreKeys: {
        for (final key in desired.keys)
          if (key.endsWith('|host') ||
              key.endsWith('|port') ||
              key == '$base|mode')
            key,
      },
      usesListener: (values) =>
          values['$base|mode'] == "'manual'" &&
          ['http', 'https', 'socks'].any(
            (protocol) =>
                desired['$base.$protocol|host'] == "'127.0.0.1'" &&
                values['$base.$protocol|host'] ==
                    desired['$base.$protocol|host'] &&
                values['$base.$protocol|port'] ==
                    desired['$base.$protocol|port'],
          ),
      read: read,
      write: (key, value) async {
        await _command(tool, ['set', ...key.split('|'), value!]);
      },
      extractUpstream: (values) {
        final mode = values['$base|mode'];
        if (mode == "'none'") return null;
        if (!config.chainSystemProxy) {
          throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
        }
        if (mode == "'auto'") {
          throw const SystemProxyException(
            '当前系统正在使用 PAC 自动代理脚本，暂不支持串联，请先关闭 PAC 或取消自动设置',
          );
        }
        if (mode != "'manual'") {
          throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
        }
        if (values['$base.http|use-authentication']?.trim() == 'true') {
          throw const SystemProxyException(
            '当前系统代理启用了认证或反向排除规则，暂不支持串联，请取消串联或手动配置',
          );
        }
        UpstreamProxyEndpoint? readEndpoint(
          String name,
          UpstreamProxyProtocol protocol,
        ) {
          final host = _unquoteGSettings(values['$base.$name|host']);
          final port =
              int.tryParse((values['$base.$name|port'] ?? '').trim()) ?? 0;
          if (host.isEmpty || port <= 0) return null;
          if (port > 65535 || host.contains('@')) {
            throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
          }
          return UpstreamProxyEndpoint(
            protocol: protocol,
            host: host,
            port: port,
          );
        }

        final http = readEndpoint('http', UpstreamProxyProtocol.http);
        final useSame = values['$base|use-same-proxy']?.trim() == 'true';
        final https = useSame
            ? http
            : readEndpoint('https', UpstreamProxyProtocol.http);
        final socks5 = readEndpoint('socks', UpstreamProxyProtocol.socks5);
        final upstream = UpstreamProxyConfig(
          http: http,
          https: https,
          socks5: socks5,
          bypass: _parseGSettingsList(values['$base|ignore-hosts']),
        );
        if (!upstream.hasEndpoint) return null;
        if (_conflictsWithLocalPorts(upstream, config)) {
          throw const SystemProxyException('已有系统代理端口与当前动态代理冲突，请修改监听端口后重试');
        }
        return upstream;
      },
      reload: () async {},
    );
  }

  Future<_LinuxProxyChange> _kde(ProxyConfig config) async {
    String? reader, writer;
    for (final version in ['6', '5']) {
      reader = await _executable('kreadconfig$version');
      writer = await _executable('kwriteconfig$version');
      if (reader != null && writer != null) break;
    }
    final readTool = reader, writeTool = writer;
    final bus = await _executable('dbus-send');
    if (readTool == null || writeTool == null || bus == null) {
      throw const SystemProxyException('当前系统不支持自动设置网络代理，请手动设置');
    }
    const arguments = [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
    ];
    const missing = '__PAGASHELL_ABSENT_PROXY_KEY__';
    final desired = <String, String?>{
      'httpProxy': config.httpEnabled
          ? 'http://127.0.0.1:${config.httpPort}'
          : '',
      // HTTPS destinations use HTTP CONNECT, not TLS to the local proxy.
      'httpsProxy': config.httpsEnabled
          ? 'http://127.0.0.1:${config.httpsPort}'
          : '',
      'ftpProxy': '',
      'socksProxy': config.socks5Enabled
          ? 'socks://127.0.0.1:${config.socks5Port}'
          : '',
      'NoProxyFor': '',
      'ReversedException': 'false',
      'Proxy Config Script': '',
      'ProxyType': '1',
    };
    return _LinuxProxyChange(
      desired: desired,
      modeKey: 'ProxyType',
      coreKeys: {
        'ProxyType',
        'httpProxy',
        'httpsProxy',
        'ftpProxy',
        'socksProxy',
      },
      usesListener: (values) =>
          values['ProxyType'] == '1' &&
          ['httpProxy', 'httpsProxy', 'socksProxy'].any(
            (key) =>
                (desired[key] ?? '').isNotEmpty && values[key] == desired[key],
          ),
      read: (key) async {
        final value = await _command(readTool, [
          ...arguments,
          key,
          '--default',
          missing,
        ]);
        return value == missing ? null : value;
      },
      write: (key, value) async {
        await _command(writeTool, [
          ...arguments,
          key,
          if (value == null) '--delete' else value,
        ]);
      },
      extractUpstream: (values) {
        final mode = values['ProxyType'] ?? '0';
        if (mode == '0') return null;
        if (!config.chainSystemProxy) {
          throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
        }
        if (mode == '2') {
          throw const SystemProxyException(
            '当前系统正在使用 PAC 自动代理脚本，暂不支持串联，请先关闭 PAC 或取消自动设置',
          );
        }
        if (mode == '3') {
          // WPAD auto-detect without PAC: temporarily replace and restore on stop.
          return null;
        }
        if (mode != '1') {
          throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
        }
        if ((values['ReversedException'] ?? '').trim().toLowerCase() ==
            'true') {
          throw const SystemProxyException(
            '当前系统代理启用了认证或反向排除规则，暂不支持串联，请取消串联或手动配置',
          );
        }
        final http = _parseKdeProxyUrl(
          values['httpProxy'],
          defaultProtocol: UpstreamProxyProtocol.http,
        );
        final https = _parseKdeProxyUrl(
          values['httpsProxy'],
          defaultProtocol: UpstreamProxyProtocol.http,
        );
        final socks5 = _parseKdeProxyUrl(
          values['socksProxy'],
          defaultProtocol: UpstreamProxyProtocol.socks5,
        );
        final bypass = (values['NoProxyFor'] ?? '')
            .split(RegExp(r'[,;]'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList(growable: false);
        final upstream = UpstreamProxyConfig(
          http: http,
          https: https,
          socks5: socks5,
          bypass: bypass,
        );
        if (!upstream.hasEndpoint) return null;
        if (_conflictsWithLocalPorts(upstream, config)) {
          throw const SystemProxyException('已有系统代理端口与当前动态代理冲突，请修改监听端口后重试');
        }
        return upstream;
      },
      reload: () async {
        await _command(bus, [
          '--session',
          '--type=signal',
          '/KIO/Scheduler',
          'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
          'string:',
        ]);
      },
    );
  }
}

class _LinuxProxyChange {
  _LinuxProxyChange({
    required this.desired,
    required this.modeKey,
    required this.coreKeys,
    required this.usesListener,
    required this.read,
    required this.write,
    required this.extractUpstream,
    required this.reload,
  });
  final Map<String, String?> desired;
  final String modeKey;
  final Set<String> coreKeys;
  final bool Function(Map<String, String?>) usesListener;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  final UpstreamProxyConfig? Function(Map<String, String?>) extractUpstream;
  final Future<void> Function() reload;
  Map<String, String?>? _before;
  final Set<String> _attempted = {};

  Future<Map<String, String?>> _readAll() async => {
    for (final key in desired.keys) key: await read(key),
  };

  Future<UpstreamProxyConfig?> inspect() async {
    final before = await _readAll();
    return extractUpstream(before);
  }

  Future<UpstreamProxyConfig?> enable() async {
    final before = await _readAll();
    final upstream = extractUpstream(before);
    _before = before;
    for (final key in desired.keys) {
      if (await read(key) != before[key]) {
        throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
      }
      if (key == modeKey && !await _matchesExpected()) {
        throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
      }
      _attempted.add(key);
      await write(key, desired[key]);
      if (await read(key) != desired[key]) {
        throw const SystemProxyException('自动设置系统代理失败，请检查系统设置或取消自动设置');
      }
    }
    if (!await _matchesExpected()) {
      throw const SystemProxyException('系统代理已被占用，请先停止其他代理或取消自动设置');
    }
    await reload();
    return upstream;
  }

  Future<bool> _matchesExpected() async {
    final current = await _readAll();
    return desired.keys.every(
      (key) =>
          current[key] ==
          (_attempted.contains(key) ? desired[key] : _before![key]),
    );
  }

  Future<bool> _canRestore() async {
    final current = await _readAll();
    for (final key in coreKeys) {
      final value = current[key];
      if (value != _before![key] &&
          (!_attempted.contains(key) || value != desired[key])) {
        if (usesListener(current)) {
          throw const SystemProxyException('系统代理配置已被部分修改，请在系统设置中移除本应用代理后重试停止');
        }
        return false;
      }
    }
    return true;
  }

  Future<void> restore() async {
    if (_before == null || _attempted.isEmpty) return;
    // Preserve a full takeover; retain the listener on a partial takeover.
    if (!await _canRestore()) return;
    for (final key in [
      modeKey,
      ...desired.keys.where((key) => key != modeKey).toList().reversed,
    ]) {
      if (!_attempted.contains(key)) continue;
      if (!await _canRestore()) return;
      final current = await read(key);
      if (current == desired[key] && current != _before![key]) {
        await write(key, _before![key]);
        if (await read(key) != _before![key]) {
          throw const SystemProxyException('恢复系统代理失败，请重试停止代理');
        }
      }
    }
    await reload();
  }
}
