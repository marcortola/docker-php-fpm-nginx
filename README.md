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
    environment:
      HOME: /tmp
    volumes:
      - ./:/var/www
```

or `docker run --user "$(id -u):$(id -g)" --group-add 0 -e HOME=/tmp ...`. Group 0 grants write
access to the paths listed below.

Neither bash nor zsh exports your uid as `HOST_UID`, so Compose falls back to 1000 without a
warning. Set `HOST_UID` and `HOST_GID` in the project's `.env`, or export them in your shell, when
your uid or gid is not 1000.

The uid needs no passwd entry. Without one, `HOME` is `/`, which the uid cannot write, so
Composer's cache, npm (`EACCES: permission denied, mkdir '/.npm'`) and PsySH fail; hence
`HOME: /tmp` above. The image has no `ssh` client, and one installed in a derived image refuses
to run without an entry (`No user exists for uid 1000`), so Composer cannot fetch `git+ssh`
dependencies. If you need them, build a derived development image that adds the user, for
example `ARG HOST_UID=1000` and `RUN adduser -D -u "$HOST_UID" dev`.

### Where it works

The mode is meant for rootful Docker Engine, where the container's uid is your host uid, so files
written to the bind mount belong to you. Rootless Podman needs `userns_mode: keep-id` for the
same result. Under rootless Docker and Docker Desktop for Linux the container runs in a user
namespace, and the mode does not give host-uid ownership.

nginx listens on port 80 as a non-root uid because Docker sets
`net.ipv4.ip_unprivileged_port_start=0` in the container's own network namespace. With
`network_mode: host` the container shares the host's namespace, where that setting does not
apply, and nginx fails with `bind() to 0.0.0.0:80 failed (13: Permission denied)`.

### What changes

The entrypoint detects the mode from `id -u`. When the uid is not 0:

- every process runs as that uid, the nginx and php-fpm workers included. nginx's `user`
  directive is ignored, with a warning in the log;
- `docker-entrypoint.d/00-init.sh` is skipped. It creates and chowns the nginx directories,
  which needs root, so the image creates them at build time instead;
- supervisord runs with `/etc/supervisord-nonroot.conf` instead of `/etc/supervisord.conf`, when
  the command passes `-c /etc/supervisord.conf`, `-c/etc/supervisord.conf`,
  `--configuration /etc/supervisord.conf` or `--configuration=/etc/supervisord.conf`, as the
  image's `CMD` does. It has the same programs, no `user=root`, and its pidfile, socket and log
  live in `/tmp`. Use `supervisorctl -c /etc/supervisord-nonroot.conf` to reach it. A command
  of plain `supervisord`, without `-c`, is not changed: supervisord then finds
  `/etc/supervisord.conf` and fails as non-root;
- nginx writes its pid to `/tmp/nginx.pid` instead of `/var/run/nginx.pid`;
- nginx keeps its client body, proxy, uwsgi and scgi temp files in `/tmp/nginx` instead of
  `/var/lib/nginx/tmp`. That directory is an anonymous volume, and Compose keeps the one root
  mode chowned to `www-data` when it recreates a service, so request bodies that spill to disk
  would fail there;
- php-fpm does not chown its socket: `listen.owner` and `listen.group` are commented out, and
  `listen.mode = 0666` lets nginx connect.

Root mode renders the same configuration and behaves as before. The nginx and php-fpm changes
come from `docker-entrypoint.d/20-auto-envsubst.sh`, which checks the uid itself, so running it
again by hand with `docker exec` and then restarting the programs with `supervisorctl` is safe
in both modes.

These paths have group 0 with group permissions equal to the owner's, so group 0 can write them.
Nothing is world-writable:

- the `.auto-tpl` render targets `/etc/nginx/nginx.conf` and
  `/usr/local/etc/php-fpm.d/zzzz-docker.conf`;
- `/var/lib/nginx` and `/var/lib/nginx/tmp`, nginx's compiled-in temp location, for a derived
  `nginx.conf.auto-tpl` that does not move the temp paths (see below);
- `/var/run/php` (the fpm socket);
- `$NGINX_CACHE_DIR` and `$NGINX_FASTCGI_TMP_DIR`, as set in this image.

### Switching an existing checkout

Files created in root mode keep their owners: root, or `www-data` (82) for what PHP wrote, such
as a Symfony `var/cache/dev` with mode 0755. Your uid cannot write them, so the application fails
until you hand them over once, for example:

```sh
docker compose run --rm -u 0 app chown -R "$(id -u):$(id -g)" /var/www
```

Named volumes need the same: chown them once the same way, or remove them so Compose recreates
them. A new named volume mounted at a path that does not exist in the image starts as
`root:root` with mode 0755, which your uid cannot write either. Create that path in a derived
image, owned by your uid or with group 0 and `g=u`, so the new volume copies it.

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

- a custom `nginx.conf.auto-tpl` must keep `pid $NGINX_PID_FILE;`, since nginx cannot write
  `/var/run/nginx.pid` as non-root and exits. It should also keep `${NGINX_TEMP_PATHS}` at the
  start of a line in the `http` block, as in this image's template, which moves the temp paths
  to `/tmp/nginx`. Without it, switch an existing service with `docker compose up -V`
  (`--renew-anon-volumes`) once, so Compose replaces the anonymous volume at
  `/var/lib/nginx/tmp`;
- a new `.auto-tpl` template needs its render target created with group 0 and `g=u`, for example
  `RUN touch /etc/nginx/foo.conf && chgrp 0 /etc/nginx/foo.conf && chmod g=u /etc/nginx/foo.conf`;
- a different `NGINX_CACHE_DIR` or `NGINX_FASTCGI_TMP_DIR` needs the directory created the same
  way;
- a `docker-entrypoint.d` script must not need root, for example to `chown`;
- a custom supervisord configuration copied over `/etc/supervisord.conf` is replaced by
  `/etc/supervisord-nonroot.conf` in non-root mode, so programs it adds (a queue worker, say) do
  not start. Keep it at another path and pass that with `-c` in your `CMD`, or replace
  `/etc/supervisord-nonroot.conf` as well. Either way it must not set `user=root`, and must keep
  its pidfile, socket and log out of `/var/run` and the bind mount.
