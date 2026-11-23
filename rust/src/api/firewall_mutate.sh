LC_ALL=C
export LC_ALL

fw_system=$(uname -s)
[ "$fw_system" = Linux ] || exit 64

fw_mode=${1:-}
fw_backend=${2:-}
shift 2 2>/dev/null || exit 72

case "$fw_mode" in
  add|delete) ;;
  *) exit 72 ;;
esac
case "$fw_backend" in
  firewalld|ufw|nftables|iptables) ;;
  *) exit 72 ;;
esac

fw_find_bin() {
  fw_found=$(command -v "$1" 2>/dev/null || true)
  if [ -n "$fw_found" ] && [ -x "$fw_found" ]; then
    printf '%s\n' "$fw_found"
    return 0
  fi
  for fw_dir in /usr/sbin /sbin /usr/bin /bin; do
    if [ -x "$fw_dir/$1" ]; then
      printf '%s\n' "$fw_dir/$1"
      return 0
    fi
  done
  return 1
}

umask 077
fw_temp=$(mktemp -d "${TMPDIR:-/tmp}/paga-fw-mut.XXXXXXXX") || exit 75
trap 'rm -f "$fw_temp/out" "$fw_temp/err" "$fw_temp/save" "$fw_temp/save6" "$fw_temp/nft.conf"; rmdir "$fw_temp"' 0
trap 'exit 75' HUP INT TERM

fw_sudo_bin=
if [ "$(id -u)" != 0 ]; then
  fw_sudo_bin=$(fw_find_bin sudo || true)
  [ -n "$fw_sudo_bin" ] || exit 77
fi

fw_is_perm_err() {
  fw_err_lower=$(tr '[:upper:]' '[:lower:]' <"$fw_temp/err" 2>/dev/null || true)
  case "$fw_err_lower" in
    *'permission denied'*|*'operation not permitted'*|*'must be root'*|*'you need to be root'*|*'authorization failed'*|*'sudo:'*|*'a password is required'*|*'not allowed to execute'*|*'sorry, you must have a tty'*|*'authentication is required'*)
      return 0 ;;
  esac
  return 1
}

fw_run() {
  if [ -n "$fw_sudo_bin" ]; then
    "$fw_sudo_bin" -n -- "$@" >"$fw_temp/out" 2>"$fw_temp/err" </dev/null
  else
    "$@" >"$fw_temp/out" 2>"$fw_temp/err" </dev/null
  fi
}

fw_fail_from_err() {
  if fw_is_perm_err; then
    exit 77
  fi
  exit 75
}

fw_bin_firewalld=$(fw_find_bin firewall-cmd || true)
fw_bin_ufw=$(fw_find_bin ufw || true)
fw_bin_nft=$(fw_find_bin nft || true)
fw_bin_iptables=$(fw_find_bin iptables || true)
fw_bin_ip6tables=$(fw_find_bin ip6tables || true)

fw_zone=
fw_need_reload=0

fw_firewalld_prepare() {
  [ -n "$fw_bin_firewalld" ] || exit 69
  if ! fw_run "$fw_bin_firewalld" --state; then
    fw_is_perm_err && exit 77
    exit 70
  fi
  case "$(tr -d '\r\n' <"$fw_temp/out")" in
    running) ;;
    *) exit 70 ;;
  esac
  if ! fw_run "$fw_bin_firewalld" --get-default-zone; then
    fw_fail_from_err
  fi
  fw_zone=$(head -n 1 "$fw_temp/out" | tr -d '\r')
  [ -n "$fw_zone" ] || exit 75
}

fw_firewalld_add_rule() {
  fw_a=$1
  fw_p=$2
  fw_port=$3
  fw_src=$4
  fw_fam=$5
  fw_prio=$6
  case "$fw_p" in
    tcpudp) fw_protos="tcp udp" ;;
    tcp|udp) fw_protos=$fw_p ;;
    *) exit 72 ;;
  esac
  for fw_proto in $fw_protos; do
    if [ "$fw_a" = allow ] && [ -z "$fw_src" ] && [ "$fw_fam" = any ] && [ -z "$fw_prio" ]; then
      if ! fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --add-port="${fw_port}/${fw_proto}"; then
        fw_fail_from_err
      fi
      fw_need_reload=1
    else
      case "$fw_fam" in
        any) fw_fams="ipv4 ipv6" ;;
        ipv4|ipv6) fw_fams=$fw_fam ;;
        *) exit 72 ;;
      esac
      fw_verdict=accept
      [ "$fw_a" = deny ] && fw_verdict=drop
      for fw_f in $fw_fams; do
        fw_rule="rule"
        if [ -n "$fw_prio" ]; then
          fw_rule="$fw_rule priority=\"$fw_prio\""
        fi
        fw_rule="$fw_rule family=\"$fw_f\""
        if [ -n "$fw_src" ] && [ "$fw_src" != "0.0.0.0/0" ] && [ "$fw_src" != "::/0" ]; then
          fw_rule="$fw_rule source address=\"$fw_src\""
        fi
        fw_rule="$fw_rule port port=\"$fw_port\" protocol=\"$fw_proto\" $fw_verdict"
        if ! fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --add-rich-rule="$fw_rule"; then
          fw_fail_from_err
        fi
        fw_need_reload=1
      done
    fi
  done
}

fw_firewalld_delete_rule() {
  fw_raw=$1
  case "$fw_raw" in
    port:*)
      fw_spec=${fw_raw#port:}
      fw_in_perm=0
      fw_in_rt=0
      if fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --query-port="$fw_spec"; then
        fw_in_perm=1
      elif fw_is_perm_err; then
        exit 77
      fi
      if fw_run "$fw_bin_firewalld" --zone="$fw_zone" --query-port="$fw_spec"; then
        fw_in_rt=1
      elif fw_is_perm_err; then
        exit 77
      fi
      if [ "$fw_in_perm" = 0 ] && [ "$fw_in_rt" = 0 ]; then
        exit 78
      fi
      if [ "$fw_in_perm" = 1 ]; then
        if ! fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --remove-port="$fw_spec"; then
          fw_fail_from_err
        fi
        fw_need_reload=1
      fi
      if [ "$fw_in_perm" = 0 ] && [ "$fw_in_rt" = 1 ]; then
        if ! fw_run "$fw_bin_firewalld" --zone="$fw_zone" --remove-port="$fw_spec"; then
          fw_fail_from_err
        fi
      fi
      ;;
    rich:*)
      fw_spec=${fw_raw#rich:}
      fw_in_perm=0
      fw_in_rt=0
      if fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --query-rich-rule="$fw_spec"; then
        fw_in_perm=1
      elif fw_is_perm_err; then
        exit 77
      fi
      if fw_run "$fw_bin_firewalld" --zone="$fw_zone" --query-rich-rule="$fw_spec"; then
        fw_in_rt=1
      elif fw_is_perm_err; then
        exit 77
      fi
      if [ "$fw_in_perm" = 0 ] && [ "$fw_in_rt" = 0 ]; then
        exit 78
      fi
      if [ "$fw_in_perm" = 1 ]; then
        if ! fw_run "$fw_bin_firewalld" --permanent --zone="$fw_zone" --remove-rich-rule="$fw_spec"; then
          fw_fail_from_err
        fi
        fw_need_reload=1
      fi
      if [ "$fw_in_perm" = 0 ] && [ "$fw_in_rt" = 1 ]; then
        if ! fw_run "$fw_bin_firewalld" --zone="$fw_zone" --remove-rich-rule="$fw_spec"; then
          fw_fail_from_err
        fi
      fi
      ;;
    *)
      exit 72
      ;;
  esac
}

fw_firewalld_finish() {
  if [ "$fw_need_reload" = 1 ]; then
    if ! fw_run "$fw_bin_firewalld" --reload; then
      fw_fail_from_err
    fi
  fi
}

fw_ufw_prepare() {
  [ -n "$fw_bin_ufw" ] || exit 69
  if ! fw_run "$fw_bin_ufw" status; then
    fw_fail_from_err
  fi
  if ! grep -q '^Status:[[:space:]]*active' "$fw_temp/out" 2>/dev/null; then
    exit 70
  fi
}

fw_ufw_add_rule() {
  fw_a=$1
  fw_p=$2
  fw_port=$3
  fw_src=$4
  fw_comment=$7
  fw_ufw_port=$(printf '%s' "$fw_port" | tr '-' ':')
  case "$fw_p" in
    tcpudp) fw_protos="tcp udp" ;;
    tcp|udp) fw_protos=$fw_p ;;
    *) exit 72 ;;
  esac
  for fw_proto in $fw_protos; do
    if [ -z "$fw_src" ]; then
      if [ -n "$fw_comment" ]; then
        fw_run "$fw_bin_ufw" "$fw_a" in "${fw_ufw_port}/${fw_proto}" comment "$fw_comment" || fw_fail_from_err
      else
        fw_run "$fw_bin_ufw" "$fw_a" in "${fw_ufw_port}/${fw_proto}" || fw_fail_from_err
      fi
    else
      if [ -n "$fw_comment" ]; then
        fw_run "$fw_bin_ufw" "$fw_a" in proto "$fw_proto" from "$fw_src" to any port "$fw_ufw_port" comment "$fw_comment" || fw_fail_from_err
      else
        fw_run "$fw_bin_ufw" "$fw_a" in proto "$fw_proto" from "$fw_src" to any port "$fw_ufw_port" || fw_fail_from_err
      fi
    fi
  done
}

fw_ufw_delete_rule() {
  fw_raw=$1
  case "$fw_raw" in
    ufw:*) ;;
    *) exit 72 ;;
  esac
  fw_rest=${fw_raw#ufw:}
  fw_expect_num=${fw_rest%%:*}
  fw_expect_body=${fw_rest#*:}
  [ -n "$fw_expect_num" ] && [ -n "$fw_expect_body" ] || exit 72
  if ! fw_run "$fw_bin_ufw" status numbered; then
    fw_fail_from_err
  fi
  fw_resolved=$(
    PAGA_FW_NUM=$fw_expect_num PAGA_FW_BODY=$fw_expect_body awk '
      /^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+/ {
        line = $0
        sub(/\r$/, "", line)
        idx = line
        sub(/^[[:space:]]*\[[[:space:]]*/, "", idx)
        sub(/\].*$/, "", idx)
        body = line
        sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+/, "", body)
        gsub(/[[:space:]]+$/, "", body)
        if (idx == ENVIRON["PAGA_FW_NUM"] && body == ENVIRON["PAGA_FW_BODY"]) {
          exact = idx
        }
        if (body == ENVIRON["PAGA_FW_BODY"]) {
          matches++
          matched_idx = idx
        }
      }
      END {
        if (exact != "") print exact
        else if (matches == 1) print matched_idx
      }
    ' "$fw_temp/out"
  )
  [ -n "$fw_resolved" ] || exit 78
  if ! fw_run "$fw_bin_ufw" --force delete "$fw_resolved"; then
    fw_fail_from_err
  fi
}

fw_nft_prepare() {
  [ -n "$fw_bin_nft" ] || exit 69
  if ! fw_run "$fw_bin_nft" -a list ruleset; then
    fw_fail_from_err
  fi
}

fw_nft_select_chain() {
  fw_req_fam=$1
  if ! fw_run "$fw_bin_nft" -a list ruleset; then
    fw_fail_from_err
  fi
  fw_target=$(
    PAGA_FW_FAM=$fw_req_fam awk '
      /^table[[:space:]]+(inet|ip|ip6)[[:space:]]+/ {
        cur_fam = $2
        cur_tbl = $3
        cur_chn = ""
        next
      }
      /^[[:space:]]*chain[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]*\{/ {
        cur_chn = $2
        next
      }
      /type[[:space:]]+filter[[:space:]]+hook[[:space:]]+input/ {
        if (cur_fam != "" && cur_tbl != "" && cur_chn != "") {
          if (cur_fam == "inet" && inet_hit == "") {
            inet_hit = cur_fam " " cur_tbl " " cur_chn
          } else if (cur_fam == "ip" && ip_hit == "") {
            ip_hit = cur_fam " " cur_tbl " " cur_chn
          } else if (cur_fam == "ip6" && ip6_hit == "") {
            ip6_hit = cur_fam " " cur_tbl " " cur_chn
          }
        }
        next
      }
      END {
        req = ENVIRON["PAGA_FW_FAM"]
        if (inet_hit != "") print inet_hit
        else if (req == "ipv4" && ip_hit != "") print ip_hit
        else if (req == "ipv6" && ip6_hit != "") print ip6_hit
      }
    ' "$fw_temp/out"
  )
  if [ -n "$fw_target" ]; then
    set -- $fw_target
    fw_nft_fam=$1
    fw_nft_tbl=$2
    fw_nft_chn=$3
    return 0
  fi
  fw_nft_fam=inet
  fw_nft_tbl=filter
  fw_nft_chn=input
  fw_run "$fw_bin_nft" add table inet filter || fw_fail_from_err
  fw_run "$fw_bin_nft" add chain inet filter input '{ type filter hook input priority 0; policy accept; }' || fw_fail_from_err
}

fw_nft_catchall_handle() {
  if ! fw_run "$fw_bin_nft" -a list chain "$1" "$2" "$3"; then
    return 1
  fi
  awk '
    /# handle [0-9]+$/ {
      line = $0
      sub(/\r$/, "", line)
      handle = line
      sub(/^.*# handle /, "", handle)
      body = line
      sub(/[[:space:]]*# handle [0-9]+$/, "", body)
      sub(/^[[:space:]]+/, "", body)
      if (body == "drop" || body == "reject" || body ~ /^reject[[:space:]]+with[[:space:]]/ || body ~ /^counter[[:space:]].*[[:space:]](drop|reject)([[:space:]]|$)/) {
        print handle
        exit
      }
    }
  ' "$fw_temp/out"
}

fw_nft_add_rule() {
  fw_a=$1
  fw_p=$2
  fw_port=$3
  fw_src=$4
  fw_fam=$5
  fw_comment=$7
  fw_nft_select_chain "$fw_fam"
  fw_verdict=accept
  [ "$fw_a" = deny ] && fw_verdict=drop
  case "$fw_p" in
    tcpudp) fw_protos="tcp udp" ;;
    tcp|udp) fw_protos=$fw_p ;;
    *) exit 72 ;;
  esac
  for fw_proto in $fw_protos; do
    fw_pos=$(fw_nft_catchall_handle "$fw_nft_fam" "$fw_nft_tbl" "$fw_nft_chn" || true)
    if [ -n "$fw_pos" ]; then
      set -- insert rule "$fw_nft_fam" "$fw_nft_tbl" "$fw_nft_chn" position "$fw_pos"
    else
      set -- add rule "$fw_nft_fam" "$fw_nft_tbl" "$fw_nft_chn"
    fi
    if [ -n "$fw_src" ]; then
      if [ "$fw_fam" = ipv4 ]; then
        if [ "$fw_nft_fam" != ip ] || [ "$fw_src" != "0.0.0.0/0" ]; then
          set -- "$@" ip saddr "$fw_src"
        fi
      elif [ "$fw_fam" = ipv6 ]; then
        if [ "$fw_nft_fam" != ip6 ] || [ "$fw_src" != "::/0" ]; then
          set -- "$@" ip6 saddr "$fw_src"
        fi
      fi
    fi
    set -- "$@" "$fw_proto" dport "$fw_port" "$fw_verdict"
    if [ -n "$fw_comment" ]; then
      set -- "$@" comment "\"$fw_comment\""
    fi
    if ! fw_run "$fw_bin_nft" "$@"; then
      fw_fail_from_err
    fi
  done
}

fw_nft_verify_rule() {
  fw_raw=$1
  case "$fw_raw" in
    nft:*) ;;
    *) exit 72 ;;
  esac
  fw_rest=${fw_raw#nft:}
  fw_dfam=$(printf '%s' "$fw_rest" | awk -F'|' '{print $1}')
  fw_dtbl=$(printf '%s' "$fw_rest" | awk -F'|' '{print $2}')
  fw_dchn=$(printf '%s' "$fw_rest" | awk -F'|' '{print $3}')
  fw_dhdl=$(printf '%s' "$fw_rest" | awk -F'|' '{print $4}')
  case "$fw_dfam" in inet|ip|ip6) ;; *) exit 72 ;; esac
  [ -n "$fw_dtbl" ] && [ -n "$fw_dchn" ] && [ -n "$fw_dhdl" ] || exit 72
  if ! fw_run "$fw_bin_nft" -a list chain "$fw_dfam" "$fw_dtbl" "$fw_dchn"; then
    fw_is_perm_err && exit 77
    exit 78
  fi
  if ! grep -Eq "# handle ${fw_dhdl}[[:space:]]*$" "$fw_temp/out" 2>/dev/null; then
    exit 78
  fi
}

fw_nft_delete_rule() {
  fw_nft_verify_rule "$1"
  if ! fw_run "$fw_bin_nft" delete rule "$fw_dfam" "$fw_dtbl" "$fw_dchn" handle "$fw_dhdl"; then
    fw_fail_from_err
  fi
}

fw_nft_persist() {
  [ -f /etc/nftables.conf ] || return 0
  if grep -q '^[[:space:]]*include[[:space:]]' /etc/nftables.conf 2>/dev/null; then
    return 0
  fi
  if fw_run "$fw_bin_nft" list ruleset; then
    {
      printf '#!/usr/sbin/nft -f\nflush ruleset\n'
      cat "$fw_temp/out"
    } >"$fw_temp/nft.conf"
    if fw_run "$fw_bin_nft" -c -f "$fw_temp/nft.conf"; then
      if [ -n "$fw_sudo_bin" ]; then
        "$fw_sudo_bin" -n -- tee /etc/nftables.conf <"$fw_temp/nft.conf" >/dev/null 2>&1 || true
      else
        cp "$fw_temp/nft.conf" /etc/nftables.conf >/dev/null 2>&1 || true
      fi
    fi
  fi
}

fw_ipt_prepare() {
  [ -n "$fw_bin_iptables" ] || exit 69
  if ! fw_run "$fw_bin_iptables" -w 5 -S INPUT; then
    fw_fail_from_err
  fi
}

fw_ipt_catchall_pos() {
  awk '
    /^-A INPUT / {
      n++
      if ($0 == "-A INPUT -j DROP" || $0 == "-A INPUT -j REJECT" || $0 ~ /^-A INPUT -j REJECT /) {
        print n
        exit
      }
    }
  ' "$fw_temp/out"
}

fw_ipt_add_one() {
  fw_bin=$1
  fw_a=$2
  fw_proto=$3
  fw_port=$4
  fw_src=$5
  fw_comment=$6
  fw_ipt_port=$(printf '%s' "$fw_port" | tr '-' ':')
  fw_target=ACCEPT
  [ "$fw_a" = deny ] && fw_target=DROP
  set --
  if [ -n "$fw_src" ] && [ "$fw_src" != "0.0.0.0/0" ] && [ "$fw_src" != "::/0" ]; then
    set -- "$@" -s "$fw_src"
  fi
  set -- "$@" -p "$fw_proto" -m "$fw_proto" --dport "$fw_ipt_port"
  if [ -n "$fw_comment" ]; then
    set -- "$@" -m comment --comment "$fw_comment"
  fi
  set -- "$@" -j "$fw_target"
  if fw_run "$fw_bin" -w 5 -C INPUT "$@"; then
    return 0
  elif fw_is_perm_err; then
    exit 77
  fi
  if ! fw_run "$fw_bin" -w 5 -S INPUT; then
    fw_fail_from_err
  fi
  fw_pos=$(fw_ipt_catchall_pos || true)
  if [ -n "$fw_pos" ]; then
    fw_run "$fw_bin" -w 5 -I INPUT "$fw_pos" "$@" || fw_fail_from_err
  else
    fw_run "$fw_bin" -w 5 -A INPUT "$@" || fw_fail_from_err
  fi
}

fw_ipt_add_rule() {
  fw_a=$1
  fw_p=$2
  fw_port=$3
  fw_src=$4
  fw_fam=$5
  fw_comment=$7
  case "$fw_p" in
    tcpudp) fw_protos="tcp udp" ;;
    tcp|udp) fw_protos=$fw_p ;;
    *) exit 72 ;;
  esac
  for fw_proto in $fw_protos; do
    case "$fw_fam" in
      ipv4)
        fw_ipt_add_one "$fw_bin_iptables" "$fw_a" "$fw_proto" "$fw_port" "$fw_src" "$fw_comment"
        ;;
      ipv6)
        [ -n "$fw_bin_ip6tables" ] || exit 73
        fw_ipt_add_one "$fw_bin_ip6tables" "$fw_a" "$fw_proto" "$fw_port" "$fw_src" "$fw_comment"
        ;;
      any)
        fw_ipt_add_one "$fw_bin_iptables" "$fw_a" "$fw_proto" "$fw_port" "" "$fw_comment"
        if [ -n "$fw_bin_ip6tables" ] && fw_run "$fw_bin_ip6tables" -w 5 -S INPUT; then
          fw_ipt_add_one "$fw_bin_ip6tables" "$fw_a" "$fw_proto" "$fw_port" "" "$fw_comment"
        fi
        ;;
      *)
        exit 72
        ;;
    esac
  done
}

fw_ipt_delete_rule() {
  fw_raw=$1
  case "$fw_raw" in
    iptables:*) ;;
    *) exit 72 ;;
  esac
  fw_rest=${fw_raw#iptables:}
  fw_ver=${fw_rest%%:*}
  fw_rest2=${fw_rest#*:}
  fw_expect_num=${fw_rest2%%:*}
  fw_expect_line=${fw_rest2#*:}
  case "$fw_ver" in
    v4) fw_bin=$fw_bin_iptables ;;
    v6)
      [ -n "$fw_bin_ip6tables" ] || exit 73
      fw_bin=$fw_bin_ip6tables
      ;;
    *) exit 72 ;;
  esac
  [ -n "$fw_expect_num" ] && [ -n "$fw_expect_line" ] || exit 72
  if ! fw_run "$fw_bin" -w 5 -S INPUT; then
    fw_fail_from_err
  fi
  fw_resolved=$(
    PAGA_FW_NUM=$fw_expect_num PAGA_FW_LINE=$fw_expect_line awk '
      /^-A INPUT / {
        n++
        line = $0
        sub(/\r$/, "", line)
        if (n == ENVIRON["PAGA_FW_NUM"] && line == ENVIRON["PAGA_FW_LINE"]) {
          exact = n
        }
        if (line == ENVIRON["PAGA_FW_LINE"]) {
          matches++
          matched_n = n
        }
      }
      END {
        if (exact != "") print exact
        else if (matches == 1) print matched_n
      }
    ' "$fw_temp/out"
  )
  [ -n "$fw_resolved" ] || exit 78
  if ! fw_run "$fw_bin" -w 5 -D INPUT "$fw_resolved"; then
    fw_fail_from_err
  fi
}

fw_ipt_persist() {
  fw_np=$(fw_find_bin netfilter-persistent || true)
  if [ -n "$fw_np" ]; then
    fw_run "$fw_np" save || true
    return 0
  fi
  fw_save=$(fw_find_bin iptables-save || true)
  fw_save6=$(fw_find_bin ip6tables-save || true)
  if [ -n "$fw_save" ]; then
    for fw_target_file in /etc/sysconfig/iptables /etc/iptables/rules.v4; do
      if [ -f "$fw_target_file" ] && fw_run "$fw_save"; then
        if [ -n "$fw_sudo_bin" ]; then
          "$fw_sudo_bin" -n -- tee "$fw_target_file" <"$fw_temp/out" >/dev/null 2>&1 || true
        else
          cp "$fw_temp/out" "$fw_target_file" >/dev/null 2>&1 || true
        fi
        break
      fi
    done
  fi
  if [ -n "$fw_save6" ]; then
    for fw_target_file6 in /etc/sysconfig/ip6tables /etc/iptables/rules.v6; do
      if [ -f "$fw_target_file6" ] && fw_run "$fw_save6"; then
        if [ -n "$fw_sudo_bin" ]; then
          "$fw_sudo_bin" -n -- tee "$fw_target_file6" <"$fw_temp/out" >/dev/null 2>&1 || true
        else
          cp "$fw_temp/out" "$fw_target_file6" >/dev/null 2>&1 || true
        fi
        break
      fi
    done
  fi
}

case "$fw_backend" in
  firewalld) fw_firewalld_prepare ;;
  ufw) fw_ufw_prepare ;;
  nftables) fw_nft_prepare ;;
  iptables) fw_ipt_prepare ;;
esac

case "$fw_mode" in
  add)
    fw_count=${1:-0}
    shift 1 2>/dev/null || exit 72
    fw_i=0
    while [ "$fw_i" -lt "$fw_count" ]; do
      [ "$#" -ge 7 ] || exit 72
      case "$fw_backend" in
        firewalld) fw_firewalld_add_rule "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
        ufw) fw_ufw_add_rule "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
        nftables) fw_nft_add_rule "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
        iptables) fw_ipt_add_rule "$1" "$2" "$3" "$4" "$5" "$6" "$7" ;;
      esac
      shift 7
      fw_i=$((fw_i + 1))
    done
    ;;
  delete)
    [ "$#" -eq 1 ] || exit 72
    case "$fw_backend" in
      firewalld) fw_firewalld_delete_rule "$1" ;;
      ufw) fw_ufw_delete_rule "$1" ;;
      nftables) fw_nft_delete_rule "$1" ;;
      iptables) fw_ipt_delete_rule "$1" ;;
    esac
    ;;
esac

case "$fw_backend" in
  firewalld) fw_firewalld_finish ;;
  nftables) fw_nft_persist ;;
  iptables) fw_ipt_persist ;;
esac
