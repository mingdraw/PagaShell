#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

lockfile=pubspec.lock
git ls-files --error-unmatch -- "$lockfile" >/dev/null
filter_name=pagashell-lock
case "$(git check-attr filter -- "$lockfile")" in
  "$lockfile: filter: unspecified"|"$lockfile: filter: $filter_name") ;;
  *) printf '%s\n' 'pubspec.lock already has a different Git filter.' >&2; exit 1 ;;
esac

# Match only hosted URL lines and preserve trailing whitespace, including CRLF.
to_official='s|^      url: "https://pub[.]flutter-io[.]cn"\([[:space:]]*\)$|      url: "https://pub.dev"\1|'
to_mirror='s|^      url: "https://pub[.]dev"\([[:space:]]*\)$|      url: "https://pub.flutter-io.cn"\1|'
git config --local "filter.$filter_name.clean" "sed '$to_official'"
git config --local "filter.$filter_name.smudge" "sed '$to_mirror'"
git config --local "filter.$filter_name.required" true

attributes="$(git rev-parse --git-path info/attributes)"
rule="/$lockfile filter=$filter_name"
mkdir -p "$(dirname "$attributes")"
if ! grep -Fxq -- "$rule" "$attributes" 2>/dev/null; then
  printf '\n%s\n' "$rule" >> "$attributes"
fi

# Switch the current copy without replacing any dependency versions or hashes.
mirror_lock="$(mktemp "./.$lockfile.mirror.XXXXXX")"
trap 'rm -f -- "$mirror_lock"' EXIT
cp -p "$lockfile" "$mirror_lock"
sed "$to_mirror" "$lockfile" > "$mirror_lock"
if ! cmp -s "$lockfile" "$mirror_lock"; then
  mv -f "$mirror_lock" "$lockfile"
fi

# Record the mirror file's size without staging any content changes.
if git diff --quiet --no-ext-diff --no-textconv -- "$lockfile"; then
  git checkout-index --force --index -- "$lockfile"
fi

printf '%s\n' 'Local Pub mirror enabled. Run:' \
  'PUB_HOSTED_URL=https://pub.flutter-io.cn flutter pub get --enforce-lockfile'
