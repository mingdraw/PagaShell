# PAGA_COMPOSE_OPERATION_V1: fixed steps only; never return raw Compose output.
LC_ALL=C
export LC_ALL
umask 077
compose_temp=$(mktemp -d "${TMPDIR:-/tmp}/paga-compose.XXXXXXXX") || exit 90
trap 'rm -f "$compose_temp/output" "$compose_temp/error"; rmdir "$compose_temp"' 0
trap 'exit 90' HUP INT TERM

compose() (
  ulimit -f 8192 2>/dev/null || :
  # Explicit project/options must not be replaced by the login shell's Compose environment.
  unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE COMPOSE_PATH_SEPARATOR
@COMPOSE_COMMAND@
)

run() {
  compose_failure=$1
  shift
  compose "$@" >"$compose_temp/output" 2>"$compose_temp/error" </dev/null
  compose_code=$?
  [ "$compose_code" -ne 0 ] || return 0
  compose_error=$(head -c 16384 "$compose_temp/error" | tr '[:upper:]' '[:lower:]')
  case "$compose_error" in
    *'permission denied'*|*'operation not permitted'*|*'access denied'*|*'authorization denied'*|*'403 forbidden'*|*'sudo:'*) exit 77 ;;
    *'cannot connect to the docker daemon'*|*'is the docker daemon running'*|*'connection refused'*) exit 70 ;;
    *'no configuration file'*|*'no such file or directory'*|*'env file'*'not found'*)
      [ "$compose_failure" -ne 82 ] || exit 81 ;;
  esac
  exit "$compose_failure"
}

run 80 version --short
@COMPOSE_STEPS@
