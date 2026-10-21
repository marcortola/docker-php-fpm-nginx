# php-fpm-nginx

PHP-FPM and nginx under supervisord on Alpine, published as `marcortola/php-fpm-nginx:<php>`
and `marcortola/php-fpm-nginx:<php>-debug` (with Xdebug).

## Non-root mode

By default the container starts as root. supervisord and the nginx and php-fpm masters run as
root, and the workers run as `www-data` (uid 82). That suits a production image. In development,
with the checkout bind-mounted at `/var/www`, it leaves root- and uid-82-owned files in the
checkout. A non-root mode avoids that: start the container as your own uid, with group 0 added:

```yaml
services:
  app:
    image: marcortola/php-fpm-nginx:8.4-debug
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    group_add: ["0"]
    volumes:
      - ./:/var/www
```

or `docker run --user "$(id -u):$(id -g)" --group-add 0 ...`. Group 0 grants write access to the
paths listed below. The uid needs no passwd entry. Port 80 keeps working, because Docker sets
`net.ipv4.ip_unprivileged_port_start=0` in the container's network namespace.

The entrypoint detects the mode from `id -u`. When the uid is not 0:

- every process runs as that uid, the nginx and php-fpm workers included. nginx's `user`
  directive is ignored, with a warning in the log;
- `docker-entrypoint.d/00-init.sh` is skipped. It creates and chowns the nginx directories,
  which needs root, so the image creates them at build time instead;
- supervisord runs with `/etc/supervisord-nonroot.conf` instead of `/etc/supervisord.conf`, for
  `-c /etc/supervisord.conf` or `--configuration /etc/supervisord.conf` on the command line. It
  has the same programs, no `user=root`, and its pidfile, socket and log live in `/tmp`. Use
  `supervisorctl -c /etc/supervisord-nonroot.conf` to reach it;
- nginx writes its pid to `/tmp/nginx.pid` instead of `/var/run/nginx.pid`;
- php-fpm does not chown its socket: `listen.owner` and `listen.group` are commented out, and
  `listen.mode = 0666` lets nginx connect.

Root mode renders the same configuration and behaves as before.

When you switch an existing Compose service to non-root, recreate it once with
`docker compose up -V` (`--renew-anon-volumes`). Compose otherwise keeps the old anonymous volume
at `/var/lib/nginx/tmp`, which root mode chowned to `www-data`, and request bodies larger than
nginx's `client_body_buffer_size` then fail.

These paths have group 0 with group permissions equal to the owner's, so group 0 can write them.
Nothing is world-writable:

- the `.auto-tpl` render targets `/etc/nginx/nginx.conf` and
  `/usr/local/etc/php-fpm.d/zzzz-docker.conf`;
- `/var/lib/nginx` and `/var/lib/nginx/tmp` (request body buffering; a fresh anonymous volume
  copies this ownership and mode);
- `/var/run/php` (the fpm socket);
- `$NGINX_CACHE_DIR` and `$NGINX_FASTCGI_TMP_DIR`, as set in this image.

### Derived images

Templates render in place, so a derived image's `COPY ./rootfs /` over `/etc/nginx` still works:
BuildKit resets an existing directory to `root:root` with the mode from your checkout, but
writing an existing file needs write permission on the file only.

Copying a file onto a render target is different. `COPY` replaces the file with your copy's
metadata (`root:root`, `0644`). The non-root render then fails with `Permission denied` and the
container exits. Such a copy has no effect in either mode, since the render overwrites the file at
start, so remove it and change the `.auto-tpl` template instead. `COPY --chmod=664` is no fix
when it copies a directory tree: it also removes the execute bit from the directories it copies.

A derived image that adds its own requirements for non-root mode must provide them itself:

- a new `.auto-tpl` template needs its render target created with group 0 and `g=u`, for example
  `RUN touch /etc/nginx/foo.conf && chgrp 0 /etc/nginx/foo.conf && chmod g=u /etc/nginx/foo.conf`;
- a different `NGINX_CACHE_DIR` or `NGINX_FASTCGI_TMP_DIR` needs the directory created the same
  way;
- a `docker-entrypoint.d` script must not need root, for example to `chown`;
- a custom supervisord configuration must not set `user=root`, and must keep its pidfile,
  socket and log out of `/var/run` and the bind mount.
