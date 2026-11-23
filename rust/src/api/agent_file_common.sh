# Sourced as part of a fixed SSH exec script. File data is never an argument.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
umask 077
elevated=$1
target=$2
limit=2097152

check_secret_path() {
    lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$lower/" in
        /proc/*|/dev/*|/sys/*|/run/secrets/*|/var/run/secrets/*) exit 76 ;;
        */.ssh/*|*/.gnupg/*|*/.aws/*|*/.kube/*|*/shadow/*|*/gshadow/*|*/shadow-/*|*/gshadow-/*|\
        */master.passwd/*|*/.my.cnf/*|*/.pgpass/*|*/pgpass/*|*/.netrc/*|*/.npmrc/*|\
        */login.keychain-db/*|*/credentials/*|*/secret/*|*/secrets/*|*/id_rsa*/*|*/id_ed25519*/*|\
        */ssh_host_*/*|*/.env/*|*/.env.*/*|*/*.key/*|*/*.pem/*|*/*.p12/*|*/*.pfx/*|*/*.kdbx/*|*/*.jks/*)
            exit 76 ;;
    esac
}

stat_field() {
    stat -c "$1" "$3" 2>/dev/null || stat -f "$2" "$3" 2>/dev/null
}

check_elevated_parent() {
    [ "$elevated" = 1 ] || return 0
    cursor=$1
    while :; do
        ownership=$(stat_field '%u %a' '%u %Lp' "$cursor") || exit 78
        case "$ownership" in
            '0 '*[2367][0-7]|'0 '*[0-7][2367]) exit 78 ;;
            '0 '*) ;;
            *) exit 78 ;;
        esac
        [ "$cursor" != / ] || break
        cursor=${cursor%/*}
        cursor=${cursor:-/}
    done
}

prepare_target() {
    check_secret_path "$target"
    wanted=${target%/*}
    wanted=${wanted:-/}
    nearest=$wanted
    while [ ! -d "$nearest" ]; do
        [ ! -e "$nearest" ] && [ ! -L "$nearest" ] || exit 78
        nearest=${nearest%/*}
        nearest=${nearest:-/}
    done
    physical=$(cd -P "$nearest" && pwd -P) || exit 78
    pending=${wanted#"$nearest"}
    [ -z "$pending" ] || pending=/${pending#/}
    parent=${physical%/}$pending
    parent=${parent:-/}
    target=${parent%/}/${target##*/}
    check_secret_path "$target"
    check_elevated_parent "$physical"
    if [ -n "$pending" ]; then
        [ "$1" = 1 ] || exit 67
        # Walk one directory at a time. Refuse a symlink installed by a
        # concurrent creator and check every newly created elevated directory.
        here=${physical%/}
        remaining=${pending#/}
        while [ -n "$remaining" ]; do
            component=${remaining%%/*}
            here=$here/$component
            if [ ! -d "$here" ]; then
                (umask 022; mkdir "$here") || exit 74
            fi
            [ ! -L "$here" ] && [ -d "$here" ] || exit 78
            check_elevated_parent "$here"
            case "$remaining" in
                */*) remaining=${remaining#*/} ;;
                *) remaining= ;;
            esac
        done
    fi
}

require_regular() {
    [ ! -L "$1" ] || exit 78
    [ -e "$1" ] || exit 67
    [ -f "$1" ] || exit 78
    size=$(stat_field '%s' '%z' "$1") || exit 74
    [ "$size" -le "$limit" ] || exit 75
}

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum < "$1") || return 1
    else
        digest=$(shasum -a 256 < "$1") || return 1
    fi
    printf '%s\n' "${digest%% *}"
}

require_hash() {
    require_regular "$1"
    actual=$(sha "$1") || exit 74
    [ "$actual" = "$2" ] || exit 66
}

lock_file() {
    # Serialize PagaShell writers; an external editor is checked by SHA
    # again just before commit. Do not delete someone else's lock.
    lock=$parent/.${target##*/}.pagashell.lock
    mkdir "$lock" 2>/dev/null || exit 66
    scratch=
    copy=
    trap 'if [ -n "$scratch" ]; then rm -f "$scratch"; fi; if [ -n "$copy" ]; then rm -f "$copy"; fi; rmdir "$lock"' EXIT
    trap 'exit 74' HUP INT TERM
}

copy_preserving() {
    cp -p "$1" "$2" || exit 74
    before=$(stat_field '%u:%g:%a' '%u:%g:%Lp' "$1") || exit 74
    after=$(stat_field '%u:%g:%a' '%u:%g:%Lp' "$2") || exit 74
    [ "$before" = "$after" ] || exit 74
}

replace_file() {
    # Linux GNU/BusyBox mv -T treats the destination as a file path.
    case "$(uname -s)" in
        Darwin|FreeBSD) mv -fh "$1" "$2" || exit 74 ;;
        *) mv -fT "$1" "$2" || exit 74 ;;
    esac
}

link_file() {
    # link(1) treats the second argument as a file path, never a directory.
    if command -v link >/dev/null 2>&1; then
        link "$1" "$2" || return 1
    else
        case "$(uname -s)" in
            Darwin|FreeBSD) [ ! -e "$2" ] && [ ! -L "$2" ] && ln -h "$1" "$2" || return 1 ;;
            *) ln -T "$1" "$2" || return 1 ;;
        esac
    fi
}
