#!/bin/sh

set -e

template_dirs="/usr/local/etc /etc"
suffix=".auto-tpl"
filter="(FPM_|NGINX_|USER)"

defined_envs=$(printf '${%s} ' $(awk "END { for (name in ENVIRON) { print ( name ~ /${filter}/ ) ? name : \"\" } }" </dev/null))

find "$template_dirs" -type f -name "*$suffix" -print | while read -r template; do
  file="${template%$suffix}"
  envsubst "$defined_envs" <"$template" >"$file"
done

exit 0
