LC_ALL=C
export LC_ALL
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) exit 64 ;;
esac
pid=$1
expected=$2
current=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
[ -n "$current" ] || exit 65
[ "$current" = "$expected" ] || exit 66
kill -TERM "$pid" 2>/dev/null || exit 67
