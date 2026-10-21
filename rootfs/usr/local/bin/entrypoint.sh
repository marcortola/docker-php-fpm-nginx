#!/bin/sh

set -e

if [ "$1" = "supervisord" ]; then

  # Non-root mode: the container was started as an arbitrary uid, typically the host uid
  # with group 0 added (compose `user:` plus `group_add: ["0"]`). Nothing can be chowned,
  # and only the paths the Dockerfile prepares with group 0 and g=u are writable, so the
  # root-only init script is skipped and the runtime files move to /tmp. The variables below
  # feed the .auto-tpl templates; the Dockerfile sets their root-mode values.
  if [ "$(id -u)" = "0" ]; then
    nonroot=false
  else
    nonroot=true
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

    # supervisord.conf runs as user=root and keeps its pidfile and socket in /var/run; the
    # non-root variant has the same programs with its runtime files under /tmp. A command
    # without -c is left as it is, so supervisord finds /etc/supervisord.conf and fails.
    previous=
    for arg do
      shift
      case $arg in
        -c/etc/supervisord.conf) arg=-c/etc/supervisord-nonroot.conf ;;
        --configuration=/etc/supervisord.conf) arg=--configuration=/etc/supervisord-nonroot.conf ;;
        /etc/supervisord.conf)
          case $previous in
            -c | --configuration) arg=/etc/supervisord-nonroot.conf ;;
          esac
          ;;
      esac
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
