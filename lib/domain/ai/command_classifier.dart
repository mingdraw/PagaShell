enum AgentCommandRisk { readOnly, mutating, highRisk }

final _highRisk = RegExp(
  r'\b(?:rm|mkfs(?:\.[\w-]+)?|dd|wipefs|fdisk|parted|reboot|shutdown|'
  r'poweroff|halt|killall|pkill)\b|\binit\s+[06]\b|'
  r'\bkill\s+[^;\n|]*-(?:9|KILL)\b|\b(?:chmod|chown)\s+[^;\n|]*-[^\s;\n|]*R\b|'
  r'\b(?:iptables|ip6tables)\s+[^;\n|]*(?:-F\b|--flush\b)|\bufw\s+disable\b|'
  r'\bsystemctl\s+(?:stop|disable|mask)\s+[^;\n|]*\bssh|'
  r'\b(?:DROP\s+(?:DATABASE|TABLE)|TRUNCATE|FLUSHALL|FLUSHDB)\b|'
  r'\b(?:curl|wget)\b[^;\n]*\|\s*(?:sudo\s+-n\s+)?(?:/bin/)?(?:ba)?sh\b|'
  r'>+\s*/dev/(?:sd|hd|vd|nvme)',
  caseSensitive: false,
);

/// Automatic shell checks are restricted to literal commands and arguments.
/// The default for SQL, aliases, options or paths we don't recognize is review.
AgentCommandRisk classifyShellCommand(String command) {
  if (_highRisk.hasMatch(command)) return AgentCommandRisk.highRisk;
  final pipeline = _literalPipeline(command);
  if (pipeline != null &&
      pipeline.indexed.every((stage) => _isReadOnly(stage.$2, stage.$1 > 0))) {
    return AgentCommandRisk.readOnly;
  }
  return AgentCommandRisk.mutating;
}

final _disallowedShellChars = RegExp(
  r'''[<>&;\x60$\\\r\n\x00-\x08\x0b-\x1f\x7f]''',
);
final _mysqlReadOnly = RegExp(
  r'^(?:SHOW\s+(?:(?:GLOBAL|SESSION)\s+)?(?:VARIABLES|STATUS)|SELECT\s+VERSION\(\))$',
  caseSensitive: false,
);
final _psqlShow = RegExp(r'^SHOW\s+[a-z_][a-z0-9_]*$', caseSensitive: false);
final _psqlSensitive = RegExp(
  r'(?:conninfo|command|pass|secret|ssl_key)',
  caseSensitive: false,
);
final _shortLinesArg = RegExp(r'^-[0-9]{1,4}$');
final _linesCountArg = RegExp(r'^[0-9]{1,4}$');

List<List<String>>? _literalPipeline(String command) {
  if (command.isEmpty ||
      command.length > 8000 ||
      _disallowedShellChars.hasMatch(command)) {
    return null;
  }
  final stages = <List<String>>[[]];
  final word = StringBuffer();
  String? quote;
  var wordStarted = false;
  void flush() {
    if (wordStarted) {
      stages.last.add(word.toString());
      word.clear();
      wordStarted = false;
    }
  }

  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        word.write(c);
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      wordStarted = true;
    } else if (c == '|') {
      flush();
      if (stages.last.isEmpty || stages.length >= 6) return null;
      stages.add([]);
    } else if (c == ' ' || c == '\t') {
      flush();
    } else if ('*?[]{}~!#'.contains(c)) {
      return null;
    } else {
      word.write(c);
      wordStarted = true;
    }
  }
  flush();
  return quote != null || stages.last.isEmpty ? null : stages;
}

final _units = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,127}$');
final _localDiagnostic = RegExp(
  r'^/(?:etc/(?:os-release|[a-z-]+-release)|proc/(?:meminfo|cpuinfo|loadavg|uptime|'
  r'sys/fs/(?:file-max|nr_open|file-nr)|[0-9]+/limits)|'
  r'sys/kernel/mm/transparent_hugepage/enabled)$',
);
const _sysctl = {
  'fs.file-max',
  'fs.nr_open',
  'fs.file-nr',
  'net.core.somaxconn',
  'net.ipv4.tcp_max_syn_backlog',
  'net.ipv4.ip_local_port_range',
  'net.ipv4.tcp_tw_reuse',
  'net.ipv4.tcp_fin_timeout',
  'net.ipv4.tcp_congestion_control',
  'net.ipv4.tcp_available_congestion_control',
  'vm.swappiness',
  'vm.overcommit_memory',
  'kern.maxfiles',
  'kern.maxfilesperproc',
  'hw.memsize',
  'hw.logicalcpu',
};
const _noArgs = {'uptime', 'nproc', 'lscpu', 'whoami', 'id', 'sw_vers'};

bool _isReadOnly(List<String> words, bool piped) {
  if (words.length > 24) return false;
  final sudo = words.first == 'sudo';
  if (sudo) {
    if (words.length < 3 || words[1] != '-n') return false;
    words = words.sublist(2);
  }
  final name = words.first;
  final args = words.sublist(1);
  bool options(Set<String> allowed) => args.every(allowed.contains);
  bool flags(String flags) => args.every(
    (arg) =>
        arg.length > 1 &&
        arg.startsWith('-') &&
        arg.substring(1).split('').every(flags.contains),
  );
  if (sudo &&
      !const {
        'cat',
        'sysctl',
        'ss',
        'systemctl',
        'nginx',
        'sshd',
        'mysqld',
      }.contains(name)) {
    return false;
  }
  if (_noArgs.contains(name)) return args.isEmpty;
  return switch (name) {
    'uname' => flags('asnrvmopi'),
    'free' => flags('bhkmgtw'),
    'df' => flags('hHkilPT'),
    'ls' => flags('alhA1'),
    'lsblk' => options({'-a', '-b', '-d', '-n', '-l', '-f', '-J'}),
    'ps' => options({'-e', '-A'}),
    'ss' => flags('lntup46s'),
    'netstat' => flags('lntup46s'),
    'cat' => args.isNotEmpty && args.every(_localDiagnostic.hasMatch),
    'head' || 'tail' => _checkLines(args, piped),
    'grep' || 'rg' =>
      piped &&
          args.isNotEmpty &&
          args.last.isNotEmpty &&
          !args.last.startsWith('-') &&
          args
              .take(args.length - 1)
              .every(
                const {
                  '-i',
                  '-E',
                  '-F',
                  '-v',
                  '-n',
                  '-c',
                  '--color=never',
                }.contains,
              ),
    'wc' => piped && flags('clmw'),
    'sort' => piped && flags('nruh'),
    'uniq' => piped && flags('cdui'),
    'ulimit' => !sudo && options({'-a', '-n', '-Sn', '-Hn'}),
    'sysctl' =>
      args.any(_sysctl.contains) &&
          args.every((arg) => arg == '-n' || _sysctl.contains(arg)),
    'systemctl' => _checkSystemctl(args),
    'docker' =>
      args.length == 1 &&
          const {'ps', 'images', 'info', 'version'}.contains(args.first),
    'dpkg' => args.length == 1 && args.first == '-l',
    'rpm' => args.length == 1 && args.first == '-qa',
    'apt-cache' =>
      args.length == 2 && args.first == 'policy' && _units.hasMatch(args.last),
    'mysql' =>
      args.length == 2 &&
          args.first == '-e' &&
          _mysqlReadOnly.hasMatch(args.last),
    'psql' =>
      args.length == 3 &&
          args[0] == '-X' &&
          args[1] == '-c' &&
          _psqlShow.hasMatch(args.last) &&
          !_psqlSensitive.hasMatch(args.last),
    'redis-cli' =>
      args.length == 1 &&
              const {'INFO', 'PING'}.contains(args.first.toUpperCase()) ||
          args.length == 2 &&
              args.first.toUpperCase() == 'INFO' &&
              const {
                'server',
                'memory',
                'stats',
                'persistence',
                'keyspace',
              }.contains(args.last),
    'mysqld' ||
    'mariadbd' ||
    'nginx' ||
    'sshd' ||
    'postgres' ||
    'redis-server' =>
      _isValidator(words) ||
          args.length == 1 &&
              const {'--version', '-v', '-V'}.contains(args.first) &&
              name != 'sshd',
    _ => false,
  };
}

bool _checkLines(List<String> args, bool piped) {
  if (args.isNotEmpty && _shortLinesArg.hasMatch(args.first)) {
    args = args.sublist(1);
  } else if (args.length >= 2 &&
      args.first == '-n' &&
      _linesCountArg.hasMatch(args[1])) {
    args = args.sublist(2);
  }
  return args.isEmpty
      ? piped
      : args.length == 1 && _localDiagnostic.hasMatch(args.first);
}

bool _checkSystemctl(List<String> args) {
  if (args.isEmpty) return false;
  final action = args.first;
  final rest = args.skip(1);
  const properties = {
    '-pLimitNOFILE',
    '-pMainPID',
    '-pActiveState',
    '-pSubState',
    '--property=LimitNOFILE',
    '--property=MainPID',
    '--property=ActiveState',
    '--property=SubState',
    '--property=FragmentPath',
  };
  if (action == 'show') {
    return rest.any(properties.contains) &&
        rest.any(_units.hasMatch) &&
        rest.every((arg) => properties.contains(arg) || _units.hasMatch(arg));
  }
  if (action == 'list-units') {
    return rest.every(const {'--type=service', '--all', '--no-pager'}.contains);
  }
  return const {'is-active', 'is-enabled'}.contains(action) &&
      rest.isNotEmpty &&
      rest.every(_units.hasMatch);
}

bool _isValidator(List<String> words) =>
    words.length == 2 &&
    switch ((words[0], words[1])) {
      ('nginx' || 'sshd', '-t') || ('mysqld', '--validate-config') => true,
      _ => false,
    };

/// Validation is attached to an approved file change. It accepts only
/// recognized syntax checks and cannot be used to run another mutation.
bool isAgentValidationCommand(String command) {
  final stages = _literalPipeline(command);
  if (stages == null || stages.length != 1) return false;
  final words = stages.single;
  return _isValidator(
    words.length > 2 && words[0] == 'sudo' && words[1] == '-n'
        ? words.sublist(2)
        : words,
  );
}
