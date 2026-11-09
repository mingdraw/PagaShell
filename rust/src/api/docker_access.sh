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
docker_config=${DOCKER_CONFIG:-${HOME}/.docker}
docker_endpoint=
docker_sudo=0
umask 077
docker_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/paga-docker-access.XXXXXXXX") || exit 75
trap 'rm -f "$docker_temp_dir/version" "$docker_temp_dir/error"; rmdir "$docker_temp_dir"' 0
trap 'exit 75' HUP INT TERM
docker_failure() {
  docker_error=$(head -c 16384 "$docker_temp_dir/error" | tr '[:upper:]' '[:lower:]')
  case "$docker_error" in
    *'permission denied'*|*'operation not permitted'*|*'access denied'*|*'authorization denied'*|*'403 forbidden'*|*'sudo:'*) return 77 ;;
    *'cannot connect to the docker daemon'*|*'is the docker daemon running'*|*'failed to connect'*|*'connection refused'*|*'no such file or directory'*) return 70 ;;
    *) return 75 ;;
  esac
}
"$docker_bin" version --format '{{.Server.APIVersion}}' >"$docker_temp_dir/version" 2>"$docker_temp_dir/error"
docker_code=$?
if [ "$docker_code" -ne 0 ]; then
  docker_failure; docker_code=$?
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
  if ! (unset DOCKER_CONTEXT DOCKER_HOST; sudo -n -- "$docker_bin" --config "$docker_config" --host "$docker_endpoint" version --format '{{.Server.APIVersion}}') >"$docker_temp_dir/version" 2>"$docker_temp_dir/error"; then
    docker_failure; exit $?
  fi
fi
printf 'PAGA_DOCKER_ACCESS_V1\n%s\n%s\n%s\n%s\n%s\n' "$docker_bin" "$docker_endpoint" "$docker_sudo" "$docker_config" "$(cat "$docker_temp_dir/version")"
