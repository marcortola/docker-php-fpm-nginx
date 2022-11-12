#!/bin/sh

set -e

if [ "$1" = "supervisord" ]; then

  # Execute docker-entrypoint.d scripts
  find "/usr/local/bin/docker-entrypoint.d/" -follow -type f -print | sort -V | while read -r f; do
    case "$f" in
        *.sh)
            if [ -x "$f" ]; then
                "$f"
            fi
            ;;
        *) ;;
    esac
  done

fi

exec "$@"
