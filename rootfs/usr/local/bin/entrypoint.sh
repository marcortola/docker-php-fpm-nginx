#!/bin/sh

set -e

if [ "$1" = "supervisord" ]; then

  # Non-root mode: the container was started as an arbitrary uid, typically the host uid
  # with group 0 added (compose `user:` plus `group_add: ["0"]`). Nothing can be chowned,
  # and only the paths the Dockerfile prepares with group 0 and g=u are writable, so the
  # root-only init script is skipped and the runtime files move to /tmp. The two variables
  # below feed the .auto-tpl templates; in root mode they render the same bytes as before.
  if [ "$(id -u)" = "0" ]; then
    nonroot=false
    export NGINX_PID_FILE=/var/run/nginx.pid
    # Prefix for the fpm listen.owner/listen.group lines: empty keeps them.
    export FPM_LISTEN_OWNERSHIP_COMMENT=
  else
    nonroot=true
    export NGINX_PID_FILE=/tmp/nginx.pid
    # A non-root fpm master cannot chown its socket (EPERM), so the lines become comments;
    # listen.mode = 0666 still lets nginx connect.
    export FPM_LISTEN_OWNERSHIP_COMMENT=';'

    # supervisord.conf runs as user=root and keeps its pidfile and socket in /var/run; the
    # non-root variant has the same programs with its runtime files under /tmp.
    for arg do
      shift
      if [ "$arg" = /etc/supervisord.conf ] && { [ "${previous:-}" = -c ] || [ "${previous:-}" = --configuration ]; }; then
        arg=/etc/supervisord-nonroot.conf
      fi
      set -- "$@" "$arg"
      previous=$arg
    done
  fi

  # Execute docker-entrypoint.d scripts
  find "/usr/local/bin/docker-entrypoint.d/" -follow -type f -print | sort -V | while read -r f; do
    case "$f" in
        */00-init.sh)
            # Creates and chowns the nginx runtime directories, which needs root. In non-root
            # mode the Dockerfile has created them already, writable through group 0.
            if [ "$nonroot" = false ] && [ -x "$f" ]; then
                "$f"
            fi
            ;;
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
