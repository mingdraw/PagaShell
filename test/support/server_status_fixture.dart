import 'package:pagashell/domain/ssh/server_status.dart';

const linuxStatusOutput = '''
login banner
PAGASHELL_STATUS_OS
Linux
PAGASHELL_STATUS_OS_RELEASE
NAME="Ubuntu"
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
PAGASHELL_STATUS_UPTIME
1000.50 2000.0
PAGASHELL_STATUS_CPU
cpu 100 20 30 800 10 5 5 30 15 2
cpu0 50 10 15 400 5 2 3 15 7 1
cpu1 50 10 15 400 5 3 2 15 8 1
PAGASHELL_STATUS_MEMORY
MemTotal: 1048576 kB
MemFree: 102400 kB
MemAvailable: 262144 kB
Buffers: 1024 kB
Cached: 4096 kB
PAGASHELL_STATUS_NETWORK
Inter-| Receive | Transmit
 face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed
lo: 500 1 0 0 0 0 0 0 500 1 0 0 0 0 0 0
eth0: 4096 1 0 0 0 0 0 0 2048 1 0 0 0 0 0 0
PAGASHELL_STATUS_DISKS
nvme0n1 10 0 100 5 20 0 200 10 0 15 15 0 0 0 0 0 0
PAGASHELL_STATUS_FILESYSTEMS
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 10485760 5242880 4718592 53% /
/dev/sdb1 2048 1024 1024 50% /data with spaces
PAGASHELL_STATUS_END
''';

const macStatusOutput = '''
PAGASHELL_STATUS_OS
Darwin
PAGASHELL_STATUS_MAC_VERSION
15.0.1
PAGASHELL_STATUS_MAC_CPU
CPU usage: 0.0% user, 0.0% sys, 100.0% idle
CPU usage: 20.0% user, 10.0% sys, 70.0% idle
PAGASHELL_STATUS_MAC_CPU_CORES
cpu0 1000 800
cpu1 1200 900
PAGASHELL_STATUS_UPTIME
1000
PAGASHELL_STATUS_MAC_MEMORY
1073741824
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free: 4096.
Pages active: 40960.
Pages inactive: 8192.
Pages speculative: 4096.
Pages wired down: 4096.
Pages occupied by compressor: 4096.
PAGASHELL_STATUS_MAC_NETWORK
Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
lo0 16384 <Link#1> 100 0 10000 100 0 10000 0
en0 1500 <Link#2> aa:bb:cc:dd:ee:ff 10 0 4096 20 0 2048 0
en0 1500 192.0.2 192.0.2.1 10 - 4096 20 - 2048 -
utun0 1380 <Link#3> 10 0 1024 20 0 512 0
gif0* 1280 <Link#4> 0 0 0 0 0 0 0
PAGASHELL_STATUS_MAC_DISKS
+-o IOBlockStorageDriver <class IOBlockStorageDriver, id 0x100001>
"Statistics" = {"Bytes (Read)"=8192,"Bytes (Write)"=4096}
"BSD Name" = "disk0"
+-o IOBlockStorageDriver <class IOBlockStorageDriver, id 0x100002>
"Statistics" = {"Bytes (Read)"=1024,"Bytes (Write)"=512}
"BSD Name" = "disk4"
PAGASHELL_STATUS_FILESYSTEMS
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1s1 1048576 524288 524288 50% /
PAGASHELL_STATUS_MAC_DISK_NAME
Macintosh HD
PAGASHELL_STATUS_END
''';

ServerStatusSample statusSample({
  String system = 'Linux',
  String? systemRelease,
  double? measuredCpuFraction,
  double uptime = 1000,
  int cpu = 1000,
  int idle = 800,
  Map<int, CpuCounters> cpuCores = const {},
  int read = 4096,
  int write = 2048,
}) => ServerStatusSample(
  system: system,
  systemRelease: systemRelease,
  measuredCpuFraction: measuredCpuFraction,
  uptimeSeconds: uptime,
  cpuTotal: cpu,
  cpuIdle: idle,
  cpuCores: cpuCores,
  memoryTotal: 1024 * 1024 * 1024,
  memoryAvailable: 256 * 1024 * 1024,
  filesystems: [
    FilesystemUsage(
      mount: '/',
      name: system == 'macOS' ? 'Macintosh HD' : null,
      total: 1024 * 1024 * 1024,
      used: 512 * 1024 * 1024,
      available: 512 * 1024 * 1024,
    ),
  ],
  network: {'eth0': IoCounters(read, write)},
  disks: {'nvme0n1': IoCounters(read * 2, write * 2)},
);
