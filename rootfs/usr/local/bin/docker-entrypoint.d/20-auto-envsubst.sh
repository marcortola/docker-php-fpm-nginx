#!/bin/sh

set -e

template_dirs="/usr/local/etc /etc"
suffix=".auto-tpl"
filter="(FPM_|NGINX_|USER)"

defined_envs=$(printf '${%s} ' $(awk "END { for (name in ENVIRON) { print ( name ~ /${filter}/ ) ? name : \"\" } }" </dev/null))

echo "$template_dirs" | tr ' ' '\n' | while read -r path; do
  find "$path" -type f -name "*$suffix" -print | while read -r template; do
    file="${template%$suffix}"
    rm -f "$file"
    envsubst "$defined_envs" <"$template" >"$file"
  done
done

exit 0
