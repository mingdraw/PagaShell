import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/proxy/system_proxy_lookup.dart';

typedef LookupCommand = Future<ProcessResult> Function(String, List<String>);
typedef LookupExecutable = Future<String?> Function(String);

/// 读取当前桌面会话的网络代理；只用于应用内请求，不改动系统设置。
class DesktopSystemProxyLookup implements SystemProxyLookup {
  DesktopSystemProxyLookup({
    this._channel = const MethodChannel('pagashell/system_proxy'),
    Map<String, String>? environment,
    LookupCommand? run,
    LookupExecutable? executable,
    bool? isLinux,
    bool? isMacOS,
    bool? isWindows,
  }) : _environment = environment ?? Platform.environment,
       _run = run ?? _runCommand,
       _executable = executable ?? _findExecutable,
       _isLinux = isLinux ?? Platform.isLinux,
       _isMacOS = isMacOS ?? Platform.isMacOS,
       _isWindows = isWindows ?? Platform.isWindows;

  final MethodChannel _channel;
  final Map<String, String> _environment;
  final LookupCommand _run;
  final LookupExecutable _executable;
  final bool _isLinux;
  final bool _isMacOS;
  final bool _isWindows;

  @override
  Future<AppProxyEndpoint?> resolve(Uri target) async {
    if (_isMacOS || _isWindows) {
      final native = await _resolveNative(target);
      if (native != null) return native;
      return parseProxyEnvironment(target, _environment);
    }
    if (_isLinux) {
      final fromEnv = parseProxyEnvironment(target, _environment);
      if (fromEnv != null) return fromEnv;
      if (_isBypassedByEnv(target, _environment)) return null;
      return _resolveLinuxDesktop(target);
    }
    return parseProxyEnvironment(target, _environment);
  }

  Future<AppProxyEndpoint?> _resolveNative(Uri target) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'resolve',
        {'url': target.toString()},
      );
      if (result == null) return null;
      return parseNativeResult(result);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static AppProxyEndpoint? parseNativeResult(Map<Object?, Object?> map) {
    final protocolName = map['protocol'];
    final host = map['host'];
    final port = map['port'];
    if (protocolName is! String || host is! String || port is! int) {
      return null;
    }
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty || port < 1 || port > 65535) return null;
    final protocol = switch (protocolName.toLowerCase()) {
      'http' => AppProxyProtocol.http,
      'https' => AppProxyProtocol.https,
      'socks' || 'socks5' => AppProxyProtocol.socks5,
      _ => null,
    };
    if (protocol == null) return null;
    return AppProxyEndpoint(protocol: protocol, host: trimmedHost, port: port);
  }

  static AppProxyEndpoint? parseProxyEnvironment(
    Uri target,
    Map<String, String> environment,
  ) {
    if (_isBypassedByEnv(target, environment)) return null;
    final scheme = target.scheme.toLowerCase();
    final keys = switch (scheme) {
      'https' => const ['https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY'],
      'http' => const ['http_proxy', 'HTTP_PROXY', 'all_proxy', 'ALL_PROXY'],
      _ => const [
        'all_proxy',
        'ALL_PROXY',
        'https_proxy',
        'HTTPS_PROXY',
        'http_proxy',
        'HTTP_PROXY',
      ],
    };
    for (final key in keys) {
      final raw = (environment[key] ?? '').trim();
      if (raw.isEmpty) continue;
      final endpoint = parseProxyUrl(raw);
      if (endpoint != null) return endpoint;
    }
    return null;
  }

  static bool _isBypassedByEnv(Uri target, Map<String, String> environment) {
    final raw = (environment['no_proxy'] ?? environment['NO_PROXY'] ?? '')
        .trim();
    if (raw.isEmpty) return false;
    final entries = raw
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return matchesBypass(target, entries);
  }

  static bool matchesBypass(Uri target, Iterable<String> rules) {
    final host = target.host.toLowerCase();
    if (host.isEmpty) return false;
    final port = target.hasPort
        ? target.port
        : (target.scheme.toLowerCase() == 'https' ? 443 : 80);
    for (final rawRule in rules) {
      var rule = rawRule.trim().toLowerCase();
      if (rule.isEmpty) continue;
      if (rule == '*') return true;
      if (rule == '<local>') {
        if (!host.contains('.')) return true;
        continue;
      }
      int? rulePort;
      if (!rule.startsWith('[') && rule.contains(':')) {
        final first = rule.indexOf(':');
        final last = rule.lastIndexOf(':');
        if (first == last) {
          final parsedPort = int.tryParse(rule.substring(last + 1));
          if (parsedPort != null) {
            rulePort = parsedPort;
            rule = rule.substring(0, last);
          }
        }
      }
      if (rulePort != null && rulePort != port) continue;
      if (rule.startsWith('*.')) {
        final suffix = rule.substring(1);
        if (host.endsWith(suffix) || host == rule.substring(2)) return true;
      } else if (rule.startsWith('.')) {
        if (host.endsWith(rule) || host == rule.substring(1)) return true;
      } else if (host == rule || host.endsWith('.$rule')) {
        return true;
      }
    }
    return false;
  }

  static AppProxyEndpoint? parseProxyUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    final protocol = switch (scheme) {
      'http' => AppProxyProtocol.http,
      'https' => AppProxyProtocol.https,
      'socks' || 'socks5' || 'socks5h' => AppProxyProtocol.socks5,
      _ => null,
    };
    if (protocol == null) return null;
    final port = uri.hasPort
        ? uri.port
        : switch (protocol) {
            AppProxyProtocol.http => 80,
            AppProxyProtocol.https => 443,
            AppProxyProtocol.socks5 => 1080,
          };
    if (port < 1 || port > 65535) return null;
    var username = '';
    var password = '';
    if (uri.userInfo.isNotEmpty) {
      final colon = uri.userInfo.indexOf(':');
      if (colon >= 0) {
        username = Uri.decodeComponent(uri.userInfo.substring(0, colon));
        password = Uri.decodeComponent(uri.userInfo.substring(colon + 1));
      } else {
        username = Uri.decodeComponent(uri.userInfo);
      }
    }
    return AppProxyEndpoint(
      protocol: protocol,
      host: uri.host,
      port: port,
      username: username,
      password: password,
    );
  }

  Future<AppProxyEndpoint?> _resolveLinuxDesktop(Uri target) async {
    final desktop =
        (_environment['XDG_CURRENT_DESKTOP'] ??
                _environment['DESKTOP_SESSION'] ??
                '')
            .toLowerCase();
    if (desktop.contains('kde') || desktop.contains('plasma')) {
      return _resolveKde(target);
    }
    return _resolveGnome(target);
  }

  Future<AppProxyEndpoint?> _resolveGnome(Uri target) async {
    final tool = await _executable('gsettings');
    if (tool == null) return null;
    const base = 'org.gnome.system.proxy';
    final mode = _stripGVariant(await _readOutput(tool, ['get', base, 'mode']));
    if (mode != 'manual') return null;
    final ignoreRaw = await _readOutput(tool, ['get', base, 'ignore-hosts']);
    if (ignoreRaw != null &&
        matchesBypass(target, _parseGVariantList(ignoreRaw))) {
      return null;
    }
    final scheme = target.scheme.toLowerCase();
    final candidates = scheme == 'https'
        ? const [
            ('https', AppProxyProtocol.http),
            ('http', AppProxyProtocol.http),
            ('socks', AppProxyProtocol.socks5),
          ]
        : const [
            ('http', AppProxyProtocol.http),
            ('socks', AppProxyProtocol.socks5),
          ];
    for (final candidate in candidates) {
      final host = _stripGVariant(
        await _readOutput(tool, ['get', '$base.${candidate.$1}', 'host']),
      );
      final portText = _stripGVariant(
        await _readOutput(tool, ['get', '$base.${candidate.$1}', 'port']),
      );
      final port = int.tryParse(portText ?? '');
      if (host != null &&
          host.isNotEmpty &&
          port != null &&
          port > 0 &&
          port <= 65535) {
        return AppProxyEndpoint(protocol: candidate.$2, host: host, port: port);
      }
    }
    return null;
  }

  Future<AppProxyEndpoint?> _resolveKde(Uri target) async {
    final tool =
        await _executable('kreadconfig6') ?? await _executable('kreadconfig5');
    if (tool == null) return null;
    Future<String?> readKey(String key) => _readOutput(tool, [
      '--file',
      'kioslaverc',
      '--group',
      'Proxy Settings',
      '--key',
      key,
    ]);
    if ((await readKey('ProxyType'))?.trim() != '1') return null;
    final noProxy = await readKey('NoProxyFor');
    if (noProxy != null &&
        noProxy.trim().isNotEmpty &&
        matchesBypass(
          target,
          noProxy.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty),
        )) {
      return null;
    }
    final scheme = target.scheme.toLowerCase();
    final keys = scheme == 'https'
        ? const ['httpsProxy', 'httpProxy', 'socksProxy']
        : const ['httpProxy', 'socksProxy'];
    for (final key in keys) {
      final raw = (await readKey(key))?.trim();
      if (raw == null || raw.isEmpty) continue;
      final normalized = raw.replaceFirst(RegExp(r'\s+'), ':');
      final parsed = parseProxyUrl(
        key == 'socksProxy' && !normalized.contains('://')
            ? 'socks5://$normalized'
            : normalized,
      );
      if (parsed != null) return parsed;
    }
    return null;
  }

  Future<String?> _readOutput(String file, List<String> args) async {
    try {
      final result = await _run(file, args);
      if (result.exitCode != 0) return null;
      return (result.stdout as String).trim();
    } on Object {
      return null;
    }
  }

  static String? _stripGVariant(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  static List<String> _parseGVariantList(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return const [];
    final inner = trimmed.substring(1, trimmed.length - 1).trim();
    if (inner.isEmpty) return const [];
    return inner
        .split(',')
        .map((item) => _stripGVariant(item) ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
  }

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
      const Duration(seconds: 5),
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
}
