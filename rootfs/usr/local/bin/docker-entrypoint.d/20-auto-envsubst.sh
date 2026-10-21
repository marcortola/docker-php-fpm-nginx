#!/bin/sh

set -e

template_dirs="/usr/local/etc /etc"
suffix=".auto-tpl"
filter="(FPM_|NGINX_|USER)"

# Non-root mode (see entrypoint.sh): the container runs as an arbitrary uid with group 0
# added. The variables below feed the .auto-tpl templates; the Dockerfile sets their root-mode
# values. They are set here rather than in the entrypoint so that running this script again by
# hand, for example with docker exec, renders the same files in either mode.
if [ "$(id -u)" != "0" ]; then
  export NGINX_PID_FILE=/tmp/nginx.pid
  # A non-root fpm master cannot chown its socket (EPERM), so the lines become comments;
  # listen.mode = 0666 still lets nginx connect.
  export FPM_LISTEN_OWNERSHIP_COMMENT=';'
  # nginx's compiled-in temp paths are under /var/lib/nginx/tmp, an anonymous volume. One
  # kept from a root-mode run is owned by www-data with mode 755, and request bodies that
  # spill to disk would fail there, so nginx creates its temp directories in /tmp/nginx.
  mkdir -p /tmp/nginx
  export NGINX_TEMP_PATHS='client_body_temp_path /tmp/nginx/client_body;
    proxy_temp_path /tmp/nginx/proxy;
    uwsgi_temp_path /tmp/nginx/uwsgi;
    scgi_temp_path /tmp/nginx/scgi;
    '
fi

# The literal ${NAME} list is envsubst's SHELL-FORMAT argument; the names split on purpose.
# shellcheck disable=SC2016,SC2046
defined_envs=$(printf '${%s} ' $(awk "END { for (name in ENVIRON) { print ( name ~ /${filter}/ ) ? name : \"\" } }" </dev/null))

echo "$template_dirs" | tr ' ' '\n' | while read -r path; do
  find "$path" -type f -name "*$suffix" -print | while read -r template; do
    file="${template%"$suffix"}"
    # Render in place: writing an existing file needs write permission on the file only,
    # which the Dockerfile grants to group 0, so non-root mode works even after a derived
    # image's COPY has reset the file's directory (for example /etc/nginx) to root:root.
    envsubst "$defined_envs" <"$template" >"$file"
  done
done

exit 0
