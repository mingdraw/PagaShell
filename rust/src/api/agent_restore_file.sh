expected=$3
suffix=$4
backup_hash=$5

prepare_target 0
lock_file
require_hash "$target" "$expected"
if [ -z "$suffix" ]; then
    rm "$target" || exit 74
else
    backup=$target.pagashell.bak.$suffix
    require_regular "$backup"
    scratch=$(mktemp "$parent/.pagashell-restore.XXXXXXXX") || exit 74
    copy_preserving "$backup" "$scratch"
    require_hash "$scratch" "$backup_hash"
    require_hash "$target" "$expected"
    replace_file "$scratch" "$target"
fi
