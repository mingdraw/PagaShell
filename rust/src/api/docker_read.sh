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
kind=$1
target=$2
# Buffer each attempt separately so a failed query cannot prepend partial JSON
# to a successful sudo retry. Temporary files are private and always removed.
umask 077
docker_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/paga-docker.XXXXXXXX") || exit 75
trap 'rm -f "$docker_temp_dir/output" "$docker_temp_dir/error"; rmdir "$docker_temp_dir"' 0
trap 'exit 75' HUP INT TERM

docker_exec() (
  # Bound remote temporary files as well as the SSH response (checked in Rust).
  ulimit -f 8192 2>/dev/null || :
  "$@" >"$docker_temp_dir/output" 2>"$docker_temp_dir/error" </dev/null
)

docker_failure() {
  docker_error=$(head -c 16384 "$docker_temp_dir/error" | tr '[:upper:]' '[:lower:]')
  case "$docker_error" in
    *'permission denied'*|*'operation not permitted'*|*'access denied'*|*'authorization denied'*|*'403 forbidden'*) return 77 ;;
    *'cannot connect to the docker daemon'*|*'is the docker daemon running'*|*'docker daemon is not running'*|*'failed to connect'*|*'connection refused'*|*'no such file or directory'*) return 70 ;;
    *'no such object:'*|*'no such container:'*|*'no such image:'*|*'no such network:'*|*'no such volume:'*) return 78 ;;
    *) return 1 ;;
  esac
}

docker_query() {
  docker_exec "$docker_bin" "$@"
  docker_code=$?
  if [ "$docker_code" -eq 0 ]; then cat "$docker_temp_dir/output"; return; fi
  docker_failure
  docker_reason=$?
  if [ "$docker_reason" -eq 77 ]; then
    command -v sudo >/dev/null 2>&1 || return 77
    # Keep the same daemon when sudo changes HOME or removes Docker variables.
    # Privilege escalation only helps access a local Unix socket.
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
      docker_endpoint=$("$docker_bin" context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    elif [ -n "${DOCKER_HOST:-}" ]; then
      docker_endpoint=$DOCKER_HOST
    else
      docker_endpoint=$("$docker_bin" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    fi
    case "$docker_endpoint" in unix://?*) ;; *) return 77 ;; esac
    # -n never prompts for or consumes a password during background polling.
    docker_exec sudo -n -- "$docker_bin" --host "$docker_endpoint" "$@"
    docker_code=$?
    if [ "$docker_code" -eq 0 ]; then cat "$docker_temp_dir/output"; return; fi
    docker_failure
    docker_reason=$?
    if [ "$docker_reason" -eq 1 ]; then
      case "$docker_error" in *'sudo:'*) return 77 ;; esac
    fi
  fi
  [ "$docker_reason" -eq 1 ] || return "$docker_reason"
  case "$docker_code" in 126|127) return 70 ;; esac
  docker_limit=2097152
  [ -z "$target" ] || docker_limit=262144
  [ "$(wc -c <"$docker_temp_dir/output")" -le "$docker_limit" ] || return 74
  return 75
}

# Resolve container references by immutable image ID, including stopped containers.
# Inspect only .Image in bounded batches, never full container configuration.
docker_images() {
  docker_query image ls --all --no-trunc --digests --format '{"id":{{json .ID}},"repository":{{json .Repository}},"tag":{{json .Tag}},"digest":{{json .Digest}},"createdAt":{{json .CreatedAt}},"size":{{json .Size}}}' || return $?
  docker_ids=$(docker_query container ls --all --quiet --no-trunc) || return $?
  docker_batch=
  docker_batch_size=0
  for docker_id in $docker_ids; do
    case "$docker_id" in ''|*[!a-fA-F0-9]*) return 75 ;; esac
    [ "${#docker_id}" -eq 64 ] || return 75
    docker_batch="$docker_batch $docker_id"
    docker_batch_size=$((docker_batch_size + 1))
    if [ "$docker_batch_size" -eq 128 ]; then
      docker_query container inspect --format '{"usedImageId":{{json .Image}}}' $docker_batch || return $?
      docker_batch=
      docker_batch_size=0
    fi
  done
  if [ "$docker_batch_size" -ne 0 ]; then
    docker_query container inspect --format '{"usedImageId":{{json .Image}}}' $docker_batch || return $?
  fi
  printf '{"imageUsageComplete":true}\n'
}

# Compose metadata is an explicit label allowlist; configuration contents,
# environment, arbitrary Labels and driver Options never leave the server.
docker_compose() {
  if [ -n "$target" ]; then
    set -- --filter "label=com.docker.compose.project=$target"
  else
    set --
  fi
  docker_query container ls --all --no-trunc --filter label=com.docker.compose.project "$@" --format '{"id":{{json (.Label "com.docker.compose.project")}},"containerId":{{json .ID}},"name":{{json .Names}},"state":{{json .State}},"service":{{json (.Label "com.docker.compose.service")}},"oneoff":{{json (.Label "com.docker.compose.oneoff")}},"workingDirectory":{{json (.Label "com.docker.compose.project.working_dir")}},"configFiles":{{json (.Label "com.docker.compose.project.config_files")}},"composeVersion":{{json (.Label "com.docker.compose.version")}}}'
}

# All other templates also project explicit fields, never full inspect.
if [ "$kind" = compose ]; then
  docker_compose
  exit $?
fi
if [ -z "$target" ]; then
  case "$kind" in
    container) docker_query container ls --all --no-trunc --format '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"state":{{json .State}},"status":{{json .Status}},"ports":{{json .Ports}},"networks":{{json .Networks}},"createdAt":{{json .CreatedAt}}}' ;;
    image) docker_images ;;
    network) docker_query network ls --no-trunc --format '{"id":{{json .ID}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}}}' ;;
    volume) docker_query volume ls --format '{"id":{{json .Name}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}}}' ;;
    *) exit 64 ;;
  esac
else
  case "$kind" in
    container) format='{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"createdAt":{{json .Created}},"state":{{json .State.Status}},"health":{{with index .State "Health"}}{{json (index . "Status")}}{{else}}""{{end}},"startedAt":{{json .State.StartedAt}},"finishedAt":{{json .State.FinishedAt}},"exitCode":{{json .State.ExitCode}},"restartCount":{{json .RestartCount}},"ports":{{json .NetworkSettings.Ports}},"networks":{ {{$comma := ""}}{{range $name, $net := .NetworkSettings.Networks}}{{$comma}}{{$comma = ","}}{{json $name}}:{"IPAddress":{{json $net.IPAddress}},"GlobalIPv6Address":{{json $net.GlobalIPv6Address}}}{{end}} },"mounts":{{json .Mounts}}}' ;;
    image) format='{"id":{{json .Id}},"tags":{{json .RepoTags}},"digests":{{json .RepoDigests}},"createdAt":{{json .Created}},"size":{{json .Size}},"platform":{{json .Os}},"architecture":{{json .Architecture}}}' ;;
    network) format='{"id":{{json .Id}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}},"createdAt":{{json .Created}},"internal":{{json .Internal}},"ipv6":{{json .EnableIPv6}},"attachable":{{json .Attachable}},"ingress":{{json .Ingress}},"ipam":{{json .IPAM.Config}},"containers":{{json .Containers}}}' ;;
    volume) format='{"id":{{json .Name}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}},"mountpoint":{{json .Mountpoint}},"createdAt":{{json .CreatedAt}}}' ;;
    *) exit 64 ;;
  esac
  docker_query inspect --type "$kind" --format "$format" "$target"
fi
