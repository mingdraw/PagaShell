LC_ALL=C
export LC_ALL

fw_system=$(uname -s)
[ "$fw_system" = Linux ] || exit 64

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
fw_temp=$(mktemp -d "${TMPDIR:-/tmp}/paga-fw.XXXXXXXX") || exit 75
trap 'rm -f "$fw_temp/out" "$fw_temp/err" "$fw_temp/rules" "$fw_temp/listeners" "$fw_temp/part"; rmdir "$fw_temp"' 0
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

fw_ipt_wait_mode=
fw_ipt_run() {
  fw_ipt_bin=$1
  shift
  if [ "$fw_ipt_wait_mode" = w ]; then
    fw_run "$fw_ipt_bin" -w "$@"
    return $?
  elif [ "$fw_ipt_wait_mode" = none ]; then
    fw_run "$fw_ipt_bin" "$@"
    return $?
  fi
  if fw_run "$fw_ipt_bin" -w 5 "$@"; then
    fw_ipt_wait_mode=w5
    return 0
  fi
  if grep -qiE 'bad argument|unknown option|unrecognized option|invalid option' "$fw_temp/err" 2>/dev/null; then
    if fw_run "$fw_ipt_bin" -w "$@"; then
      fw_ipt_wait_mode=w
      return 0
    fi
    if grep -qiE 'bad argument|unknown option|unrecognized option|invalid option' "$fw_temp/err" 2>/dev/null; then
      fw_ipt_wait_mode=none
      fw_run "$fw_ipt_bin" "$@"
      return $?
    fi
    return 1
  fi
  return 1
}

fw_bin_firewalld=$(fw_find_bin firewall-cmd || true)
fw_bin_firewalld_daemon=$(fw_find_bin firewalld || true)
fw_bin_ufw=$(fw_find_bin ufw || true)
fw_bin_nft=$(fw_find_bin nft || true)
fw_bin_iptables=$(fw_find_bin iptables || true)
fw_bin_ip6tables=$(fw_find_bin ip6tables || true)
fw_bin_systemctl=$(fw_find_bin systemctl || true)
fw_bin_rc_service=$(fw_find_bin rc-service || true)
fw_bin_ss=$(fw_find_bin ss || true)

if [ -z "$fw_bin_firewalld" ] && [ -z "$fw_bin_ufw" ] && [ -z "$fw_bin_nft" ] && [ -z "$fw_bin_iptables" ]; then
  exit 69
fi

fw_service_enabled() {
  if [ -n "$fw_bin_systemctl" ]; then
    "$fw_bin_systemctl" is-enabled --quiet "$1" 2>/dev/null && return 0
  fi
  return 1
}

fw_firewalld_running() {
  [ -n "$fw_bin_firewalld" ] || return 1
  if fw_run "$fw_bin_firewalld" --state; then
    case "$(tr -d '\r\n' <"$fw_temp/out")" in
      running) return 0 ;;
    esac
    return 1
  fi
  if fw_is_perm_err; then
    exit 77
  fi
  return 1
}

fw_ufw_active() {
  [ -n "$fw_bin_ufw" ] || return 1
  if fw_run "$fw_bin_ufw" status; then
    if grep -q '^Status:[[:space:]]*active' "$fw_temp/out" 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  if fw_is_perm_err; then
    exit 77
  fi
  return 1
}

fw_nft_service_exists() {
  if [ -n "$fw_bin_systemctl" ]; then
    fw_load=$("$fw_bin_systemctl" show -p LoadState --value nftables.service 2>/dev/null || true)
    if [ "$fw_load" = loaded ]; then
      return 0
    fi
  fi
  if [ -n "$fw_bin_rc_service" ] && [ -x /etc/init.d/nftables ]; then
    return 0
  fi
  return 1
}

fw_nft_service_active() {
  if [ -n "$fw_bin_systemctl" ]; then
    "$fw_bin_systemctl" is-active --quiet nftables.service 2>/dev/null && return 0
  fi
  if [ -n "$fw_bin_rc_service" ]; then
    "$fw_bin_rc_service" nftables status >/dev/null 2>&1 && return 0
  fi
  return 1
}

fw_nft_has_native_input_rules() {
  [ -n "$fw_bin_nft" ] || return 1
  if ! fw_run "$fw_bin_nft" -a list ruleset; then
    if fw_is_perm_err; then
      exit 77
    fi
    return 1
  fi
  fw_has_nft=$(
    PAGA_NO_IPT=$([ -z "$fw_bin_iptables" ] && printf 1 || printf 0) awk '
      /^table[ \t]+(inet|ip|ip6)[ \t]+/ { fam = $2; tbl = $3; chn = ""; next }
      /^[ \t]*chain[ \t]+[A-Za-z0-9_.-]+[ \t]*\{/ { chn = $2; next }
      /type[ \t]+filter[ \t]+hook[ \t]+input/ {
        if (fam == "inet" || ENVIRON["PAGA_NO_IPT"] == "1" ||
            (tbl != "filter" && tbl != "nat" && tbl != "mangle" && tbl != "raw" && tbl != "security") ||
            chn != "INPUT") {
          print "1"
          exit
        }
      }
    ' "$fw_temp/out"
  )
  [ "$fw_has_nft" = 1 ]
}

fw_iptables_service_active() {
  if [ -n "$fw_bin_systemctl" ]; then
    for fw_unit in iptables.service ip6tables.service netfilter-persistent.service; do
      "$fw_bin_systemctl" is-active --quiet "$fw_unit" 2>/dev/null && return 0
    done
  fi
  if [ -n "$fw_bin_rc_service" ]; then
    "$fw_bin_rc_service" iptables status >/dev/null 2>&1 && return 0
    "$fw_bin_rc_service" ip6tables status >/dev/null 2>&1 && return 0
  fi
  return 1
}

fw_iptables_service_enabled() {
  fw_service_enabled iptables.service && return 0
  fw_service_enabled ip6tables.service && return 0
  fw_service_enabled netfilter-persistent.service && return 0
  return 1
}

fw_iptables_has_active_rules() {
  [ -n "$fw_bin_iptables" ] || return 1
  if ! fw_ipt_run "$fw_bin_iptables" -S INPUT; then
    if fw_is_perm_err; then
      exit 77
    fi
    return 1
  fi
  if grep -qE '^(-A INPUT |-P INPUT (DROP|REJECT))' "$fw_temp/out" 2>/dev/null; then
    return 0
  fi
  if [ -n "$fw_bin_ip6tables" ] && fw_ipt_run "$fw_bin_ip6tables" -S INPUT; then
    if grep -qE '^(-A INPUT |-P INPUT (DROP|REJECT))' "$fw_temp/out" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

fw_backend=
fw_state=inactive
fw_version=
fw_zone=
fw_policy=
fw_service_actions=none

if fw_firewalld_running; then
  fw_backend=firewalld
  fw_state=active
elif fw_ufw_active; then
  fw_backend=ufw
  fw_state=active
elif [ -n "$fw_bin_firewalld" ] || [ -n "$fw_bin_ufw" ]; then
  if [ -n "$fw_bin_firewalld" ] && fw_service_enabled firewalld.service; then
    fw_backend=firewalld
    fw_state=inactive
  elif [ -n "$fw_bin_ufw" ] && { fw_service_enabled ufw.service || grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; }; then
    fw_backend=ufw
    fw_state=inactive
  elif [ -n "$fw_bin_firewalld" ]; then
    fw_backend=firewalld
    fw_state=inactive
  else
    fw_backend=ufw
    fw_state=inactive
  fi
elif [ -n "$fw_bin_nft" ] && { fw_nft_service_active || fw_nft_has_native_input_rules; }; then
  fw_backend=nftables
  fw_state=active
elif [ -n "$fw_bin_iptables" ] && { fw_iptables_service_active || fw_iptables_has_active_rules; }; then
  fw_backend=iptables
  fw_state=active
elif [ -n "$fw_bin_nft" ] && fw_service_enabled nftables.service; then
  fw_backend=nftables
  fw_state=inactive
elif [ -n "$fw_bin_iptables" ] && fw_iptables_service_enabled; then
  fw_backend=iptables
  fw_state=active
elif [ -n "$fw_bin_nft" ] && { [ -z "$fw_bin_iptables" ] || fw_nft_service_exists || [ -f /etc/nftables.conf ]; }; then
  fw_backend=nftables
elif [ -n "$fw_bin_iptables" ]; then
  fw_backend=iptables
  fw_state=active
elif [ -n "$fw_bin_nft" ]; then
  fw_backend=nftables
else
  exit 69
fi

: >"$fw_temp/rules"

case "$fw_backend" in
  firewalld)
    fw_version=$("$fw_bin_firewalld" --version 2>/dev/null | head -n 1 | tr -d '\r' || true)
    if [ -z "$fw_version" ] && [ -n "$fw_bin_firewalld_daemon" ]; then
      fw_version=$("$fw_bin_firewalld_daemon" --version 2>/dev/null | head -n 1 | tr -d '\r' || true)
    fi
    if [ "$fw_state" = active ]; then
      fw_service_actions=disable,reload
      if fw_run "$fw_bin_firewalld" --get-default-zone; then
        fw_zone=$(head -n 1 "$fw_temp/out" | tr -d '\r')
      else
        fw_is_perm_err && exit 77
        exit 75
      fi
      {
        printf 'FIREWALLD_PORTS\n'
        if fw_run "$fw_bin_firewalld" --zone="$fw_zone" --list-ports; then
          cat "$fw_temp/out"
          printf '\n'
        else
          fw_is_perm_err && exit 77
          exit 75
        fi
        printf 'FIREWALLD_RICH_RULES\n'
        if fw_run "$fw_bin_firewalld" --zone="$fw_zone" --list-rich-rules; then
          cat "$fw_temp/out"
          printf '\n'
        else
          fw_is_perm_err && exit 77
          exit 75
        fi
      } >"$fw_temp/rules"
    else
      fw_service_actions=enable
    fi
    ;;
  ufw)
    fw_version=$("$fw_bin_ufw" version 2>/dev/null | head -n 1 | sed 's/^ufw[[:space:]]*//' | tr -d '\r' || true)
    if fw_run "$fw_bin_ufw" status numbered; then
      if grep -q '^Status:[[:space:]]*active' "$fw_temp/out" 2>/dev/null; then
        fw_state=active
        fw_service_actions=disable,reload
        {
          printf 'UFW_STATUS\n'
          cat "$fw_temp/out"
          printf '\n'
        } >"$fw_temp/rules"
      else
        fw_state=inactive
        fw_service_actions=enable
      fi
    else
      fw_is_perm_err && exit 77
      exit 75
    fi
    ;;
  nftables)
    fw_version=$("$fw_bin_nft" --version 2>/dev/null | head -n 1 | sed 's/^nftables[[:space:]]*//; s/^v//' | awk '{print $1}' | tr -d '\r' || true)
    if fw_run "$fw_bin_nft" -a list ruleset; then
      if fw_nft_service_active || [ -s "$fw_temp/out" ]; then
        fw_state=active
      else
        fw_state=inactive
      fi
      if fw_nft_service_exists; then
        if [ "$fw_state" = active ]; then
          fw_service_actions=disable,reload
        else
          fw_service_actions=enable
        fi
      elif [ -f /etc/nftables.conf ]; then
        fw_service_actions=reload
      else
        fw_service_actions=none
      fi
      {
        printf 'NFT_RULESET\n'
        cat "$fw_temp/out"
        printf '\n'
      } >"$fw_temp/rules"
    else
      fw_is_perm_err && exit 77
      exit 75
    fi
    ;;
  iptables)
    fw_version=$("$fw_bin_iptables" --version 2>/dev/null | head -n 1 | sed 's/^iptables[[:space:]]*//; s/^v//' | tr -d '\r' || true)
    fw_state=active
    fw_service_actions=none
    if ! fw_ipt_run "$fw_bin_iptables" -S INPUT; then
      fw_is_perm_err && exit 77
      exit 75
    fi
    fw_policy=$(awk '$1 == "-P" && $2 == "INPUT" { print $3; exit }' "$fw_temp/out" | tr -d '\r')
    {
      printf 'IPTABLES_V4\n'
      cat "$fw_temp/out"
      printf '\n'
      if [ -n "$fw_bin_ip6tables" ] && fw_ipt_run "$fw_bin_ip6tables" -S INPUT; then
        printf 'IPTABLES_V6\n'
        cat "$fw_temp/out"
        printf '\n'
      fi
    } >"$fw_temp/rules"
    ;;
esac

: >"$fw_temp/listeners"
if [ -n "$fw_bin_ss" ]; then
  if fw_run "$fw_bin_ss" -H -4 -l -n -t -u -p; then
    {
      printf 'SS4\n'
      cat "$fw_temp/out"
      printf '\n'
    } >>"$fw_temp/listeners"
  fi
  if fw_run "$fw_bin_ss" -H -6 -l -n -t -u -p; then
    {
      printf 'SS6\n'
      cat "$fw_temp/out"
      printf '\n'
    } >>"$fw_temp/listeners"
  fi
fi

printf 'PAGA_FIREWALL_V1\n'
printf 'BACKEND %s\n' "$fw_backend"
printf 'STATE %s\n' "$fw_state"
printf 'VERSION %s\n' "$fw_version"
printf 'ZONE %s\n' "$fw_zone"
printf 'POLICY %s\n' "$fw_policy"
printf 'SERVICE_ACTIONS %s\n' "$fw_service_actions"
printf -- '---RULES---\n'
cat "$fw_temp/rules"
printf -- '---LISTENERS---\n'
cat "$fw_temp/listeners"
printf 'END_FIREWALL\n'
