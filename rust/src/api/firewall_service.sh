LC_ALL=C
export LC_ALL

fw_system=$(uname -s)
[ "$fw_system" = Linux ] || exit 64

fw_backend=${1:-}
fw_action=${2:-}
case "$fw_backend" in
  firewalld|ufw|nftables) ;;
  *) exit 72 ;;
esac
case "$fw_action" in
  enable|disable|reload) ;;
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
fw_temp=$(mktemp -d "${TMPDIR:-/tmp}/paga-fw-svc.XXXXXXXX") || exit 75
trap 'rm -f "$fw_temp/out" "$fw_temp/err"; rmdir "$fw_temp"' 0
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

fw_bin_systemctl=$(fw_find_bin systemctl || true)
fw_bin_service=$(fw_find_bin service || true)
fw_bin_rc_service=$(fw_find_bin rc-service || true)

case "$fw_backend" in
  firewalld)
    fw_bin_firewalld=$(fw_find_bin firewall-cmd || true)
    [ -n "$fw_bin_firewalld" ] || exit 69
    case "$fw_action" in
      enable)
        if [ -n "$fw_bin_systemctl" ]; then
          fw_run "$fw_bin_systemctl" start firewalld || fw_fail_from_err
        elif [ -n "$fw_bin_service" ]; then
          fw_run "$fw_bin_service" firewalld start || fw_fail_from_err
        elif [ -n "$fw_bin_rc_service" ]; then
          fw_run "$fw_bin_rc_service" firewalld start || fw_fail_from_err
        else
          exit 69
        fi
        ;;
      disable)
        if [ -n "$fw_bin_systemctl" ]; then
          fw_run "$fw_bin_systemctl" stop firewalld || fw_fail_from_err
        elif [ -n "$fw_bin_service" ]; then
          fw_run "$fw_bin_service" firewalld stop || fw_fail_from_err
        elif [ -n "$fw_bin_rc_service" ]; then
          fw_run "$fw_bin_rc_service" firewalld stop || fw_fail_from_err
        else
          exit 69
        fi
        ;;
      reload)
        fw_run "$fw_bin_firewalld" --reload || fw_fail_from_err
        ;;
    esac
    ;;
  ufw)
    fw_bin_ufw=$(fw_find_bin ufw || true)
    [ -n "$fw_bin_ufw" ] || exit 69
    case "$fw_action" in
      enable)
        fw_run "$fw_bin_ufw" --force enable || fw_fail_from_err
        ;;
      disable)
        fw_run "$fw_bin_ufw" --force disable || fw_fail_from_err
        ;;
      reload)
        fw_run "$fw_bin_ufw" reload || fw_fail_from_err
        ;;
    esac
    ;;
  nftables)
    fw_bin_nft=$(fw_find_bin nft || true)
    [ -n "$fw_bin_nft" ] || exit 69
    case "$fw_action" in
      enable)
        if [ -n "$fw_bin_systemctl" ]; then
          fw_run "$fw_bin_systemctl" start nftables || fw_fail_from_err
        elif [ -n "$fw_bin_rc_service" ]; then
          fw_run "$fw_bin_rc_service" nftables start || fw_fail_from_err
        else
          exit 69
        fi
        ;;
      disable)
        if [ -n "$fw_bin_systemctl" ]; then
          fw_run "$fw_bin_systemctl" stop nftables || fw_fail_from_err
        elif [ -n "$fw_bin_rc_service" ]; then
          fw_run "$fw_bin_rc_service" nftables stop || fw_fail_from_err
        else
          exit 69
        fi
        ;;
      reload)
        if [ -n "$fw_bin_systemctl" ] && [ "$("$fw_bin_systemctl" show -p LoadState --value nftables.service 2>/dev/null || true)" = loaded ]; then
          fw_run "$fw_bin_systemctl" reload nftables || fw_run "$fw_bin_systemctl" restart nftables || fw_fail_from_err
        elif [ -n "$fw_bin_rc_service" ] && [ -x /etc/init.d/nftables ]; then
          fw_run "$fw_bin_rc_service" nftables reload || fw_fail_from_err
        elif [ -f /etc/nftables.conf ]; then
          fw_run "$fw_bin_nft" -f /etc/nftables.conf || fw_fail_from_err
        else
          exit 69
        fi
        ;;
    esac
    ;;
esac
