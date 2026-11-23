prepare_target 0
require_regular "$target"
# Prevent known private keys from crossing the SSH channel in the first place.
grep -qi -e '-----BEGIN .*PRIVATE KEY' "$target" && exit 76
stat_field '%Y' '%m' "$target" || exit 74
# Keep the transfer bounded if a remote writer grows the file after stat.
head -c "$((limit + 1))" "$target" || exit 74
