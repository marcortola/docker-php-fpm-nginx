#!/bin/sh

set -eu

mkdir -p /var/lib/nginx/tmp
mkdir -p "$NGINX_CACHE_DIR"
mkdir -p "$NGINX_FASTCGI_TMP_DIR"

chown -R "$USER:$USER" /var/lib/nginx
chmod -R 755 /var/lib/nginx
chown -R "$USER:$USER" "$NGINX_FASTCGI_TMP_DIR"
