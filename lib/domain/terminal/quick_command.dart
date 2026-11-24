/// 终端底部常用指令面板的模型、校验逻辑与内置运维指令库。
class QuickCommand {
  const QuickCommand({
    required this.id,
    required this.command,
    required this.summary,
    this.keywords = const [],
    this.isBuiltIn = true,
  });

  static const int maxCommandLength = 1000;
  static const int maxSummaryLength = 200;
  static final _controlChars = RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]');

  final String id;

  /// 点击后填入当前聚焦终端的指令文本（可保留尾部空格方便继续输入参数）。
  final String command;

  /// 指令用途说明；内置指令作为 GetX 翻译键，自定义指令按原文展示。
  final String summary;

  /// 额外搜索关键词（如中英文别名、工具名）。
  final List<String> keywords;

  /// 是否为内置只读指令。
  final bool isBuiltIn;

  /// Badge 上展示的紧凑指令文本（去除尾部辅助空格）。
  String get displayCommand => command.trim();

  static String? validateCommand(String? raw) {
    final text = raw ?? '';
    if (text.trim().isEmpty) return '请输入指令内容';
    if (text.contains('\r') || text.contains('\n')) {
      return '指令不支持换行，请输入单行命令';
    }
    if (_controlChars.hasMatch(text)) return '指令不能包含控制字符';
    if (text.length > maxCommandLength) return '指令长度不能超过 1000 个字符';
    return null;
  }

  static String? validateSummary(String? raw) {
    final text = (raw ?? '').trim();
    if (text.length > maxSummaryLength) return '说明长度不能超过 200 个字符';
    return null;
  }

  static String normalizeCommand(String raw) => raw.trimLeft();

  QuickCommand copyWith({
    String? id,
    String? command,
    String? summary,
    List<String>? keywords,
    bool? isBuiltIn,
  }) => QuickCommand(
    id: id ?? this.id,
    command: command ?? this.command,
    summary: summary ?? this.summary,
    keywords: keywords ?? this.keywords,
    isBuiltIn: isBuiltIn ?? this.isBuiltIn,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'command': command,
    'summary': summary,
  };

  static QuickCommand fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final command = json['command'];
    final summary = json['summary'];
    if (id is! String ||
        id.trim().isEmpty ||
        command is! String ||
        validateCommand(command) != null ||
        (summary != null && summary is! String)) {
      throw const FormatException('Invalid quick command');
    }
    final normalizedSummary = (summary as String? ?? '').trim();
    if (validateSummary(normalizedSummary) != null) {
      throw const FormatException('Invalid quick command summary');
    }
    return QuickCommand(
      id: id.trim(),
      command: normalizeCommand(command),
      summary: normalizedSummary,
      isBuiltIn: false,
    );
  }

  bool matchesQuery(
    String normalizedQuery, {
    required String displaySummary,
    required String displayCategory,
  }) {
    if (normalizedQuery.isEmpty) return true;
    if (command.toLowerCase().contains(normalizedQuery)) return true;
    if (summary.toLowerCase().contains(normalizedQuery)) return true;
    if (displaySummary.toLowerCase().contains(normalizedQuery)) return true;
    if (displayCategory.toLowerCase().contains(normalizedQuery)) return true;
    return keywords.any((item) => item.toLowerCase().contains(normalizedQuery));
  }

  @override
  bool operator ==(Object other) =>
      other is QuickCommand &&
      other.id == id &&
      other.command == command &&
      other.summary == summary &&
      other.isBuiltIn == isBuiltIn &&
      _listEquals(other.keywords, keywords);

  @override
  int get hashCode =>
      Object.hash(id, command, summary, isBuiltIn, Object.hashAll(keywords));
}

enum QuickCommandCategoryId {
  system,
  files,
  process,
  network,
  docker,
  kubernetes,
  database,
  nginx,
  packages,
  git,
}

class QuickCommandCategory {
  const QuickCommandCategory({
    required this.id,
    required this.title,
    required this.commands,
    this.builtInId,
  });

  static const int maxTitleLength = 40;

  final String id;

  /// 内置分类标识；自定义分组为 null。
  final QuickCommandCategoryId? builtInId;

  /// 分组名称；内置分类作为 GetX 翻译键，自定义分组按原文展示。
  final String title;
  final List<QuickCommand> commands;

  bool get isBuiltIn => builtInId != null;

  static String? validateTitle(
    String? raw, {
    Iterable<String> existingTitles = const [],
  }) {
    final trimmed = (raw ?? '').trim();
    if (trimmed.isEmpty) return '请输入分组名称';
    if (trimmed.length > maxTitleLength) return '分组名称不能超过 40 个字符';
    final normalized = trimmed.toLowerCase();
    for (final existing in existingTitles) {
      if (existing.trim().toLowerCase() == normalized) {
        return '分组名称已存在';
      }
    }
    return null;
  }

  QuickCommandCategory copyWith({
    String? id,
    String? title,
    List<QuickCommand>? commands,
    QuickCommandCategoryId? builtInId,
  }) => QuickCommandCategory(
    id: id ?? this.id,
    builtInId: builtInId ?? this.builtInId,
    title: title ?? this.title,
    commands: commands ?? this.commands,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'commands': [for (final command in commands) command.toJson()],
  };

  static QuickCommandCategory fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final rawCommands = json['commands'];
    if (id is! String ||
        id.trim().isEmpty ||
        title is! String ||
        validateTitle(title) != null ||
        rawCommands is! List) {
      throw const FormatException('Invalid quick command group');
    }
    final commands = <QuickCommand>[];
    for (final item in rawCommands) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid quick command entry');
      }
      commands.add(QuickCommand.fromJson(item));
    }
    return QuickCommandCategory(
      id: id.trim(),
      title: title.trim(),
      commands: List.unmodifiable(commands),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuickCommandCategory &&
      other.id == id &&
      other.builtInId == builtInId &&
      other.title == title &&
      _listEquals(other.commands, commands);

  @override
  int get hashCode =>
      Object.hash(id, builtInId, title, Object.hashAll(commands));
}

class QuickCommandMatch {
  const QuickCommandMatch({required this.category, required this.command});

  final QuickCommandCategory category;
  final QuickCommand command;
}

abstract final class QuickCommandCatalog {
  static const List<QuickCommandCategory> categories = [
    QuickCommandCategory(
      id: 'system',
      builtInId: QuickCommandCategoryId.system,
      title: '系统',
      commands: [
        QuickCommand(
          id: 'sys-uname',
          command: 'uname -a',
          summary: '查看内核版本、主机名与系统架构',
          keywords: ['kernel', 'arch', '内核', '版本', '架构'],
        ),
        QuickCommand(
          id: 'sys-os-release',
          command: 'cat /etc/os-release',
          summary: '查看 Linux 发行版与系统版本号',
          keywords: ['distro', 'ubuntu', 'centos', 'debian', '发行版'],
        ),
        QuickCommand(
          id: 'sys-uptime',
          command: 'uptime',
          summary: '查看系统运行时间与 1/5/15 分钟平均负载',
          keywords: ['load', '负载', '运行时间'],
        ),
        QuickCommand(
          id: 'sys-free',
          command: 'free -h',
          summary: '查看内存与 Swap 使用情况（自动换算单位）',
          keywords: ['memory', 'ram', 'swap', '内存'],
        ),
        QuickCommand(
          id: 'sys-lscpu',
          command: 'lscpu',
          summary: '查看 CPU 架构、核心数与线程信息',
          keywords: ['cpu', 'cores', '处理器', '核心'],
        ),
        QuickCommand(
          id: 'sys-df',
          command: 'df -h',
          summary: '查看各磁盘分区容量与挂载点使用率',
          keywords: ['disk', 'storage', '磁盘', '空间', '挂载'],
        ),
        QuickCommand(
          id: 'sys-du-top',
          command: 'du -sh * | sort -hr | head -n 20',
          summary: '统计当前目录下体积最大的前 20 个文件或目录',
          keywords: ['disk', 'size', '目录大小', '磁盘占用'],
        ),
        QuickCommand(
          id: 'sys-lsblk',
          command: 'lsblk',
          summary: '树形列出所有块设备、分区与挂载关系',
          keywords: ['disk', 'partition', '块设备', '分区'],
        ),
        QuickCommand(
          id: 'sys-timedatectl',
          command: 'timedatectl',
          summary: '查看系统时间、时区与 NTP 同步状态',
          keywords: ['time', 'timezone', 'ntp', '时区', '时间'],
        ),
        QuickCommand(
          id: 'sys-dmesg',
          command: 'dmesg -T | tail -n 50',
          summary: '查看最近 50 条带可读时间戳的内核日志',
          keywords: ['kernel', 'oom', '内核日志', '故障'],
        ),
        QuickCommand(
          id: 'sys-ulimit',
          command: 'ulimit -a',
          summary: '查看当前 Shell 的文件描述符等资源限制',
          keywords: ['fd', 'open files', '句柄', '限制'],
        ),
        QuickCommand(
          id: 'sys-sysctl',
          command: 'sysctl -a | grep ',
          summary: '搜索查看当前生效的内核运行参数',
          keywords: ['kernel', 'param', '内核参数'],
        ),
        QuickCommand(
          id: 'sys-hostnamectl',
          command: 'hostnamectl',
          summary: '查看主机名、操作系统与内核概览',
          keywords: ['hostname', 'os', '主机名'],
        ),
        QuickCommand(
          id: 'sys-who',
          command: 'who',
          summary: '查看当前登录系统的所有用户会话',
          keywords: ['user', 'login', 'session', '登录用户'],
        ),
        QuickCommand(
          id: 'sys-last',
          command: 'last -n 20',
          summary: '查看最近 20 条系统登录与重启记录',
          keywords: ['login', 'reboot', 'audit', '登录历史'],
        ),
        QuickCommand(
          id: 'sys-df-inode',
          command: 'df -i',
          summary: '查看各磁盘分区的 inode 使用率（排查小文件耗尽空间）',
          keywords: ['inode', 'disk', '磁盘', '小文件'],
        ),
        QuickCommand(
          id: 'sys-vmstat',
          command: 'vmstat 1 5',
          summary: '每秒采样一次 CPU、内存、IO 与上下文切换（共 5 次）',
          keywords: ['cpu', 'memory', 'io', '性能采样'],
        ),
        QuickCommand(
          id: 'sys-iostat',
          command: 'iostat -xz 1 3',
          summary: '查看磁盘 I/O 吞吐、延迟与利用率详情',
          keywords: ['disk', 'io', 'latency', '磁盘io'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'files',
      builtInId: QuickCommandCategoryId.files,
      title: '文件与日志',
      commands: [
        QuickCommand(
          id: 'file-ls',
          command: 'ls -lah',
          summary: '列出目录内所有文件（含隐藏文件、权限与大小）',
          keywords: ['list', 'dir', '目录', '列表', '权限'],
        ),
        QuickCommand(
          id: 'file-find-name',
          command: 'find / -name "*keyword*" 2>/dev/null',
          summary: '按文件名递归查找文件并忽略权限报错',
          keywords: ['search', 'locate', '查找', '搜索文件'],
        ),
        QuickCommand(
          id: 'file-find-large',
          command: 'find . -type f -size +100M',
          summary: '查找当前目录下大于 100MB 的大文件',
          keywords: ['large', 'disk', '大文件', '清理'],
        ),
        QuickCommand(
          id: 'file-grep',
          command: 'grep -rn "keyword" .',
          summary: '在当前目录递归搜索包含关键词的文本行并显示行号',
          keywords: ['search', 'text', '文本搜索', '关键词'],
        ),
        QuickCommand(
          id: 'file-tail',
          command: 'tail -f -n 100 ',
          summary: '实时跟踪日志文件末尾最新 100 行输出',
          keywords: ['log', 'follow', '实时日志', '追踪'],
        ),
        QuickCommand(
          id: 'file-less',
          command: 'less +F ',
          summary: '以可翻页模式实时追踪日志（Ctrl+C 暂停，Shift+F 继续）',
          keywords: ['log', 'pager', '翻页日志'],
        ),
        QuickCommand(
          id: 'file-tar-c',
          command: 'tar -czvf archive.tar.gz ',
          summary: '将文件或目录打包并用 gzip 压缩',
          keywords: ['compress', 'archive', '压缩', '打包'],
        ),
        QuickCommand(
          id: 'file-tar-x',
          command: 'tar -xzvf ',
          summary: '解压 .tar.gz 压缩包到当前目录',
          keywords: ['extract', 'unzip', '解压'],
        ),
        QuickCommand(
          id: 'file-chmod',
          command: 'chmod -R 755 ',
          summary: '递归修改目录或文件的读写执行权限',
          keywords: ['permission', '权限'],
        ),
        QuickCommand(
          id: 'file-chown',
          command: 'chown -R user:group ',
          summary: '递归修改目录或文件的所有者与所属组',
          keywords: ['owner', '归属', '属主'],
        ),
        QuickCommand(
          id: 'file-rsync',
          command: 'rsync -avz --progress src/ dst/',
          summary: '增量同步文件或目录并显示传输进度',
          keywords: ['sync', 'copy', 'backup', '同步', '备份'],
        ),
        QuickCommand(
          id: 'file-ln',
          command: 'ln -s target link_name',
          summary: '创建指向目标路径的软链接',
          keywords: ['symlink', '软链接', '符号链接'],
        ),
        QuickCommand(
          id: 'file-wc',
          command: 'wc -l ',
          summary: '统计文件总行数',
          keywords: ['count', 'lines', '行数'],
        ),
        QuickCommand(
          id: 'file-du-depth',
          command: 'du -h --max-depth=1',
          summary: '查看当前目录下一级子目录的磁盘占用大小',
          keywords: ['du', 'disk', '目录占用'],
        ),
        QuickCommand(
          id: 'file-find-clean-logs',
          command: 'find . -name "*.log" -mtime +7 -delete',
          summary: '删除当前目录下 7 天前的 .log 日志文件（慎用）',
          keywords: ['clean', 'log', 'mtime', '清理日志'],
        ),
        QuickCommand(
          id: 'file-sed-lines',
          command: "sed -n '1,100p' ",
          summary: '查看文件指定行号范围（第 1 到 100 行）内容',
          keywords: ['sed', 'range', '行号'],
        ),
        QuickCommand(
          id: 'file-awk-col',
          command: r"awk '{print $1}' ",
          summary: '按空白分隔提取文本指定列内容',
          keywords: ['awk', 'column', '提取列'],
        ),
        QuickCommand(
          id: 'file-unzip',
          command: 'unzip -q archive.zip -d dest/',
          summary: '静默解压 .zip 压缩包到指定目录',
          keywords: ['zip', 'extract', '解压'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'process',
      builtInId: QuickCommandCategoryId.process,
      title: '进程与服务',
      commands: [
        QuickCommand(
          id: 'proc-cpu',
          command: 'ps aux --sort=-%cpu | head -n 20',
          summary: '按 CPU 占用从高到低查看前 20 个进程',
          keywords: ['cpu', 'process', '高负载', '进程'],
        ),
        QuickCommand(
          id: 'proc-mem',
          command: 'ps aux --sort=-%mem | head -n 20',
          summary: '按内存占用从高到低查看前 20 个进程',
          keywords: ['memory', 'oom', '内存占用', '进程'],
        ),
        QuickCommand(
          id: 'proc-grep',
          command: 'ps -ef | grep ',
          summary: '按关键词筛选运行中的进程及其 PID',
          keywords: ['pid', 'search', '查找进程'],
        ),
        QuickCommand(
          id: 'proc-top',
          command: 'top -c',
          summary: '动态查看进程资源占用并显示完整启动命令',
          keywords: ['monitor', '实时监控'],
        ),
        QuickCommand(
          id: 'proc-kill-15',
          command: 'kill -15 ',
          summary: '向指定 PID 发送 SIGTERM，通知进程优雅退出',
          keywords: ['stop', 'sigterm', '优雅停止'],
        ),
        QuickCommand(
          id: 'proc-kill-9',
          command: 'kill -9 ',
          summary: '向指定 PID 发送 SIGKILL，强制终止无响应进程',
          keywords: ['force', 'sigkill', '强杀'],
        ),
        QuickCommand(
          id: 'proc-systemctl-status',
          command: 'systemctl status ',
          summary: '查看指定 systemd 服务的运行状态与近期日志',
          keywords: ['service', 'systemd', '服务状态'],
        ),
        QuickCommand(
          id: 'proc-systemctl-restart',
          command: 'systemctl restart ',
          summary: '重启指定的 systemd 服务',
          keywords: ['service', 'systemd', '重启服务'],
        ),
        QuickCommand(
          id: 'proc-systemctl-enable',
          command: 'systemctl enable --now ',
          summary: '立即启动服务并设置开机自启',
          keywords: ['service', 'autostart', '开机自启'],
        ),
        QuickCommand(
          id: 'proc-systemctl-failed',
          command: 'systemctl --failed',
          summary: '列出所有启动失败或异常的 systemd 服务',
          keywords: ['failed', 'error', '异常服务'],
        ),
        QuickCommand(
          id: 'proc-journalctl',
          command: 'journalctl -u service -f -n 100',
          summary: '实时查看指定服务的最近 100 条 systemd 日志',
          keywords: ['log', 'systemd', '服务日志'],
        ),
        QuickCommand(
          id: 'proc-crontab',
          command: 'crontab -l',
          summary: '查看当前用户的定时任务列表',
          keywords: ['cron', 'schedule', '计划任务', '定时任务'],
        ),
        QuickCommand(
          id: 'proc-systemctl-start',
          command: 'systemctl start ',
          summary: '启动指定的 systemd 服务',
          keywords: ['service', 'systemd', '启动服务'],
        ),
        QuickCommand(
          id: 'proc-systemctl-stop',
          command: 'systemctl stop ',
          summary: '停止指定的 systemd 服务',
          keywords: ['service', 'systemd', '停止服务'],
        ),
        QuickCommand(
          id: 'proc-systemctl-reload-daemon',
          command: 'systemctl daemon-reload',
          summary: '重新加载修改后的 systemd 服务单元配置',
          keywords: ['systemd', 'reload', '重载单元'],
        ),
        QuickCommand(
          id: 'proc-systemctl-enabled',
          command: 'systemctl list-unit-files --type=service --state=enabled',
          summary: '查看所有已设置开机自启的系统服务',
          keywords: ['service', 'autostart', '自启服务'],
        ),
        QuickCommand(
          id: 'proc-journalctl-err',
          command: 'journalctl -p err -n 50 --no-pager',
          summary: '查看最近 50 条错误级别及以上的系统日志',
          keywords: ['log', 'error', 'systemd', '错误日志'],
        ),
        QuickCommand(
          id: 'proc-pstree',
          command: 'pstree -p',
          summary: '以树形结构查看进程父子关系与 PID',
          keywords: ['tree', 'pid', '进程树'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'network',
      builtInId: QuickCommandCategoryId.network,
      title: '网络',
      commands: [
        QuickCommand(
          id: 'net-ip-addr',
          command: 'ip addr',
          summary: '查看网卡列表与 IPv4/IPv6 地址配置',
          keywords: ['ip', 'nic', 'ifconfig', '网卡'],
        ),
        QuickCommand(
          id: 'net-ip-route',
          command: 'ip route',
          summary: '查看系统路由表与默认网关',
          keywords: ['route', 'gateway', '路由', '网关'],
        ),
        QuickCommand(
          id: 'net-ss',
          command: 'ss -tulpn',
          summary: '查看所有监听中的 TCP/UDP 端口及对应进程',
          keywords: ['port', 'listen', 'netstat', '端口', '监听'],
        ),
        QuickCommand(
          id: 'net-lsof-port',
          command: 'lsof -i :8080',
          summary: '查看占用指定端口的进程详情',
          keywords: ['port', 'pid', '端口占用'],
        ),
        QuickCommand(
          id: 'net-curl-head',
          command: 'curl -I https://',
          summary: '仅请求并查看目标 URL 的 HTTP 响应头',
          keywords: ['http', 'header', '状态码', '响应头'],
        ),
        QuickCommand(
          id: 'net-curl-verbose',
          command: 'curl -vk https://',
          summary: '调试 HTTPS 请求，输出握手过程与详细头信息',
          keywords: ['http', 'tls', 'ssl', 'debug', '调试'],
        ),
        QuickCommand(
          id: 'net-nc',
          command: 'nc -zv host 443',
          summary: '测试目标主机指定 TCP 端口是否连通',
          keywords: ['telnet', 'port', 'connect', '连通性', '测端口'],
        ),
        QuickCommand(
          id: 'net-dig',
          command: 'dig +short ',
          summary: '快速查询域名 DNS 解析记录',
          keywords: ['dns', 'nslookup', '域名解析'],
        ),
        QuickCommand(
          id: 'net-traceroute',
          command: 'traceroute ',
          summary: '追踪数据包到达目标主机的网络路由跳点',
          keywords: ['trace', 'hop', '路由追踪'],
        ),
        QuickCommand(
          id: 'net-tcpdump',
          command: 'tcpdump -i any port 80 -nn',
          summary: '抓取指定端口的网络数据包（不解析主机名与端口名）',
          keywords: ['packet', 'capture', '抓包'],
        ),
        QuickCommand(
          id: 'net-firewalld',
          command: 'firewall-cmd --list-all',
          summary: '查看 firewalld 当前区域的放行规则',
          keywords: ['firewall', 'firewalld', '防火墙'],
        ),
        QuickCommand(
          id: 'net-ufw',
          command: 'ufw status verbose',
          summary: '查看 ufw 防火墙启用状态与详细规则',
          keywords: ['firewall', 'ufw', '防火墙'],
        ),
        QuickCommand(
          id: 'net-ss-summary',
          command: 'ss -s',
          summary: '汇总查看各协议与状态的 Socket 连接数量统计',
          keywords: ['socket', 'tcp', 'connections', '连接统计'],
        ),
        QuickCommand(
          id: 'net-ping',
          command: 'ping -c 4 ',
          summary: '发送 4 个 ICMP 探测包测试网络连通性与延迟',
          keywords: ['icmp', 'latency', '延迟', '连通性'],
        ),
        QuickCommand(
          id: 'net-mtr',
          command: 'mtr -rwc 10 ',
          summary: '结合 ping 与路由追踪输出 10 次丢包与延迟报告',
          keywords: ['route', 'packet loss', '丢包', '路由诊断'],
        ),
        QuickCommand(
          id: 'net-public-ip',
          command: 'curl -sS ifconfig.me',
          summary: '查询当前服务器的公网出口 IP 地址',
          keywords: ['ip', 'egress', '公网ip', '出口ip'],
        ),
        QuickCommand(
          id: 'net-curl-timing',
          command: r'curl -o /dev/null -s -w "dns:%{time_namelookup}s conn:%{time_connect}s ttfb:%{time_starttransfer}s total:%{time_total}s\n" https://',
          summary: '测量目标 URL 的 DNS、建连、首字节与总耗时',
          keywords: ['http', 'ttfb', 'latency', '耗时', '测速'],
        ),
        QuickCommand(
          id: 'net-iptables',
          command: 'iptables -L -n -v --line-numbers',
          summary: '查看 iptables 规则链、编号及数据包命中计数',
          keywords: ['firewall', 'iptables', '防火墙'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'docker',
      builtInId: QuickCommandCategoryId.docker,
      title: 'Docker',
      commands: [
        QuickCommand(
          id: 'docker-ps',
          command: 'docker ps -a',
          summary: '列出所有容器（包含已停止的容器）',
          keywords: ['container', 'list', '容器列表'],
        ),
        QuickCommand(
          id: 'docker-images',
          command: 'docker images',
          summary: '列出本地所有 Docker 镜像及占用空间',
          keywords: ['image', '镜像'],
        ),
        QuickCommand(
          id: 'docker-logs',
          command: 'docker logs -f --tail 100 ',
          summary: '实时查看容器最近 100 行日志',
          keywords: ['log', '容器日志'],
        ),
        QuickCommand(
          id: 'docker-exec',
          command: 'docker exec -it <container> sh',
          summary: '进入运行中容器的交互式终端',
          keywords: ['shell', 'bash', '进入容器'],
        ),
        QuickCommand(
          id: 'docker-stats',
          command: 'docker stats --no-stream',
          summary: '获取所有运行中容器的 CPU/内存/网络实时快照',
          keywords: ['cpu', 'memory', '资源监控'],
        ),
        QuickCommand(
          id: 'docker-inspect',
          command: 'docker inspect ',
          summary: '查看容器、镜像或网络的完整 JSON 元数据',
          keywords: ['metadata', 'ip', 'mount', '详情'],
        ),
        QuickCommand(
          id: 'docker-restart',
          command: 'docker restart ',
          summary: '重启指定容器',
          keywords: ['restart', '重启容器'],
        ),
        QuickCommand(
          id: 'docker-df',
          command: 'docker system df',
          summary: '查看镜像、容器、数据卷与构建缓存的磁盘占用',
          keywords: ['disk', 'space', '空间占用'],
        ),
        QuickCommand(
          id: 'docker-prune',
          command: 'docker system prune -f',
          summary: '清理未使用的容器、网络与悬空镜像',
          keywords: ['clean', 'cleanup', '清理'],
        ),
        QuickCommand(
          id: 'docker-compose-ps',
          command: 'docker compose ps',
          summary: '查看当前 Compose 项目的服务容器状态',
          keywords: ['compose', '编排状态'],
        ),
        QuickCommand(
          id: 'docker-compose-up',
          command: 'docker compose up -d',
          summary: '后台创建并启动 Compose 编排服务',
          keywords: ['compose', 'deploy', '启动服务'],
        ),
        QuickCommand(
          id: 'docker-compose-logs',
          command: 'docker compose logs -f --tail 100',
          summary: '实时跟踪 Compose 所有服务的最近 100 行日志',
          keywords: ['compose', 'log', '编排日志'],
        ),
        QuickCommand(
          id: 'docker-ps-table',
          command:
              r'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"',
          summary: '以精简表格查看运行中容器的名称、状态与端口映射',
          keywords: ['container', 'ports', '表格', '端口映射'],
        ),
        QuickCommand(
          id: 'docker-stop',
          command: 'docker stop ',
          summary: '优雅停止指定运行中的容器',
          keywords: ['stop', 'container', '停止容器'],
        ),
        QuickCommand(
          id: 'docker-rm',
          command: 'docker rm -f ',
          summary: '强制删除指定容器',
          keywords: ['remove', 'delete', '删除容器'],
        ),
        QuickCommand(
          id: 'docker-rmi',
          command: 'docker rmi ',
          summary: '删除本地指定 Docker 镜像',
          keywords: ['image', 'remove', '删除镜像'],
        ),
        QuickCommand(
          id: 'docker-network-ls',
          command: 'docker network ls',
          summary: '列出所有 Docker 网络',
          keywords: ['network', '容器网络'],
        ),
        QuickCommand(
          id: 'docker-volume-ls',
          command: 'docker volume ls',
          summary: '列出所有 Docker 数据卷',
          keywords: ['volume', 'storage', '数据卷'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'kubernetes',
      builtInId: QuickCommandCategoryId.kubernetes,
      title: 'Kubernetes',
      commands: [
        QuickCommand(
          id: 'k8s-nodes',
          command: 'kubectl get nodes -o wide',
          summary: '查看集群所有节点状态、IP 与容器运行时信息',
          keywords: ['k8s', 'node', '集群节点'],
        ),
        QuickCommand(
          id: 'k8s-pods-all',
          command: 'kubectl get pods -A',
          summary: '查看所有命名空间下的 Pod 运行状态',
          keywords: ['k8s', 'pod', 'namespace', '全部pod'],
        ),
        QuickCommand(
          id: 'k8s-pods-wide',
          command: 'kubectl get pods -o wide',
          summary: '查看当前命名空间 Pod 及所在节点与 Pod IP',
          keywords: ['k8s', 'pod', 'ip'],
        ),
        QuickCommand(
          id: 'k8s-describe-pod',
          command: 'kubectl describe pod ',
          summary: '查看指定 Pod 的详细配置与事件排查原因',
          keywords: ['k8s', 'describe', 'debug', '排查'],
        ),
        QuickCommand(
          id: 'k8s-logs',
          command: 'kubectl logs -f --tail=100 ',
          summary: '实时跟踪指定 Pod 最近 100 行容器日志',
          keywords: ['k8s', 'log', '容器日志'],
        ),
        QuickCommand(
          id: 'k8s-exec',
          command: 'kubectl exec -it <pod> -- sh',
          summary: '进入运行中 Pod 容器的交互式终端',
          keywords: ['k8s', 'shell', 'bash', '进入容器'],
        ),
        QuickCommand(
          id: 'k8s-svc-ing',
          command: 'kubectl get svc,ing -A',
          summary: '查看所有命名空间的 Service 与 Ingress 资源',
          keywords: ['k8s', 'service', 'ingress', '路由'],
        ),
        QuickCommand(
          id: 'k8s-events',
          command: 'kubectl get events --sort-by=.metadata.creationTimestamp',
          summary: '按时间顺序查看集群近期事件',
          keywords: ['k8s', 'event', '告警', '事件'],
        ),
        QuickCommand(
          id: 'k8s-top-pods',
          command: 'kubectl top pods -A',
          summary: '查看所有 Pod 的实时 CPU 与内存占用',
          keywords: ['k8s', 'cpu', 'memory', '资源监控'],
        ),
        QuickCommand(
          id: 'k8s-top-nodes',
          command: 'kubectl top nodes',
          summary: '查看集群各节点的实时 CPU 与内存占用',
          keywords: ['k8s', 'node', 'cpu', 'memory'],
        ),
        QuickCommand(
          id: 'k8s-rollout-status',
          command: 'kubectl rollout status deployment/',
          summary: '查看指定 Deployment 的滚动发布进度',
          keywords: ['k8s', 'deploy', 'rollout', '发布状态'],
        ),
        QuickCommand(
          id: 'k8s-rollout-restart',
          command: 'kubectl rollout restart deployment/',
          summary: '触发指定 Deployment 无中断滚动重启',
          keywords: ['k8s', 'restart', '滚动重启'],
        ),
        QuickCommand(
          id: 'k8s-rollout-undo',
          command: 'kubectl rollout undo deployment/',
          summary: '将指定 Deployment 回滚到上一个历史版本',
          keywords: ['k8s', 'rollback', 'undo', '回滚'],
        ),
        QuickCommand(
          id: 'k8s-contexts',
          command: 'kubectl config get-contexts',
          summary: '查看本地 kubeconfig 中的所有集群上下文',
          keywords: ['k8s', 'context', 'cluster', '上下文'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'database',
      builtInId: QuickCommandCategoryId.database,
      title: '数据库',
      commands: [
        QuickCommand(
          id: 'db-mysql-login',
          command: 'mysql -u root -p',
          summary: '以交互方式登录本地 MySQL / MariaDB',
          keywords: ['mysql', 'mariadb', 'sql', '登录'],
        ),
        QuickCommand(
          id: 'db-mysqldump',
          command: 'mysqldump -u root -p db_name > backup.sql',
          summary: '导出指定 MySQL 数据库为 SQL 备份文件',
          keywords: ['mysql', 'backup', 'export', '备份', '导出'],
        ),
        QuickCommand(
          id: 'db-mysql-restore',
          command: 'mysql -u root -p db_name < backup.sql',
          summary: '从 SQL 备份文件恢复到指定 MySQL 数据库',
          keywords: ['mysql', 'restore', 'import', '恢复', '导入'],
        ),
        QuickCommand(
          id: 'db-mysql-processlist',
          command: 'mysqladmin -u root -p processlist',
          summary: '查看 MySQL 当前活跃连接与正在执行的查询',
          keywords: ['mysql', 'slow', 'connection', '连接数', '慢查询'],
        ),
        QuickCommand(
          id: 'db-psql',
          command: 'psql -U postgres -d postgres',
          summary: '登录本地 PostgreSQL 交互命令行',
          keywords: ['postgres', 'postgresql', 'pg', '登录'],
        ),
        QuickCommand(
          id: 'db-pg-dump',
          command: 'pg_dump -U postgres -Fc db_name > backup.dump',
          summary: '以自定义压缩格式备份 PostgreSQL 数据库',
          keywords: ['postgres', 'pg', 'backup', '备份'],
        ),
        QuickCommand(
          id: 'db-pg-restore',
          command: 'pg_restore -U postgres -d db_name backup.dump',
          summary: '将压缩备份恢复到指定 PostgreSQL 数据库',
          keywords: ['postgres', 'pg', 'restore', '恢复'],
        ),
        QuickCommand(
          id: 'db-redis-ping',
          command: 'redis-cli ping',
          summary: '检测本地 Redis 服务是否正常响应',
          keywords: ['redis', 'health', '检测'],
        ),
        QuickCommand(
          id: 'db-redis-memory',
          command: 'redis-cli info memory',
          summary: '查看 Redis 内存占用与淘汰策略详情',
          keywords: ['redis', 'memory', '内存'],
        ),
        QuickCommand(
          id: 'db-redis-bigkeys',
          command: 'redis-cli --bigkeys',
          summary: '扫描并统计 Redis 中占用空间较大的 Key',
          keywords: ['redis', 'bigkey', '大key'],
        ),
        QuickCommand(
          id: 'db-redis-monitor',
          command: 'redis-cli monitor',
          summary: '实时监听 Redis 正在执行的命令（生产慎用）',
          keywords: ['redis', 'debug', '监听'],
        ),
        QuickCommand(
          id: 'db-mongosh',
          command: 'mongosh',
          summary: '打开 MongoDB Shell 连接本地实例',
          keywords: ['mongo', 'mongodb', 'nosql'],
        ),
        QuickCommand(
          id: 'db-mysql-remote',
          command: 'mysql -h 127.0.0.1 -P 3306 -u root -p',
          summary: '指定主机与端口通过 TCP 登录 MySQL',
          keywords: ['mysql', 'tcp', 'remote', '远程连接'],
        ),
        QuickCommand(
          id: 'db-psql-remote',
          command: 'psql -h 127.0.0.1 -p 5432 -U postgres -d ',
          summary: '指定主机与端口登录 PostgreSQL 数据库',
          keywords: ['postgres', 'postgresql', 'remote', '远程连接'],
        ),
        QuickCommand(
          id: 'db-redis-auth',
          command: 'redis-cli -h 127.0.0.1 -p 6379 -a password',
          summary: '指定地址、端口与密码连接 Redis',
          keywords: ['redis', 'auth', 'password', '连接'],
        ),
        QuickCommand(
          id: 'db-redis-clients',
          command: 'redis-cli info clients',
          summary: '查看 Redis 当前客户端连接数与阻塞连接',
          keywords: ['redis', 'clients', '连接数'],
        ),
        QuickCommand(
          id: 'db-sqlite-tables',
          command: 'sqlite3 app.db ".tables"',
          summary: '列出 SQLite 数据库文件中的所有表',
          keywords: ['sqlite', 'tables', '数据表'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'nginx',
      builtInId: QuickCommandCategoryId.nginx,
      title: 'Web 与证书',
      commands: [
        QuickCommand(
          id: 'web-nginx-test',
          command: 'nginx -t',
          summary: '检查 Nginx 配置文件语法是否正确',
          keywords: ['nginx', 'config', 'syntax', '校验配置'],
        ),
        QuickCommand(
          id: 'web-nginx-reload',
          command: 'nginx -s reload',
          summary: '平滑重载 Nginx 配置而不中断现有连接',
          keywords: ['nginx', 'reload', '重载'],
        ),
        QuickCommand(
          id: 'web-nginx-dump',
          command: 'nginx -T',
          summary: '输出 Nginx 生效的完整汇总配置',
          keywords: ['nginx', 'config', '完整配置'],
        ),
        QuickCommand(
          id: 'web-nginx-version',
          command: 'nginx -V',
          summary: '查看 Nginx 版本号及编译参数与模块列表',
          keywords: ['nginx', 'module', '版本', '模块'],
        ),
        QuickCommand(
          id: 'web-nginx-error-log',
          command: 'tail -f /var/log/nginx/error.log',
          summary: '实时查看 Nginx 错误日志',
          keywords: ['nginx', 'log', 'error', '错误日志'],
        ),
        QuickCommand(
          id: 'web-nginx-access-log',
          command: 'tail -f /var/log/nginx/access.log',
          summary: '实时查看 Nginx 访问日志',
          keywords: ['nginx', 'log', 'access', '访问日志'],
        ),
        QuickCommand(
          id: 'web-ssl-dates',
          command: 'openssl s_client -connect host:443 -servername host < /dev/null 2>/dev/null | openssl x509 -noout -dates',
          summary: '查看远程 HTTPS 站点 SSL 证书的有效期',
          keywords: ['ssl', 'tls', 'cert', 'https', '证书', '过期'],
        ),
        QuickCommand(
          id: 'web-certbot-list',
          command: 'certbot certificates',
          summary: '查看本机 Certbot 管理的 SSL 证书与到期时间',
          keywords: ['certbot', 'letsencrypt', 'ssl', '证书'],
        ),
        QuickCommand(
          id: 'web-nginx-systemd-reload',
          command: 'systemctl reload nginx',
          summary: '通过 systemd 平滑重载 Nginx 服务',
          keywords: ['nginx', 'systemd', 'reload', '重载'],
        ),
        QuickCommand(
          id: 'web-nginx-top-ips',
          command: r"awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -nr | head -n 20",
          summary: '统计 Nginx 访问日志中请求量最高的前 20 个来源 IP',
          keywords: ['nginx', 'ip', 'traffic', '访问统计', '排障'],
        ),
        QuickCommand(
          id: 'web-nginx-status-codes',
          command: r"awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -nr",
          summary: '统计 Nginx 访问日志中各 HTTP 状态码的分布次数',
          keywords: ['nginx', '502', '500', 'status', '状态码'],
        ),
        QuickCommand(
          id: 'web-openssl-inspect',
          command: 'openssl x509 -in cert.pem -noout -text | head -n 30',
          summary: '查看本地 PEM 证书的颁发者、域名与有效期信息',
          keywords: ['ssl', 'tls', 'pem', 'cert', '证书详情'],
        ),
        QuickCommand(
          id: 'web-openssl-selfsigned',
          command: 'openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365',
          summary: '生成有效期 365 天的本地自签名 TLS 证书',
          keywords: ['ssl', 'tls', 'self-signed', '自签名证书'],
        ),
        QuickCommand(
          id: 'web-caddy-validate',
          command: 'caddy validate --config /etc/caddy/Caddyfile',
          summary: '校验 Caddy 配置文件语法是否正确',
          keywords: ['caddy', 'config', '校验配置'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'packages',
      builtInId: QuickCommandCategoryId.packages,
      title: '包管理与安全',
      commands: [
        QuickCommand(
          id: 'pkg-apt-upgradable',
          command: 'apt update && apt list --upgradable',
          summary: '刷新 Debian/Ubuntu 软件包索引并列出可更新包',
          keywords: ['apt', 'ubuntu', 'debian', '更新'],
        ),
        QuickCommand(
          id: 'pkg-apt-install',
          command: 'apt install -y ',
          summary: '在 Debian/Ubuntu 上安装指定软件包',
          keywords: ['apt', 'install', '安装'],
        ),
        QuickCommand(
          id: 'pkg-dnf-check',
          command: 'dnf check-update',
          summary: '检查 RHEL/Rocky/CentOS 系统中可用的软件包更新',
          keywords: ['dnf', 'yum', 'centos', 'rocky', '更新'],
        ),
        QuickCommand(
          id: 'pkg-dnf-install',
          command: 'dnf install -y ',
          summary: '在 RHEL/Rocky/CentOS 上安装指定软件包',
          keywords: ['dnf', 'yum', 'install', '安装'],
        ),
        QuickCommand(
          id: 'pkg-dpkg-grep',
          command: 'dpkg -l | grep ',
          summary: '在 Debian/Ubuntu 上搜索已安装的软件包',
          keywords: ['dpkg', 'debian', 'ubuntu', '已安装'],
        ),
        QuickCommand(
          id: 'pkg-rpm-grep',
          command: 'rpm -qa | grep ',
          summary: '在 RHEL/CentOS 上搜索已安装的 RPM 软件包',
          keywords: ['rpm', 'centos', 'rocky', '已安装'],
        ),
        QuickCommand(
          id: 'sec-ssh-keygen',
          command: 'ssh-keygen -t ed25519 -C ""',
          summary: '生成 Ed25519 算法 SSH 密钥对',
          keywords: ['ssh', 'key', 'ed25519', '密钥'],
        ),
        QuickCommand(
          id: 'sec-ssh-copy-id',
          command: 'ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host',
          summary: '将本地公钥追加到远程主机实现免密登录',
          keywords: ['ssh', 'pubkey', '免密登录'],
        ),
        QuickCommand(
          id: 'sec-ssh-chmod',
          command: 'chmod 600 ~/.ssh/authorized_keys',
          summary: '修复 SSH 公钥授权文件权限避免登录被拒',
          keywords: ['ssh', 'permission', 'authorized_keys', '权限'],
        ),
        QuickCommand(
          id: 'sec-sshd-test',
          command: 'sshd -t',
          summary: '检查 SSH 服务端配置文件 /etc/ssh/sshd_config 语法',
          keywords: ['sshd', 'config', 'ssh配置'],
        ),
        QuickCommand(
          id: 'sec-fail2ban',
          command: 'fail2ban-client status sshd',
          summary: '查看 fail2ban 对 SSH 暴力破解的封禁统计',
          keywords: ['fail2ban', 'ban', 'security', '防爆破'],
        ),
        QuickCommand(
          id: 'sec-sha256',
          command: 'sha256sum ',
          summary: '计算文件的 SHA-256 校验哈希值',
          keywords: ['hash', 'checksum', '校验'],
        ),
        QuickCommand(
          id: 'sec-login-users',
          command: 'cat /etc/passwd | grep -v nologin',
          summary: '列出系统中允许交互登录的账号',
          keywords: ['user', 'account', 'passwd', '登录账号'],
        ),
        QuickCommand(
          id: 'sec-sudo-list',
          command: 'sudo -l',
          summary: '查看当前用户被授予的 sudo 提权命令范围',
          keywords: ['sudo', 'privilege', '提权', '权限'],
        ),
      ],
    ),
    QuickCommandCategory(
      id: 'git',
      builtInId: QuickCommandCategoryId.git,
      title: 'Git',
      commands: [
        QuickCommand(
          id: 'git-status',
          command: 'git status -sb',
          summary: '以简洁模式查看工作区变更与当前分支状态',
          keywords: ['status', 'branch', '状态'],
        ),
        QuickCommand(
          id: 'git-log',
          command: 'git log --oneline -n 20',
          summary: '单行显示最近 20 条提交记录',
          keywords: ['log', 'history', 'commit', '提交历史'],
        ),
        QuickCommand(
          id: 'git-diff-stat',
          command: 'git diff --stat',
          summary: '查看当前未暂存改动的受影响文件统计',
          keywords: ['diff', 'changes', '变更'],
        ),
        QuickCommand(
          id: 'git-branch',
          command: 'git branch -vv',
          summary: '查看本地分支列表及关联的远程跟踪分支',
          keywords: ['branch', '分支'],
        ),
        QuickCommand(
          id: 'git-pull-rebase',
          command: 'git pull --rebase',
          summary: '拉取远程更新并以变基方式同步当前分支',
          keywords: ['pull', 'rebase', '拉取'],
        ),
        QuickCommand(
          id: 'git-fetch-prune',
          command: 'git fetch --all --prune',
          summary: '拉取所有远程分支并清理已删除的远程引用',
          keywords: ['fetch', 'prune', '同步远程'],
        ),
        QuickCommand(
          id: 'git-stash',
          command: 'git stash push -m ""',
          summary: '暂存当前未提交改动并附带备注说明',
          keywords: ['stash', '暂存'],
        ),
        QuickCommand(
          id: 'git-reflog',
          command: 'git reflog -n 20',
          summary: '查看 HEAD 操作历史，用于误操作回溯恢复',
          keywords: ['reflog', 'recover', '回滚', '恢复'],
        ),
        QuickCommand(
          id: 'git-log-graph',
          command: 'git log --graph --oneline --decorate -n 20',
          summary: '图形化查看最近 20 条分支与合并提交历史',
          keywords: ['log', 'graph', 'branch', '分支图'],
        ),
        QuickCommand(
          id: 'git-checkout-b',
          command: 'git checkout -b ',
          summary: '基于当前提交创建并切换到新分支',
          keywords: ['branch', 'checkout', '新建分支'],
        ),
        QuickCommand(
          id: 'git-stash-pop',
          command: 'git stash pop',
          summary: '恢复最近一次暂存的改动并从暂存栈移除',
          keywords: ['stash', 'pop', '恢复暂存'],
        ),
        QuickCommand(
          id: 'git-tag-list',
          command: 'git tag -l --sort=-v:refname | head -n 20',
          summary: '按版本号倒序列出最近 20 个 Git 标签',
          keywords: ['tag', 'release', 'version', '标签'],
        ),
      ],
    ),
  ];

  static List<QuickCommandCategory> combined(
    List<QuickCommandCategory> customGroups,
  ) => customGroups.isEmpty ? categories : [...customGroups, ...categories];

  static List<QuickCommandMatch> search(
    String query, {
    required String Function(String key) translate,
    List<QuickCommandCategory>? sourceCategories,
  }) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final results = <QuickCommandMatch>[];
    for (final category in sourceCategories ?? categories) {
      final displayCategory = category.isBuiltIn
          ? translate(category.title)
          : category.title;
      for (final command in category.commands) {
        final displaySummary = command.isBuiltIn
            ? translate(command.summary)
            : command.summary;
        if (command.matchesQuery(
          normalized,
          displaySummary: displaySummary,
          displayCategory: displayCategory,
        )) {
          results.add(QuickCommandMatch(category: category, command: command));
        }
      }
    }
    return results;
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
