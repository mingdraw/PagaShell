expected=$3
allow_create=$4
make_parents=$5
suffix=$6
new_hash=$7

[ -z "$expected" ] || make_parents=0
[ "$allow_create" = 1 ] || make_parents=0
prepare_target "$make_parents"
lock_file
if [ -z "$expected" ]; then
    [ "$allow_create" = 1 ] || exit 67
    [ ! -L "$target" ] || exit 78
    [ ! -e "$target" ] || exit 68
else
    require_hash "$target" "$expected"
fi

scratch=$(mktemp "$parent/.pagashell-write.XXXXXXXX") || exit 74
head -c "$((limit + 1))" > "$scratch" || exit 74
require_hash "$scratch" "$new_hash"

if [ -z "$expected" ]; then
    link_file "$scratch" "$target" || exit 68
else
    copy_metadata "$target" "$scratch"
    backup=$target.pagashell.bak.$suffix
    copy=$(mktemp "$parent/.pagashell-backup.XXXXXXXX") || exit 74
    copy_preserving "$target" "$copy"
    require_hash "$copy" "$expected"
    link_file "$copy" "$backup" || exit 68
    require_hash "$target" "$expected"
    replace_file "$scratch" "$target"
fi
