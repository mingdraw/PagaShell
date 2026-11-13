#!/bin/sh
# Runs outside the application bundle; no shell command is read from a release.
set -eu
mode=$1
platform=$2
source=$3
target=$4
work=$5
parent_process=$6
authorize=$7
self=$0
backup="$target.pagashell-backup"
marker="$backup.marker"
incoming="$target.pagashell-new-$(basename "$work")"
lock="$target.pagashell-update-lock"

transaction() {
  mkdir "$lock" || return 1
  moved=0
  trap 'status=$?; if [ "$status" -ne 0 ] && [ "$moved" -eq 1 ] && [ ! -e "$target" ] && [ -d "$backup" ]; then mv "$backup" "$target"; rm -f "$marker"; fi; rm -rf "$incoming"; rmdir "$lock"; exit "$status"' EXIT
  if [ "$mode" = cleanup ]; then
    [ -d "$target" ] && [ -f "$marker" ] || return 1
    rm -rf "$backup"
    rm -f "$marker"
    return
  fi
  if [ "$mode" = rollback ]; then
    [ -d "$backup" ] && [ -f "$marker" ]
    mv "$target" "$incoming"
    mv "$backup" "$target"
    rm -f "$marker"
    return
  fi
  [ -d "$source" ] && [ -d "$target" ]
  if [ -e "$backup" ]; then
    [ -f "$marker" ] || return 1
    rm -rf "$backup"
  fi
  if [ "$platform" = macos ]; then
    /usr/bin/ditto "$source" "$incoming"
  else
    cp -a "$source" "$incoming"
  fi
  # Mark the managed backup before the first rename so an interruption cannot
  # leave an unmarked copy of the only working installation.
  : > "$marker"
  mv "$target" "$backup"
  moved=1
  mv "$incoming" "$target"
  moved=0
}

if [ "$mode" != watch ]; then
  transaction
  exit 0
fi

exec >> "$work/helper.log" 2>&1
cd /
run_transaction() {
  action=$1
  if [ "$authorize" = false ]; then
    /bin/sh "$self" "$action" "$platform" "$source" "$target" "$work" "$parent_process" false
  elif [ "$platform" = macos ]; then
    /usr/bin/osascript -e 'on run argv
      set cmd to ""
      repeat with arg in argv
        set cmd to cmd & quoted form of (contents of arg) & " "
      end repeat
      do shell script cmd with administrator privileges
    end run' /bin/sh "$self" "$action" "$platform" "$source" "$target" "$work" "$parent_process" false
  else
    pkexec /bin/sh "$self" "$action" "$platform" "$source" "$target" "$work" "$parent_process" false
  fi
}

launch_app() {
  if [ "$platform" = macos ]; then
    /usr/bin/open -n "$target"
  else
    "$target/pagashell" >> "$work/application.log" 2>&1 &
    child_process=$!
    sleep 1
    kill -0 "$child_process" 2>/dev/null
  fi
}

: > "$work/ready"
while [ ! -f "$work/commit" ]; do
  [ ! -f "$work/cancel" ] || exit 0
  # Saving data or an exit confirmation can take arbitrarily long.
  kill -0 "$parent_process" 2>/dev/null || exit 0
  sleep 0.1
done
attempt=0
while kill -0 "$parent_process" 2>/dev/null; do
  [ ! -f "$work/cancel" ] || exit 0
  attempt=$((attempt + 1))
  [ "$attempt" -lt 1200 ] || { echo exit-timeout > "$work/error"; exit 1; }
  sleep 0.1
done
[ ! -f "$work/cancel" ] || exit 0
if ! run_transaction apply; then
  echo install-failed > "$work/error"
  launch_app || true
  exit 1
fi
if ! launch_app; then
  echo launch-failed > "$work/error"
  run_transaction rollback || true
  launch_app || true
  exit 1
fi
# Keep the backup available until the replacement has launched. Use the same
# authorization as installation when its directory requires administrator access.
if [ "$platform" = macos ]; then
  run_transaction cleanup || echo backup-cleanup-failed > "$work/error"
fi
: > "$work/complete"
rm -rf "$work/stage"
rm -f "$work"/pagashell_*
