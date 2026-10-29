#!/usr/bin/env bash
# Keep Flutter's VM Service and DDS on loopback, even when a proxy is enabled.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf '%s\n' \
    'Usage: ./script/build_and_run.sh [flutter run options]' \
    'Builds and runs macOS Debug with hot reload (r) and hot restart (R).' \
    'Stops only the Debug app from this checkout before rebuilding.' \
    'Preserves external proxies and existing proxy bypass entries.'
  exit 0
fi

cd "$project_root"
flutter_binary="${FLUTTER_BIN:-flutter}"
if ! command -v "$flutter_binary" >/dev/null 2>&1; then
  printf '%s\n' 'Flutter was not found. Add it to PATH or set FLUTTER_BIN.' >&2
  exit 127
fi

# Dart prefers lowercase no_proxy. Merge both so neither list gets discarded.
loopback_bypass="${no_proxy:-},${NO_PROXY:-},localhost,127.0.0.1,::1,[::1]"
export no_proxy="${loopback_bypass#,}"
export NO_PROXY="$no_proxy"

# Another Debug process must exit before Xcode replaces its signed executable.
# Match the full binary path; Release apps and other checkouts keep running.
debug_binary="$project_root/build/macos/Build/Products/Debug/pagashell.app/Contents/MacOS/pagashell"
while IFS= read -r app_pid; do
  [[ "$app_pid" =~ ^[0-9]+$ ]] || continue
  app_binary="$(ps -p "$app_pid" -o comm= 2>/dev/null)" || continue
  [[ "$app_binary" == "$debug_binary" ]] || continue
  kill -TERM "$app_pid" 2>/dev/null || continue
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    printf '%s\n' 'The previous Debug app is still stopping. Try again after it exits.' >&2
    exit 1
  fi
done < <(pgrep -x pagashell 2>/dev/null || true)

printf '%s\n' '[PagaShell] Starting macOS Debug; VM Service and DDS use direct loopback connections.'
exec "$flutter_binary" run -d macos "$@"
