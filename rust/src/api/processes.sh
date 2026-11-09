LC_ALL=C
export LC_ALL
printf 'PAGA_PROCESSES_V1\n'
case "$(uname -s)" in
  Linux)
    memory=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)
    # uptime 不受系统时钟校准影响，CPU 利用率用相邻采样的增量计算。
    measured=$(awk '{print $1}' /proc/uptime)
    ;;
  Darwin)
    memory=$(sysctl -n hw.memsize 2>/dev/null)
    measured=$(date +%s)
    ;;
  *) printf 'UNSUPPORTED\nPAGA_PROCESSES_END\n'; exit 0 ;;
esac
printf 'TIME %s\nMEMORY %s\nPROCESSES\n' "$measured" "$memory"
# comm 不包含命令行参数，避免采集参数中的密码和 token。
ps -ww -A -o pid= -o user= -o pcpu= -o rss= -o time= -o lstart= -o comm= 2>/dev/null || exit 1
printf 'PAGA_PROCESSES_END\n'
