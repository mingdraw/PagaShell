LC_ALL=C
export LC_ALL
case "$(uname -s)" in Linux|Darwin) ;; *) exit 64 ;; esac
docker_bin=$(command -v docker 2>/dev/null)
if [ -z "$docker_bin" ]; then
  for candidate in /usr/local/bin/docker /opt/homebrew/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker; do
    if [ -x "$candidate" ]; then docker_bin=$candidate; break; fi
  done
fi
[ -n "$docker_bin" ] || exit 70
container_id=$1
umask 077
docker_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/paga-docker-terminal.XXXXXXXX") || exit 81
trap 'rm -f "$docker_temp_dir/state" "$docker_temp_dir/error" "$docker_temp_dir/probe_error"; rmdir "$docker_temp_dir"' 0
trap 'exit 75' HUP INT TERM
docker_sudo=0
docker_endpoint=

docker_run() {
  if [ "$docker_sudo" -eq 1 ]; then
    sudo -n -- "$docker_bin" --host "$docker_endpoint" "$@"
  else
    "$docker_bin" "$@"
  fi
}

docker_failure() {
  docker_error=$(head -c 16384 "$docker_temp_dir/error" | tr '[:upper:]' '[:lower:]')
  case "$docker_error" in
    *'permission denied'*|*'operation not permitted'*|*'authorization denied'*|*'403 forbidden'*|*'sudo:'*) return 77 ;;
    *'cannot connect to the docker daemon'*|*'is the docker daemon running'*|*'failed to connect'*|*'error during connect'*|*'connection refused'*|*'dial unix '*) return 70 ;;
    *'no such object:'*|*'no such container:'*|*'is not running'*|*'is paused'*) return 79 ;;
    *) return 75 ;;
  esac
}

docker_run container inspect --format '{{.State.Status}}' "$container_id" >"$docker_temp_dir/state" 2>"$docker_temp_dir/error"
docker_code=$?
if [ "$docker_code" -ne 0 ]; then
  docker_failure
  docker_code=$?
  [ "$docker_code" -eq 77 ] || exit "$docker_code"
  command -v sudo >/dev/null 2>&1 || exit 77
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    docker_endpoint=$("$docker_bin" context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  elif [ -n "${DOCKER_HOST:-}" ]; then
    docker_endpoint=$DOCKER_HOST
  else
    docker_endpoint=$("$docker_bin" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  fi
  case "$docker_endpoint" in unix://?*) ;; *) exit 77 ;; esac
  docker_sudo=1
  if ! docker_run container inspect --format '{{.State.Status}}' "$container_id" >"$docker_temp_dir/state" 2>"$docker_temp_dir/error"; then
    docker_failure; exit $?
  fi
fi
[ "$(cat "$docker_temp_dir/state")" = running ] || exit 79
docker_probe_failure=0
docker_probe_exit=0
for docker_shell in /bin/bash /usr/bin/bash bash /bin/sh /usr/bin/sh sh; do
  # Docker/OCI can report a failed exec on either output stream.
  docker_run exec "$container_id" "$docker_shell" -c ':' >"$docker_temp_dir/error" 2>&1
  docker_code=$?
  if [ "$docker_code" -eq 0 ]; then
    printf 'PAGA_DOCKER_TERMINAL_V1\n%s\n%s\n%s\n%s\n' "$docker_bin" "$docker_shell" "$docker_endpoint" "$docker_sudo"
    exit 0
  fi
  docker_error=$(head -c 16384 "$docker_temp_dir/error" | tr '[:upper:]' '[:lower:]')
  case "$docker_error" in
    *'chdir to cwd'*|*'working directory'*) ;;
    *'executable file not found'*|*'exec: '*': no such file or directory'*|*'/bin/'*': no such file or directory'*) continue ;;
    '') [ "$docker_code" -ne 127 ] || continue ;;
  esac
  docker_exec_code=$docker_code
  docker_failure
  docker_code=$?
  case "$docker_code" in
    77|75)
      if [ "$docker_probe_failure" -eq 0 ]; then
        docker_probe_failure=$docker_code
        docker_probe_exit=$docker_exec_code
        head -c 8192 "$docker_temp_dir/error" >"$docker_temp_dir/probe_error"
      fi ;;
    *) exit "$docker_code" ;;
  esac
done
if ! docker_run container inspect --format '{{.State.Status}}' "$container_id" >"$docker_temp_dir/state" 2>"$docker_temp_dir/error"; then
  docker_failure; exit $?
fi
[ "$(cat "$docker_temp_dir/state")" = running ] || exit 79
if [ "$docker_probe_failure" -ne 0 ]; then
  # Raw diagnostics stay inside Rust; only classified reasons reach the UI.
  printf 'PAGA_DOCKER_TERMINAL_FAILURE_V1\n%s\n' "$docker_probe_exit"
  cat "$docker_temp_dir/probe_error"
  exit "$docker_probe_failure"
fi
exit 80
