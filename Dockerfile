ARG PHP_VERSION=7.4

### BASE ###
FROM php:${PHP_VERSION}-fpm-alpine as base
ARG USER=www-data
ENV USER=${USER} \
    APP_ENV=prod \
    APP_DEBUG=0 \
    FPM_PM_MAX_CHILDREN=250 \
    FPM_PM_START_SERVERS=5 \
    FPM_PM_MIN_SPARE_SERVERS=5 \
    FPM_PM_MAX_SPARE_SERVERS=10 \
    FPM_PM_PROCESS_IDLE_TIMEOUT=300s \
    FPM_PM_MAX_REQUESTS=500 \
    NGINX_WORKER_PROCESSES=auto \
    NGINX_WORKER_CONNECTIONS=4096 \
    NGINX_KEEPALIVE_TIMEOUT=65 \
    NGINX_PCRE_JIT=on \
    NGINX_FASTCGI_TMP_DIR=/var/run/fastcgi-cache/ \
    NGINX_CACHE_DIR=/var/run/nginx-cache/ \
    NGINX_CACHE_MAX_SIZE=6144m \
    NGINX_CACHE_INACTIVE=1w

# Install deps
RUN apk add --update --no-cache \
        gettext \
        nginx \
        supervisor

# Setup PHP
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    intl \
    opcache \
    && mkdir -p /var/run/php/

# Setup Nginx
RUN chown -R $USER:$USER /var/www/ \
    && rm -rf /usr/share/doc/* /var/www/html /var/www/localhost \
    && rm -f /etc/nginx/sites-enabled/* \
    && mkdir -p /etc/nginx/server-blocks/ \
    && mkdir -p /etc/nginx/site-default/ \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log \
	&& ln -sf /dev/stderr /var/log/php-fpm.log

# Copy files
COPY ./rootfs /
RUN find /usr/local/bin/ -type f -name "*.sh" -exec chmod +x {} \;

HEALTHCHECK --interval=10s --timeout=3s CMD ["healthcheck.sh"]

ENTRYPOINT ["entrypoint.sh"]

WORKDIR /var/www

VOLUME /var/lib/nginx/tmp
EXPOSE 80

CMD ["supervisord", "-c", "/etc/supervisord.conf", "--nodaemon"]

### DEBUG ###
FROM base as debug
ENV APP_ENV=dev \
    APP_DEBUG=1 \
    XDEBUG_MODE=debug \
    NGINX_PCRE_JIT=off
RUN install-php-extensions \
      xdebug
COPY ./rootfs.debug /
