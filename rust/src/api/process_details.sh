LC_ALL=C
export LC_ALL
process_os=$(uname -s)
case "$process_os" in Linux|Darwin) ;; *) exit 64 ;; esac
pid=$1
expected=$2
check_identity() {
  current=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
  [ -n "$current" ] || exit 65
  [ "$current" = "$expected" ] || exit 66
}
check_identity
# Read only the requested process; command-line arguments are never collected.
details=$(ps -ww -p "$pid" -o pid= -o ppid= -o user= -o pcpu= -o pmem= -o rss= -o vsz= -o stat= -o ni= -o etime= -o time= -o lstart= -o comm= 2>/dev/null) || exit 68
[ -n "$details" ] || exit 65
printf 'PAGA_PROCESS_DETAILS_V1\n%s\nPAGA_PROCESS_PATH\000' "$details"
if [ "$process_os" = Linux ]; then
  readlink -n "/proc/$pid/exe" 2>/dev/null || true
else
  /usr/bin/osascript -l JavaScript - "$pid" 2>/dev/null <<'PAGASHELL_PROCESS_PATH_JXA' || true
ObjC.import('Foundation');
ObjC.bindFunction('dlopen', ['void *', ['char *', 'int']]);
$.dlopen('/usr/lib/libproc.dylib', 2);
ObjC.bindFunction('proc_pidpath', ['int', ['int', 'void *', 'unsigned int']]);
function run(argv) {
  var buffer = $.NSMutableData.dataWithLength(4096);
  var length = $.proc_pidpath(Number(argv[0]), buffer.mutableBytes, 4096);
  if (length <= 0) return;
  var data = buffer.subdataWithRange($.NSMakeRange(0, length));
  var path = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  if (!path) return;
  path = path.replace(/\u0000.*$/, '');
  if (path[0] === '/') $.NSFileHandle.fileHandleWithStandardOutput.writeData($(path).dataUsingEncoding($.NSUTF8StringEncoding));
}
PAGASHELL_PROCESS_PATH_JXA
fi
printf '\000\n'
# Discard partial output if the target exits or its PID is reused during the read.
check_identity
printf 'PAGA_PROCESS_DETAILS_END\n'
