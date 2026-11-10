LC_ALL=C
export LC_ALL
ports_system=$(uname -s)
case "$ports_system" in Linux|Darwin) ;; *) exit 64 ;; esac
ports_tool=
ports_format=LSOF
if [ "$ports_system" = Linux ]; then
  ports_tool=$(command -v ss 2>/dev/null)
  if [ -z "$ports_tool" ]; then
    for candidate in /usr/sbin/ss /sbin/ss /usr/bin/ss /bin/ss; do
      if [ -x "$candidate" ]; then ports_tool=$candidate; break; fi
    done
  fi
  [ -z "$ports_tool" ] || ports_format=SS
fi
if [ -z "$ports_tool" ]; then
  ports_tool=$(command -v lsof 2>/dev/null)
  if [ -z "$ports_tool" ]; then
    for candidate in /usr/sbin/lsof /usr/bin/lsof; do
      if [ -x "$candidate" ]; then ports_tool=$candidate; break; fi
    done
  fi
fi
[ -n "$ports_tool" ] || exit 69
umask 077
ports_temp=$(mktemp -d "${TMPDIR:-/tmp}/paga-ports.XXXXXXXX") || exit 75
trap 'rm -f "$ports_temp/output" "$ports_temp/part" "$ports_temp/error"; rmdir "$ports_temp"' 0
trap 'exit 75' HUP INT TERM

ports_exec() (
  ulimit -f 8192 2>/dev/null || :
  if [ "$ports_sudo" = 1 ]; then
    sudo -n -- "$ports_tool" "$@"
  else
    "$ports_tool" "$@"
  fi
) >"$ports_temp/part" 2>"$ports_temp/error" </dev/null

ports_lsof() {
  ports_exec "$@"
  ports_code=$?
  # lsof exits 1 for an empty selection. Diagnostic failures are not empty data.
  if [ "$ports_code" -eq 0 ] || { [ "$ports_code" -eq 1 ] && [ ! -s "$ports_temp/error" ]; }; then
    cat "$ports_temp/part"
    return 0
  fi
  return 77
}

ports_collect() {
  if [ "$ports_format" = SS ]; then
    printf 'SS4\n'
    ports_exec -H -4 -l -n -t -u -p || return 77
    cat "$ports_temp/part"
    printf 'SS6\n'
    ports_exec -H -6 -l -n -t -u -p || return 77
    cat "$ports_temp/part"
  else
    printf 'LSOF\n'
    ports_lsof -nP -a -iTCP -sTCP:LISTEN -FpcftPnT || return $?
    ports_lsof -nP -iUDP -FpcftPnT || return $?
  fi
}

ports_sudo=0
ports_access=FULL
if [ "$(id -u)" != 0 ]; then
  ports_access=LIMITED
  if command -v sudo >/dev/null 2>&1; then
    ports_sudo=1
    if ports_collect >"$ports_temp/output"; then ports_access=FULL; else ports_sudo=0; fi
  fi
fi
if [ "$ports_sudo" = 0 ]; then
  ports_collect >"$ports_temp/output" || exit $?
fi
printf 'PAGA_NETWORK_PORTS_V1\nACCESS %s\n' "$ports_access"
cat "$ports_temp/output"
printf 'END_PORTS\n'
