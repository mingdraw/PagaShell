# No process arguments, environment, service configs or credentials.
LC_ALL=C
export LC_ALL
field() { printf '%s=%s\n' "$1" "$2"; }
system=$(uname -s) || exit 69
field system "$system"
field kernel "$(uname -r)"
field architecture "$(uname -m)"
if [ "$system" = Linux ]; then
    for os_release in /etc/os-release /usr/lib/os-release; do
        [ -r "$os_release" ] || continue
        awk -F= '/^(ID|VERSION_ID|PRETTY_NAME)=/{print}' "$os_release"
        break
    done
elif [ "$system" = Darwin ]; then
    field PRETTY_NAME "$(sw_vers -productName)"
    field VERSION_ID "$(sw_vers -productVersion)"
fi
if command -v systemd-detect-virt >/dev/null 2>&1; then
    field virtualization "$(systemd-detect-virt 2>/dev/null || :)"
elif [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    field virtualization container
fi
if [ "$system" = Darwin ]; then
    field init launchd
elif [ -d /run/systemd/system ]; then
    field init systemd
elif command -v rc-status >/dev/null 2>&1; then
    field init openrc
elif [ -x /sbin/init ]; then
    field init sysvinit
fi
uid=$(id -u)
field user "$(id -un)"
if [ "$uid" = 0 ]; then
    field privilege root
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    field privilege sudo_noninteractive
else
    field privilege user
fi
for manager in apt-get dnf yum apk pacman zypper brew; do
    command -v "$manager" >/dev/null 2>&1 && field package "$manager"
done
field cpu_cores "$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null)"
field nofile_soft "$(ulimit -Sn 2>/dev/null)"
field nofile_hard "$(ulimit -Hn 2>/dev/null)"
if [ "$system" = Linux ]; then
    awk '
        /^MemTotal:/{printf "memory_bytes=%.0f\n",$2*1024}
        /^MemAvailable:/{printf "available_bytes=%.0f\n",$2*1024}
        /^SwapTotal:/{printf "swap_bytes=%.0f\n",$2*1024}
        /^SwapFree:/{printf "swap_free_bytes=%.0f\n",$2*1024}
    ' /proc/meminfo 2>/dev/null
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -bdn -o NAME,SIZE,ROTA,TYPE 2>/dev/null |
            awk '$4=="disk"{printf "disk=%s|%s|%s\n",$1,$2,$3}'
    fi
    field thp "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
elif [ "$system" = Darwin ]; then
    field memory_bytes "$(sysctl -n hw.memsize 2>/dev/null)"
    field swap_usage "$(sysctl -n vm.swapusage 2>/dev/null)"
    vm_stat 2>/dev/null | awk '
        NR==1 {for(i=1;i<NF;i++) if($i=="of") pagesize=$(i+1)}
        /^Pages (free|inactive|speculative):/{sum+=$NF}
        END{if(pagesize>0) printf "available_bytes=%.0f\n",sum*pagesize}
    '
    diskutil list physical 2>/dev/null |
        awk '/^\/dev\/disk[0-9]+ /{print substr($1,6); if(++n==8)exit}' |
        while IFS= read -r disk; do
            info=$(diskutil info -plist "$disk" 2>/dev/null) || continue
            bytes=$(printf '%s\n' "$info" | plutil -extract TotalSize raw -o - - 2>/dev/null)
            solid=$(printf '%s\n' "$info" | plutil -extract SolidState raw -o - - 2>/dev/null)
            case "$solid" in true|1) rotation=0 ;; false|0) rotation=1 ;; *) rotation= ;; esac
            field disk "$disk|$bytes|$rotation"
        done
fi
for key in fs.file-max fs.nr_open net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
    net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse vm.swappiness \
    vm.overcommit_memory net.ipv4.tcp_congestion_control kern.maxfiles kern.maxfilesperproc; do
    value=$(sysctl -n "$key" 2>/dev/null) && field "sysctl.$key" "$value"
done
for service in mysqld mariadbd mysql postgres redis-server nginx caddy haproxy \
    docker podman java node python3 php supervisord; do
    command -v "$service" >/dev/null 2>&1 || continue
    case "$service" in
        nginx|haproxy) arg=-v ;;
        java) arg=-version ;;
        *) arg=--version ;;
    esac
    version=$("$service" "$arg" </dev/null 2>&1 | head -n 1 | tr '|' ' ')
    status=
    if [ -d /run/systemd/system ]; then
        unit=$service
        case "$service" in
            mysqld|mysql) unit=mysql ;;
            mariadbd) unit=mariadb ;;
            postgres) unit=postgresql ;;
        esac
        status=$(systemctl is-active "$unit.service" 2>/dev/null || :)
    fi
    field service "$service|$version|$status"
done
exit 0
