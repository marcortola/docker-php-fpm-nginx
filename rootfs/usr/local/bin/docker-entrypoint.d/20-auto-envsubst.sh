#!/bin/sh

set -e

template_dirs="/usr/local/etc /etc"
suffix=".auto-tpl"
filter="(FPM_|NGINX_|USER)"

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
