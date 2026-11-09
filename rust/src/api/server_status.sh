#!/bin/sh
# Read-only Linux/macOS snapshot. No agent, sudo, or remote files written.
LC_ALL=C
export LC_ALL
printf 'PAGASHELL_STATUS_OS\n'
status_os=$(uname -s)
printf '%s\n' "$status_os"
case "$status_os" in Linux|Darwin) ;; *) exit 0 ;; esac
set -e
printf 'PAGASHELL_STATUS_ARCHITECTURE\n'
uname -m 2>/dev/null || true
if [ "$status_os" = Darwin ]; then
  printf 'PAGASHELL_STATUS_MAC_VERSION\n'
  /usr/bin/sw_vers -productVersion 2>/dev/null || true
  printf 'PAGASHELL_STATUS_MAC_CPU\n'
  /usr/bin/top -l 2 -s 1 -n 0 -R -F
  printf 'PAGASHELL_STATUS_MAC_CPU_CORES\n'
  # JXA bridges the system Mach API without a remote agent or extra runtime.
  # Failure leaves per-core data unavailable while other metrics keep working.
  /usr/bin/osascript -l JavaScript 2>/dev/null <<'PAGASHELL_CPU_JXA' || true
ObjC.bindFunction('mach_host_self', ['unsigned int', []]);
ObjC.bindFunction('host_processor_info', ['int', ['unsigned int', 'int', 'unsigned int *', 'int **', 'unsigned int *']]);
var count = Ref();
var info = Ref();
var length = Ref();
if ($.host_processor_info($.mach_host_self(), 2, count, info, length) !== 0 || length[0] < count[0] * 4) {
  throw new Error('CPU counters unavailable');
}
var ticks = info[0];
var lines = [];
for (var core = 0; core < count[0]; core++) {
  // PROCESSOR_CPU_LOAD_INFO: user, system, idle, nice (unsigned 32-bit ticks).
  var offset = core * 4;
  var user = ticks[offset] >>> 0;
  var system = ticks[offset + 1] >>> 0;
  var idle = ticks[offset + 2] >>> 0;
  var nice = ticks[offset + 3] >>> 0;
  lines.push('cpu' + core + ' ' + (user + system + idle + nice) + ' ' + idle);
}
lines.join('\n');
PAGASHELL_CPU_JXA
  printf 'PAGASHELL_STATUS_UPTIME\n'
  status_boot=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk '{gsub(/,/, "", $4); print $4}')
  printf '%s\n' "$(( $(/bin/date +%s) - status_boot ))"
  printf 'PAGASHELL_STATUS_MAC_MEMORY\n'
  /usr/sbin/sysctl -n hw.memsize
  /usr/bin/vm_stat
  printf 'PAGASHELL_STATUS_MAC_SWAP\n'
  /usr/sbin/sysctl -n vm.swapusage 2>/dev/null || true
  printf 'PAGASHELL_STATUS_LOAD\n'
  /usr/sbin/sysctl -n vm.loadavg 2>/dev/null || true
  printf 'PAGASHELL_STATUS_MAC_NETWORK\n'
  /usr/sbin/netstat -ibn
  printf 'PAGASHELL_STATUS_MAC_DISKS\n'
  /usr/sbin/ioreg -r -c IOBlockStorageDriver -l -w 0 -d 2
  printf 'PAGASHELL_STATUS_FILESYSTEMS\n'
  /bin/df -Pkl 2>/dev/null || true
  printf 'PAGASHELL_STATUS_MAC_STORAGE\n'
  # Physical devices exclude mounted disk images. APFS containers retain shared
  # free space separately from each volume's own usage.
  /usr/sbin/diskutil list -plist physical 2>/dev/null |
    /usr/bin/plutil -convert json -o - - 2>/dev/null || true
  printf '\nPAGASHELL_STATUS_MAC_APFS\n'
  /usr/sbin/diskutil apfs list -plist 2>/dev/null |
    /usr/bin/plutil -convert json -o - - 2>/dev/null || true
  printf '\n'
  printf 'PAGASHELL_STATUS_END\n'
  exit 0
fi
printf 'PAGASHELL_STATUS_OS_RELEASE\n'
if [ -r /etc/os-release ]; then
  cat /etc/os-release || true
elif [ -r /usr/lib/os-release ]; then
  cat /usr/lib/os-release || true
fi
printf 'PAGASHELL_STATUS_UPTIME\n'
cat /proc/uptime
printf 'PAGASHELL_STATUS_LOAD\n'
cat /proc/loadavg 2>/dev/null || true
printf 'PAGASHELL_STATUS_CPU\n'
awk '/^cpu[0-9]*[[:space:]]/ { print }' /proc/stat
printf 'PAGASHELL_STATUS_MEMORY\n'
cat /proc/meminfo
printf 'PAGASHELL_STATUS_NETWORK\n'
cat /proc/net/dev
printf 'PAGASHELL_STATUS_DISKS\n'
# Whole devices only: avoid counting partitions and virtual mappings twice.
for device in /sys/block/*; do
  name=${device##*/}
  case "$name" in loop*|ram*|zram*|dm-*|md*) continue ;; esac
  [ -r "$device/stat" ] || continue
  printf '%s ' "$name"
  cat "$device/stat"
done
printf 'PAGASHELL_STATUS_LINUX_STORAGE\n'
# Optional topology; older/minimal hosts still report df data if unavailable.
if ! lsblk -b -J -p -o NAME,KNAME,PKNAME,TYPE,SIZE,LABEL,UUID 2>/dev/null; then
  printf '\nPAGASHELL_STATUS_LINUX_DEVICE_ALIASES\n'
  # Minimal hosts may lack lsblk JSON support; still resolve mapper aliases so
  # one filesystem is not counted again under its dm-N device name.
  for status_alias in /dev/root /dev/mapper/* /dev/disk/by-uuid/* /dev/disk/by-label/*; do
    [ -b "$status_alias" ] || continue
    status_target=$(readlink -f "$status_alias" 2>/dev/null) || continue
    printf '%s\t%s\n' "$status_alias" "$status_target"
  done
fi
printf '\n'
printf 'PAGASHELL_STATUS_FILESYSTEMS\n'
df -Pk -l -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || true
printf 'PAGASHELL_STATUS_END\n'
