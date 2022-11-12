ARG PHP_VERSION=7.4

### BASE ###
FROM php:${PHP_VERSION}-fpm-alpine as base
ARG USER=www-data
ENV USER=${USER} \
    APP_ENV=prod \
    APP_DEBUG=false \
    FPM_PM_MAX_CHILDREN=20 \
    FPM_PM_START_SERVERS=2 \
    FPM_PM_MIN_SPARE_SERVERS=1 \
    FPM_PM_MAX_SPARE_SERVERS=3 \
    FPM_PM_PROCESS_IDLE_TIMEOUT=3 \
    FPM_PM_MAX_REQUESTS=3 \
    NGINX_WORKER_PROCESSES=auto \
    NGINX_WORKER_CONNECTIONS=4096 \
    NGINX_KEEPALIVE_TIMEOUT=65

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
RUN chown -R $USER:$USER /var/www/html/ \
    && rm -rf /usr/share/doc/* /var/www/html/* \
    && rm -f /etc/nginx/sites-enabled/* \
    && mkdir -p /etc/nginx/server-blocks/ \
    && mkdir -p /etc/nginx/site-default/ \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log

# Copy files
COPY ./rootfs /
RUN find /usr/local/bin/ -type f -name "*.sh" -exec chmod +x {} \;

HEALTHCHECK --interval=10s --timeout=3s CMD ["healthcheck.sh"]

ENTRYPOINT ["entrypoint.sh"]

WORKDIR /var/www

EXPOSE 80

CMD ["supervisord", "-c", "/usr/local/etc/supervisor/supervisor.conf", "--nodaemon"]

### DEBUG ###
FROM base as debug
ENV APP_ENV=dev \
    APP_DEBUG=true \
    XDEBUG_MODE=debug
RUN install-php-extensions \
      xdebug
COPY ./rootfs.debug /
