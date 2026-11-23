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
            parsed=$(printf '%s\n' "$info" | awk '
                /<key>TotalSize<\/key>/ { want="size"; next }
                /<key>SolidState<\/key>/ { want="solid"; next }
                want=="size" {
                    gsub(/[^0-9]/, "", $0)
                    bytes=$0
                    want=""
                    next
                }
                want=="solid" {
                    if ($0 ~ /<true\/>/) rotation="0"
                    else if ($0 ~ /<false\/>/) rotation="1"
                    want=""
                    next
                }
                END { printf "%s|%s\n", bytes, rotation }
            ')
            field disk "$disk|$parsed"
        done
fi
if [ "$system" = Linux ]; then
    for pair in \
        fs.file-max:/proc/sys/fs/file-max \
        fs.nr_open:/proc/sys/fs/nr_open \
        net.core.somaxconn:/proc/sys/net/core/somaxconn \
        net.ipv4.tcp_max_syn_backlog:/proc/sys/net/ipv4/tcp_max_syn_backlog \
        net.ipv4.ip_local_port_range:/proc/sys/net/ipv4/ip_local_port_range \
        net.ipv4.tcp_tw_reuse:/proc/sys/net/ipv4/tcp_tw_reuse \
        vm.swappiness:/proc/sys/vm/swappiness \
        vm.overcommit_memory:/proc/sys/vm/overcommit_memory \
        net.ipv4.tcp_congestion_control:/proc/sys/net/ipv4/tcp_congestion_control; do
        key=${pair%%:*}
        path=${pair#*:}
        if [ -r "$path" ] && IFS= read -r value < "$path"; then
            field "sysctl.$key" "$value"
        fi
    done
elif [ "$system" = Darwin ]; then
    sysctl kern.maxfiles kern.maxfilesperproc 2>/dev/null |
        awk -F': ' 'NF==2{printf "sysctl.%s=%s\n",$1,$2}'
fi
found_services=
unit_list=
for service in mysqld mariadbd mysql postgres redis-server nginx caddy haproxy \
    docker podman java node python3 php supervisord; do
    command -v "$service" >/dev/null 2>&1 || continue
    found_services="$found_services $service"
    if [ -d /run/systemd/system ]; then
        unit=$service
        case "$service" in
            mysqld|mysql) unit=mysql ;;
            mariadbd) unit=mariadb ;;
            postgres) unit=postgresql ;;
        esac
        unit_list="$unit_list $unit.service"
    fi
done
unit_statuses=
if [ -n "$unit_list" ] && [ -d /run/systemd/system ]; then
    # Single D-Bus round-trip for all detected services.
    # shellcheck disable=SC2086
    unit_statuses=$(systemctl is-active $unit_list 2>/dev/null || :)
fi
has_timeout=0
if command -v timeout >/dev/null 2>&1 && timeout 1 true >/dev/null 2>&1; then
    has_timeout=1
fi
run_version() {
    if [ "$1" = java ]; then
        jhome=${JAVA_HOME:-}
        if [ -z "$jhome" ]; then
            jbin=$(command -v java 2>/dev/null || :)
            if [ -n "$jbin" ] && command -v readlink >/dev/null 2>&1; then
                jreal=$(readlink -f "$jbin" 2>/dev/null || :)
                [ -z "$jreal" ] || jbin=$jreal
            fi
            jhome=${jbin%/bin/java}
        fi
        if [ -n "$jhome" ] && [ -r "$jhome/release" ]; then
            jver=$(awk -F= '/^JAVA_VERSION=/{gsub(/"/,"",$2); print "java " $2; exit}' "$jhome/release" 2>/dev/null)
            if [ -n "$jver" ]; then
                printf '%s\n' "$jver"
                return 0
            fi
        fi
    fi
    if [ "$has_timeout" = 1 ]; then
        timeout 2 "$1" "$2" </dev/null 2>&1 | head -n 1 | tr '|' ' '
    else
        "$1" "$2" </dev/null 2>&1 | head -n 1 | tr '|' ' '
    fi
}
idx=0
for service in $found_services; do
    idx=$((idx + 1))
    status=
    if [ -n "$unit_statuses" ]; then
        status=$(printf '%s\n' "$unit_statuses" | awk -v n="$idx" 'NR==n{print; exit}')
    fi
    case "$service" in
        nginx|haproxy) arg=-v ;;
        java) arg=-version ;;
        *) arg=--version ;;
    esac
    (
        version=$(run_version "$service" "$arg")
        field service "$service|$version|$status"
    ) &
done
wait
exit 0
