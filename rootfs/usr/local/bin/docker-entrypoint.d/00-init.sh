#!/bin/sh

set -eu

mkdir -p "$NGINX_CACHE_DIR"
mkdir -p "$NGINX_FASTCGI_TMP_DIR"
chown -R "$USER:$USER" "$NGINX_FASTCGI_TMP_DIR"
