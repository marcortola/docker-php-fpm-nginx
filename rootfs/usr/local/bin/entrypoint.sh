#!/bin/sh

set -e

if [ "$1" = "supervisord" ]; then

  # Non-root mode: the container was started as an arbitrary uid, typically the host uid
  # with group 0 added (compose `user:` plus `group_add: ["0"]`). Nothing can be chowned,
  # and only the paths the Dockerfile prepares with group 0 and g=u are writable, so the
  # root-only init script is skipped and supervisord gets its non-root config.
  # docker-entrypoint.d/20-auto-envsubst.sh moves the nginx and php-fpm runtime files to /tmp
  # itself, so that running it again by hand renders the same files.
  if [ "$(id -u)" = "0" ]; then
    nonroot=false
  else
    nonroot=true

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
