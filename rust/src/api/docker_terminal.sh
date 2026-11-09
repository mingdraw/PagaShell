# The arguments are prepared by the fixed preflight script and quoted by Rust.
container_id=$1
docker_bin=$2
docker_shell=$3
docker_endpoint=$4
docker_sudo=$5
case "$docker_shell" in /bin/bash|/usr/bin/bash|bash|/bin/sh|/usr/bin/sh|sh) ;; *) exit 80 ;; esac
if [ "$docker_sudo" = 1 ]; then
  exec sudo -n -- "$docker_bin" --host "$docker_endpoint" exec -it -e TERM=xterm-256color "$container_id" "$docker_shell"
fi
exec "$docker_bin" exec -it -e TERM=xterm-256color "$container_id" "$docker_shell"
